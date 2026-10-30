import Cocoa
import Metal
import QuartzCore
import OSLog
import VirtualCore

/// Draws the guest's display into a Metal layer.
///
/// The GPU reads the pixels from the memory QEMU draws them into, so nothing is copied when the display changes. Where
/// the GPU can't read them in place, because of how the rows are laid out, they're copied into a texture as they change.
@MainActor
final class QEMUDisplayRenderer {
    let layer = CAMetalLayer()

    private let logger = Logger(subsystem: VirtualUIConstants.subsystemName, category: "QEMUDisplayRenderer")

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    private var surface: QEMUDisplaySurface?
    private var texture: MTLTexture?
    /// Whether the texture holds a copy of the surface's pixels, which has to be updated when they change.
    private var isTextureCopied = false

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let commandQueue = device.makeCommandQueue() else {
            throw Failure("This Mac’s GPU can’t be used to show the virtual machine’s display.")
        }

        let library = try device.makeDefaultLibrary(bundle: Bundle(for: QEMUDisplayRenderer.self))

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "qemuDisplayVertex")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "qemuDisplayFragment")
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge

        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw Failure("The virtual machine’s display couldn’t be set up to draw.")
        }

        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        self.sampler = sampler

        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        /// The guest's pixels are in sRGB, as they were when the display was shown as images.
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.backgroundColor = NSColor.black.cgColor
    }

    /// Shows a new surface, or nothing.
    func show(_ surface: QEMUDisplaySurface?) {
        self.surface = surface
        texture = nil
        isTextureCopied = false

        guard let surface else { return }

        let pixelFormat: MTLPixelFormat = switch surface.pixelFormat {
        case .bgrx: .bgra8Unorm
        case .rgbx: .rgba8Unorm
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: surface.width, height: surface.height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead

        let alignment = device.minimumLinearTextureAlignment(for: pixelFormat)
        if surface.pixelOffset % alignment == 0, surface.bytesPerRow % alignment == 0,
           let buffer = device.makeBuffer(bytesNoCopy: surface.memory, length: surface.memoryLength, options: .storageModeShared, deallocator: { _, _ in
               /// The memory stays mapped for as long as the GPU might read it.
               withExtendedLifetime(surface) {}
           }),
           let texture = buffer.makeTexture(descriptor: descriptor, offset: surface.pixelOffset, bytesPerRow: surface.bytesPerRow)
        {
            self.texture = texture
            return
        }

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            logger.error("Couldn't make a \(surface.width)×\(surface.height) texture for the display")
            return
        }

        self.texture = texture
        isTextureCopied = true
        copyPixels(in: surface.bounds)
    }

    /// Takes in an area of the surface that changed.
    func update(_ area: CGRect) {
        guard isTextureCopied else { return }
        copyPixels(in: area)
    }

    private func copyPixels(in area: CGRect) {
        guard let surface, let texture else { return }

        let area = area.integral.intersection(surface.bounds)
        guard !area.isNull, !area.isEmpty else { return }

        let region = MTLRegionMake2D(Int(area.minX), Int(area.minY), Int(area.width), Int(area.height))
        let start = surface.pixels.advanced(by: Int(area.minY) * surface.bytesPerRow + Int(area.minX) * 4)
        texture.replace(region: region, mipmapLevel: 0, withBytes: start, bytesPerRow: surface.bytesPerRow)
    }

    /// Draws the display into the part of the layer it occupies, in the layer's pixels from the top left.
    func draw(in viewport: CGRect) {
        guard layer.drawableSize.width > 0, layer.drawableSize.height > 0,
              let drawable = layer.nextDrawable(),
              let commands = commandQueue.makeCommandBuffer()
        else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store

        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }

        if let texture, viewport.width > 0, viewport.height > 0 {
            encoder.setViewport(MTLViewport(originX: viewport.minX, originY: viewport.minY, width: viewport.width, height: viewport.height, znear: 0, zfar: 1))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}

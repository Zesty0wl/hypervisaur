//
//  SharedFolderListItem.swift
//  VirtualUI
//
//  Created by Guilherme Rambo on 19/07/22.
//

import SwiftUI
import VirtualCore

struct SharedFolderListItem: View {
    @Binding var folder: VBSharedFolder
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Toggle(folder.shortName, isOn: $folder.isEnabled)
                .labelsHidden()
                .disabled(folder.errorMessage != nil)

            folder.icon(maxHeight: 16)

            Text(folder.shortName)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(folder.url.path)

            Spacer(minLength: 0)

            if let errorMessage = folder.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .help(errorMessage)
            } else {
                Button {
                    folder.isReadOnly.toggle()
                } label: {
                    Image(systemName: folder.isReadOnly ? "pencil.slash" : "pencil")
                }
                .help(folder.isReadOnly ? "Make writable" : "Make read only")
                .buttonStyle(.borderless)
                .disabled(!folder.isEnabled)
            }

            CompactListRemoveButton(help: "Remove this shared folder", action: remove)
        }
        .opacity(folder.isEnabled ? 1 : 0.6)
        .opacity(folder.errorMessage != nil ? 0.5 : 1)
        .compactListRow()
    }
}

extension VBSharedFolder {
    func icon(maxHeight: CGFloat) -> some View {
        let image: NSImage
        if let externalVolumeURL {
            image = NSWorkspace.shared.icon(forFile: externalVolumeURL.path)
        } else {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
        let dimension = min(image.size.width, image.size.height)
        let scale = (maxHeight) / dimension
        image.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxHeight: maxHeight)
    }
}

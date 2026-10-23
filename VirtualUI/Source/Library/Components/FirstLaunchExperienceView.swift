import SwiftUI
import BuddyUI

/// Introduces the app over the library's background when the library is empty for the first time:
/// the app icon arrives, followed by the app's name and the button to create a virtual machine.
struct FirstLaunchExperienceView: View {
    var action: () -> ()

    @State private var iconRevealed = false
    @State private var titleRevealed = false
    @State private var buttonRevealed = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 180, height: 180)
                .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 12)
                .scaleEffect(iconRevealed ? 1 : 0.4)
                .rotationEffect(.degrees(iconRevealed ? 0 : -12))
                .opacity(iconRevealed ? 1 : 0)

            Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 2)
                .opacity(titleRevealed ? 1 : 0)
                .offset(y: titleRevealed ? 0 : 12)

            Button {
                action()
            } label: {
                Text("Create Virtual Machine")
                    .font(.system(.title2, design: .rounded, weight: .medium))
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(FirstLaunchButtonStyle())
            .controlSize(.large)
            .opacity(buttonRevealed ? 1 : 0)
            .scaleEffect(buttonRevealed ? 1 : 1.2)
            .disabled(!buttonRevealed)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.55).delay(0.3)) {
                iconRevealed = true
            }
            withAnimation(.snappy.delay(1.1)) {
                titleRevealed = true
            }
            withAnimation(.snappy.delay(1.8)) {
                buttonRevealed = true
            }
        }
    }
}

private extension Color {
    /// The app's brand colour, which the introduction uses whatever accent colour the user has chosen for controls.
    static let hypervisaurTeal = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            NSColor(srgbRed: 0x2E / 255, green: 0xC4 / 255, blue: 0xB6 / 255, alpha: 1)
        } else {
            NSColor(srgbRed: 0x0E / 255, green: 0x7C / 255, blue: 0x73 / 255, alpha: 1)
        }
    })
}

private struct FirstLaunchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(Material.regular, in: shape)
            .overlay {
                ZStack {
                    Color.hypervisaurTeal
                        .blendMode(.color)
                        .opacity(configuration.isPressed ? 1 : 0.7)

                    shape
                        .inset(by: 10)
                        .fill(Color.hypervisaurTeal)
                        .blur(radius: 10)
                        .blendMode(.plusLighter)
                        .opacity(configuration.isPressed ? 0.1 : 0)

                    LinearGradient(colors: [.hypervisaurTeal.opacity(0.9), .hypervisaurTeal.opacity(0.4)], startPoint: .top, endPoint: .bottom)
                        .mask {
                            shape.strokeBorder(Color.white, lineWidth: 1)
                        }
                        .blendMode(.plusLighter)
                        .opacity(0.3)
                }
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 0)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(configuration.isPressed ? .linear(duration: 0) : .snappy, value: configuration.isPressed)
    }

    var shape: some InsettableShape {
        Capsule(style: .continuous)
    }
}

#if DEBUG
#Preview {
    FirstLaunchExperienceView() { }
        .frame(width: 900, height: 600)
}
#endif

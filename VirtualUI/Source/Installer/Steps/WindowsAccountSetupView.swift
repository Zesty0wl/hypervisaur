import SwiftUI
import VirtualCore

/// Lets the user have Windows installed without going through Windows Setup, signing in to a local account.
struct WindowsAccountSetupView: View {
    @Binding var isEnabled: Bool
    @Binding var accountName: String
    @Binding var password: String
    var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Set Up Windows Automatically", isOn: $isEnabled)
                .toggleStyle(.switch)
                .font(.headline)

            Text("Windows installs without asking anything, and signs in to a local account instead of a Microsoft account.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isEnabled {
                TextField("Account Name", text: $accountName)

                SecureField("Password (Optional)", text: $password)

                Text(password.isEmpty ? "Without a password, Windows signs in to the account every time it starts." : "Windows signs in to the account by itself the first time it starts.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let validationError {
                    Text(validationError)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.large)
        .padding()
        .controlGroup()
        .frame(maxWidth: 500)
        .animation(.snappy, value: isEnabled)
    }
}

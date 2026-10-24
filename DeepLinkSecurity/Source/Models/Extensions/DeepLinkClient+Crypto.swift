import Cocoa

public extension DeepLinkClient {
    init(auditTokenDescriptor: NSAppleEventDescriptor) throws {
        let attrs = [kSecGuestAttributeAudit: auditTokenDescriptor.data]
        var client: SecCode!

        try checkSecError(SecCodeCopyGuestWithAttributes(nil, attrs as CFDictionary, .default, &client), task: "copy client cs attributes")

        var staticCode: SecStaticCode!
        try checkSecError(SecCodeCopyStaticCode(client, .default, &staticCode), task: "copy client static code")

        var url: CFURL!

        try checkSecError(SecCodeCopyPath(staticCode, .default, &url), task: "copy client path")

        var requirement: SecRequirement!
        try checkSecError(SecCodeCopyDesignatedRequirement(staticCode, .default, &requirement), task: "copy client designated requirement")

        var requirementText: CFString!
        try checkSecError(SecRequirementCopyString(requirement, .default, &requirementText), task: "copy client designated requirement text")

        self.init(url: url as URL, designatedRequirement: requirementText as String)
    }

    init(url: URL) throws {
        var staticCode: SecStaticCode!
        try checkSecError(SecStaticCodeCreateWithPath(url as CFURL, .default, &staticCode), task: "load client static code")

        var requirement: SecRequirement!
        try checkSecError(SecCodeCopyDesignatedRequirement(staticCode, .default, &requirement), task: "copy client designated requirement")

        var requirementText: CFString!
        try checkSecError(SecRequirementCopyString(requirement, .default, &requirementText), task: "copy client designated requirement text")

        self.init(url: url, designatedRequirement: requirementText as String)
    }

    /// Validates the client's static code against the designated requirement,
    /// throwing an error if the signature doesn't match.
    ///
    /// Validating a bundle blocks while its nested code is validated on other threads, and when as many validations
    /// as there are CPU cores block at once, none of them finish. Calling it from Swift concurrency's thread pool,
    /// which has one thread per core, would hang every task in the process once enough requests arrive together,
    /// so validations run one at a time on their own queue.
    func validate() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            codeValidationQueue.async {
                continuation.resume(with: Result { try validateSynchronously() })
            }
        }
    }

    private func validateSynchronously() throws {
        var requirement: SecRequirement!
        try checkSecError(SecRequirementCreateWithString(designatedRequirement as CFString, .default, &requirement), task: "create client designated requirement")

        var staticCode: SecStaticCode!
        try checkSecError(SecStaticCodeCreateWithPath(url as CFURL, .default, &staticCode), task: "load client static code")

        var errors: Unmanaged<CFError>?
        guard SecStaticCodeCheckValidityWithErrors(staticCode, .default, requirement, &errors) == noErr else {
            let errorMessage = errors?.takeUnretainedValue().localizedDescription ?? "Unknown error"
            throw DeepLinkError("Client code signature validation failed with: \(errorMessage)")
        }
    }
}

private let codeValidationQueue = DispatchQueue(label: "DeepLinkClient.CodeValidation", qos: .userInitiated)

private func checkSecError(_ closure: @autoclosure () -> OSStatus, task: String) throws {
    let err = closure()

    guard err != noErr else { return }

    let msg = SecCopyErrorMessageString(err, nil) as String?

    throw DeepLinkError("Failed to \(task). Error code \(err): \(msg ?? "<unknown>")")
}

extension SecCSFlags {
    static let `default` = SecCSFlags([])
}

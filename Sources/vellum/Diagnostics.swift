import Foundation

public struct VellumDiagnostic: Codable, Hashable, Sendable {
    public enum Severity: String, Codable, Sendable {
        case error
        case warning
    }

    public let code: String
    public let severity: Severity
    public let specRule: String
    public let filePath: String?
    public let message: String
    public let hint: String

    public init(
        code: String,
        severity: Severity = .error,
        specRule: String,
        filePath: String? = nil,
        message: String,
        hint: String
    ) {
        self.code = code
        self.severity = severity
        self.specRule = specRule
        self.filePath = filePath
        self.message = message
        self.hint = hint
    }
}

public enum VellumError: Error, Sendable, LocalizedError {
    case strictValidationFailed([VellumDiagnostic])
    case unsupportedFeature(String, [VellumDiagnostic] = [])
    case ioFailure(String)

    public var errorDescription: String? {
        switch self {
        case .strictValidationFailed(let diagnostics):
            return "Strict validation failed with \(diagnostics.count) diagnostic(s)."
        case .unsupportedFeature(let reason, _):
            return "Unsupported EPUB feature: \(reason)"
        case .ioFailure(let message):
            return "I/O failure: \(message)"
        }
    }
}

import Foundation

/// Non-throwing validation result for EPUB input.
public struct ValidationReport: Sendable {
    /// `true` when no validation diagnostics were produced.
    public let isValid: Bool
    /// Validation diagnostics for invalid input.
    public let diagnostics: [VellumDiagnostic]

    /// Creates a validation report.
    ///
    /// - Parameters:
    ///   - isValid: Whether validation passed.
    ///   - diagnostics: Validation diagnostics.
    public init(isValid: Bool, diagnostics: [VellumDiagnostic]) {
        self.isValid = isValid
        self.diagnostics = diagnostics
    }
}

/// Non-throwing EPUB validator that wraps strict parser behavior.
public struct EPUBValidator: Sendable {
    /// Creates a validator.
    public init() {}

    /// Validates an EPUB archive from disk.
    ///
    /// - Parameter epubURL: EPUB archive URL.
    /// - Returns: A validation report.
    public func validateEPUB(at epubURL: URL) -> ValidationReport {
        validateSync(at: epubURL)
    }

    /// Validates an EPUB archive from disk.
    ///
    /// - Parameter epubURL: EPUB archive URL.
    /// - Returns: A validation report.
    public func validateEPUB(at epubURL: URL) async -> ValidationReport {
        validateSync(at: epubURL)
    }

    private func validateSync(at epubURL: URL) -> ValidationReport {
        do {
            _ = try EPUBParser().parseEPUB(at: epubURL)
            return ValidationReport(isValid: true, diagnostics: [])
        } catch let VellumError.strictValidationFailed(diagnostics) {
            return ValidationReport(isValid: false, diagnostics: diagnostics)
        } catch let VellumError.unsupportedFeature(reason, diagnostics) {
            let wrapped: [VellumDiagnostic]
            if diagnostics.isEmpty {
                wrapped = [
                    .init(
                        code: "VAL001",
                        specRule: "EPUB Feature Support",
                        message: reason,
                        hint: "Remove unsupported features or extend vellum support."
                    )
                ]
            } else {
                wrapped = diagnostics
            }
            return ValidationReport(isValid: false, diagnostics: wrapped)
        } catch let VellumError.ioFailure(message) {
            return ValidationReport(
                isValid: false,
                diagnostics: [
                    .init(
                        code: "VAL002",
                        specRule: "EPUB I/O",
                        message: message,
                        hint: "Verify the EPUB exists and is a valid ZIP archive."
                    )
                ]
            )
        } catch {
            return ValidationReport(
                isValid: false,
                diagnostics: [
                    .init(
                        code: "VAL999",
                        specRule: "Unknown",
                        message: error.localizedDescription,
                        hint: "Inspect underlying error and EPUB structure."
                    )
                ]
            )
        }
    }
}

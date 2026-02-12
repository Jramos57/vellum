import Foundation

enum Internal {
    static let oebps = "OEBPS"
    static let containerPath = "META-INF/container.xml"
    static let opfPath = "OEBPS/content.opf"
    static let navPath = "OEBPS/nav.xhtml"
    static let tocNCXPath = "OEBPS/toc.ncx"
    static let cssPath = "OEBPS/styles/main.css"
    static let scriptPath = "OEBPS/scripts/app.js"
    static let imagePath = "OEBPS/images/cover.jpg"
    static let svgPath = "OEBPS/images/diagram.svg"
    static let fontPath = "OEBPS/fonts/demo.otf"
    static let audioPath = "OEBPS/audio/sample.mp3"
    static let videoPath = "OEBPS/video/sample.mp4"
}

enum ZipTool {
    static func makeArchive(from directory: URL, output: URL) throws {
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }

        let result1 = run(
            executable: "/usr/bin/zip",
            arguments: ["-X0q", output.path, "mimetype"],
            currentDirectoryURL: directory
        )
        guard result1.exitCode == 0 else {
            throw VellumError.ioFailure("zip failed when writing mimetype: \(result1.stderr)")
        }

        let result2 = run(
            executable: "/usr/bin/zip",
            arguments: ["-Xr9q", output.path, "META-INF", "OEBPS"],
            currentDirectoryURL: directory
        )
        guard result2.exitCode == 0 else {
            throw VellumError.ioFailure("zip failed when writing content: \(result2.stderr)")
        }
    }

    static func extractArchive(_ archiveURL: URL, to directory: URL) throws {
        let result = run(
            executable: "/usr/bin/unzip",
            arguments: ["-q", archiveURL.path, "-d", directory.path],
            currentDirectoryURL: directory
        )
        guard result.exitCode == 0 else {
            throw VellumError.ioFailure("unzip failed: \(result.stderr)")
        }
    }

    static func validateMimetypeConstraints(archiveURL: URL) throws {
        let order = run(executable: "/usr/bin/zipinfo", arguments: ["-1", archiveURL.path], currentDirectoryURL: nil)
        guard order.exitCode == 0 else {
            throw VellumError.ioFailure("zipinfo failed: \(order.stderr)")
        }
        let entries = order.stdout.split(separator: "\n").map(String.init)
        var diagnostics: [VellumDiagnostic] = []
        if entries.first != "mimetype" {
            diagnostics.append(
                .init(
                    code: "ZIP001",
                    specRule: "EPUB 3.3 OCF ZIP Container",
                    filePath: "mimetype",
                    message: "mimetype is not the first ZIP entry.",
                    hint: "Ensure mimetype is added first during archive creation."
                )
            )
        }

        let verbose = run(executable: "/usr/bin/zipinfo", arguments: ["-v", archiveURL.path], currentDirectoryURL: nil)
        if verbose.exitCode == 0 {
            let block = verbose.stdout
            if block.contains("mimetype") && !block.contains("compression method:                             none (stored)") {
                diagnostics.append(
                    .init(
                        code: "ZIP002",
                        specRule: "EPUB 3.3 OCF ZIP Container",
                        filePath: "mimetype",
                        message: "mimetype entry is compressed.",
                        hint: "Write mimetype with storage mode 0 (uncompressed)."
                    )
                )
            }
        }

        if !diagnostics.isEmpty {
            throw VellumError.strictValidationFailed(diagnostics)
        }
    }

    private static func run(
        executable: String,
        arguments: [String],
        currentDirectoryURL: URL?
    ) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectoryURL {
            process.currentDirectoryURL = currentDirectoryURL
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (1, "", error.localizedDescription)
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return (
            process.terminationStatus,
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}

extension String {
    func xmlEscaped() -> String {
        self
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

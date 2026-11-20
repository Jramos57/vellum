import Foundation
import vellum

@main
struct VellumCLI {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            printUsage()
            exit(1)
        }

        do {
            switch command {
            case "sample":
                guard args.count >= 2 else {
                    throw CLIError.invalidUsage("sample requires output path")
                }
                let outputURL = URL(fileURLWithPath: args[1])
                let flags = Set(args.dropFirst(2))
                let supportedFlags: Set<String> = ["--feature-demo"]
                let unsupported = flags.subtracting(supportedFlags)
                if let firstUnsupported = unsupported.first {
                    throw CLIError.invalidUsage("unsupported sample option: \(firstUnsupported)")
                }

                let includeFeatureDemo = flags.contains("--feature-demo")
                let request = includeFeatureDemo
                    ? SampleBookFactory.makeLoremIpsumBook(chapterCount: 10)
                    : SampleBookFactory.makeReaderSafeLoremIpsumBook(chapterCount: 10)
                try EPUBCreator().createEPUB(request, outputURL: outputURL)
                if includeFeatureDemo {
                    print("Created sample EPUB (feature demo enabled): \(outputURL.path)")
                } else {
                    print("Created sample EPUB (reader-safe profile): \(outputURL.path)")
                }

            case "create":
                guard args.count == 3 else {
                    throw CLIError.invalidUsage("create requires a build manifest and an output path")
                }
                let manifestURL = URL(fileURLWithPath: args[1])
                let outputURL = URL(fileURLWithPath: args[2])
                let manifest = try EPUBBuildManifest.load(from: manifestURL)
                let request = try manifest.makeRequest(relativeTo: manifestURL.deletingLastPathComponent())
                try EPUBCreator().createEPUB(request, outputURL: outputURL)
                print("Created EPUB with \(request.chapters.count) chapters: \(outputURL.path)")

            case "validate":
                guard args.count >= 2 else {
                    throw CLIError.invalidUsage("validate requires epub path")
                }
                let inputURL = URL(fileURLWithPath: args[1])
                let report = EPUBValidator().validateEPUB(at: inputURL)
                if report.isValid {
                    print("VALID")
                } else {
                    print("INVALID")
                    for d in report.diagnostics {
                        print("[\(d.code)] \(d.message)")
                    }
                    exit(2)
                }

            case "parse":
                guard args.count >= 3 else {
                    throw CLIError.invalidUsage("parse requires epub path and markdown output path")
                }
                let inputURL = URL(fileURLWithPath: args[1])
                let outputMD = URL(fileURLWithPath: args[2])
                let book = try EPUBParser().parseEPUB(at: inputURL)
                try book.renderStructuredMarkdown().write(to: outputMD, atomically: true, encoding: .utf8)
                print("Wrote markdown: \(outputMD.path)")

            default:
                throw CLIError.invalidUsage("unknown command: \(command)")
            }
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            if case VellumError.strictValidationFailed(let diagnostics) = error {
                for d in diagnostics {
                    let file = d.filePath.map { " \($0):" } ?? ""
                    FileHandle.standardError.write(Data("  [\(d.code)]\(file) \(d.message) \(d.hint)\n".utf8))
                }
            } else if case CLIError.invalidUsage = error {
                printUsage()
            }
            exit(1)
        }
    }

    static func printUsage() {
        print("""
        vellum-cli usage:
          vellum-cli sample <output.epub> [--feature-demo]
          vellum-cli create <manifest.json> <output.epub>
          vellum-cli validate <input.epub>
          vellum-cli parse <input.epub> <output.md>
        """)
    }
}

enum CLIError: LocalizedError {
    case invalidUsage(String)

    var errorDescription: String? {
        switch self {
        case .invalidUsage(let msg):
            return msg
        }
    }
}

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
                let request = SampleBookFactory.makeLoremIpsumBook(chapterCount: 10)
                try EPUBCreator().createEPUB(request, outputURL: outputURL)
                print("Created sample EPUB: \(outputURL.path)")

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
            fputs("Error: \(error.localizedDescription)\n", stderr)
            printUsage()
            exit(1)
        }
    }

    static func printUsage() {
        print("""
        vellum-cli usage:
          vellum-cli sample <output.epub>
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

import Foundation

enum ZipArchiveError: Error, LocalizedError {
    case invalidArchive(String)
    case unsupported(String)
    case ioFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidArchive(let message):
            message
        case .unsupported(let message):
            message
        case .ioFailure(let message):
            message
        }
    }
}

import Foundation
import zlib

enum ZipCRC32 {
    static func checksum(_ data: Data) -> UInt32 {
        if data.isEmpty {
            return UInt32(zlib.crc32(0, nil, 0))
        }

        return data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: Bytef.self)
            return UInt32(zlib.crc32(0, bytes.baseAddress, uInt(bytes.count)))
        }
    }
}

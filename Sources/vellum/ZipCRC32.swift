import Foundation
#if canImport(zlib)
import zlib
#endif

enum ZipCRC32 {
    #if !canImport(zlib)
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
        }
        return value
    }
    #endif

    static func checksum(_ data: Data) -> UInt32 {
        #if canImport(zlib)
        return data.withUnsafeBytes { rawBuffer in
            var crc = zlib.crc32(0, nil, 0)
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return UInt32(crc)
            }
            var offset = 0
            while offset < rawBuffer.count {
                // crc32 takes a uInt length; chunk buffers larger than that type.
                let count = uInt(clamping: rawBuffer.count - offset)
                crc = zlib.crc32(crc, bytes.advanced(by: offset), count)
                offset += Int(count)
            }
            return UInt32(truncatingIfNeeded: crc)
        }
        #else
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { rawBuffer in
            for byte in rawBuffer.bindMemory(to: UInt8.self) {
                crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
            }
        }
        return crc ^ 0xFFFF_FFFF
        #endif
    }
}

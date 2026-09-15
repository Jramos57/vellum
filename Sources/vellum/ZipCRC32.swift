import Foundation

enum ZipCRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { rawBuffer in
            for byte in rawBuffer.bindMemory(to: UInt8.self) {
                crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

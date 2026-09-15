import Foundation

enum ZipBinary {
    static func readUInt16(from data: Data, at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else {
            throw ZipArchiveError.invalidArchive("Unexpected end of ZIP data.")
        }
        let lower = UInt16(data[offset])
        let upper = UInt16(data[offset + 1]) << 8
        return lower | upper
    }

    static func readUInt32(from data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else {
            throw ZipArchiveError.invalidArchive("Unexpected end of ZIP data.")
        }
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1]) << 8
        let b2 = UInt32(data[offset + 2]) << 16
        let b3 = UInt32(data[offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }

    static func readData(from data: Data, at offset: Int, length: Int) throws -> Data {
        guard offset >= 0, length >= 0, offset + length <= data.count else {
            throw ZipArchiveError.invalidArchive("Unexpected end of ZIP data.")
        }
        return data.subdata(in: offset..<(offset + length))
    }
}

extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value & 0x00ff))
        append(UInt8(truncatingIfNeeded: (value >> 8) & 0x00ff))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value & 0x0000_00ff))
        append(UInt8(truncatingIfNeeded: (value >> 8) & 0x0000_00ff))
        append(UInt8(truncatingIfNeeded: (value >> 16) & 0x0000_00ff))
        append(UInt8(truncatingIfNeeded: (value >> 24) & 0x0000_00ff))
    }
}

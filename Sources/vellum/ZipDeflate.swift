import Foundation

enum ZipDeflate {
    /// Compresses bytes into a raw DEFLATE stream.
    ///
    /// The current encoder emits stored (uncompressed) DEFLATE blocks. A fixed-Huffman
    /// encoder with LZ77 matching lands in the same release cycle.
    static func compress(_ data: Data) throws -> Data {
        var output = Data()
        let chunkSize = 65_535

        if data.isEmpty {
            output.append(0x01)
            output.appendLittleEndian(UInt16(0))
            output.appendLittleEndian(UInt16(0xFFFF))
            return output
        }

        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let length = end - offset

            output.append(end == data.count ? 0x01 : 0x00)
            output.appendLittleEndian(UInt16(length))
            output.appendLittleEndian(~UInt16(length))
            output.append(contentsOf: data[offset..<end])

            offset = end
        }

        return output
    }

    /// Decompresses a raw DEFLATE stream.
    ///
    /// - Parameters:
    ///   - data: The raw DEFLATE stream.
    ///   - expectedSize: Optional uncompressed size; decoding fails early if exceeded.
    static func decompress(_ data: Data, expectedSize: Int? = nil) throws -> Data {
        try ZipInflate.decompress(data, expectedSize: expectedSize)
    }
}

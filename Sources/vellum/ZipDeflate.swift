import Foundation

enum ZipDeflate {
    /// Compresses bytes into a raw DEFLATE stream.
    ///
    /// The encoder uses a single fixed-Huffman block with greedy LZ77 matching and
    /// falls back to stored blocks when compression would not reduce the size.
    static func compress(_ data: Data) throws -> Data {
        let compressed = try fixedHuffmanStream(for: data)
        let storedSize = storedBlockSize(for: data)
        if compressed.count >= storedSize {
            return storedBlocks(for: data)
        }
        return compressed
    }

    /// Decompresses a raw DEFLATE stream.
    ///
    /// - Parameters:
    ///   - data: The raw DEFLATE stream.
    ///   - expectedSize: Optional uncompressed size; decoding fails early if exceeded.
    static func decompress(_ data: Data, expectedSize: Int? = nil) throws -> Data {
        try ZipInflate.decompress(data, expectedSize: expectedSize)
    }

    // MARK: Stored blocks

    private static func storedBlockSize(for data: Data) -> Int {
        guard !data.isEmpty else { return 5 }
        let blockCount = (data.count + 65_534) / 65_535
        return data.count + blockCount * 5
    }

    private static func storedBlocks(for data: Data) -> Data {
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

    // MARK: Fixed-Huffman LZ77 encoder

    private static let minMatchLength = 3
    private static let maxMatchLength = 258
    private static let maxWindowDistance = 32_768
    private static let maxChainLength = 128
    private static let hashBits = 15
    private static let hashSize = 1 << hashBits

    private static let lengthBase: [Int] = [
        3, 4, 5, 6, 7, 8, 9, 10,
        11, 13, 15, 17, 19, 23, 27, 31,
        35, 43, 51, 59, 67, 83, 99, 115,
        131, 163, 195, 227, 258
    ]

    private static let lengthExtraBits: [Int] = [
        0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4,
        5, 5, 5, 5, 0
    ]

    private static let distanceBase: [Int] = [
        1, 2, 3, 4, 5, 7, 9, 13,
        17, 25, 33, 49, 65, 97, 129, 193,
        257, 385, 513, 769, 1025, 1537, 2049, 3073,
        4097, 6145, 8193, 12289, 16385, 24577
    ]

    private static let distanceExtraBits: [Int] = [
        0, 0, 0, 0, 1, 1, 2, 2,
        3, 3, 4, 4, 5, 5, 6, 6,
        7, 7, 8, 8, 9, 9, 10, 10,
        11, 11, 12, 12, 13, 13
    ]

    private static let lengthCodes: [(symbol: Int, extraBits: Int, extraValue: Int)] = {
        (minMatchLength...maxMatchLength).map { length in
            if length == maxMatchLength {
                return (285, 0, 0)
            }
            var index = lengthBase.count - 2
            while index > 0 && lengthBase[index] > length {
                index -= 1
            }
            return (257 + index, lengthExtraBits[index], length - lengthBase[index])
        }
    }()

    private static func distanceCode(for distance: Int) -> (symbol: Int, extraBits: Int, extraValue: Int) {
        var symbol = 0
        while symbol < distanceBase.count - 1 && distanceBase[symbol + 1] <= distance {
            symbol += 1
        }
        return (symbol, distanceExtraBits[symbol], distance - distanceBase[symbol])
    }

    private static func fixedHuffmanStream(for data: Data) throws -> Data {
        let bytes = [UInt8](data)
        var writer = BitWriter()

        writer.writeBits(1, count: 1)
        writer.writeBits(1, count: 2)

        var head = [Int32](repeating: -1, count: hashSize)
        var previous = [Int32](repeating: -1, count: max(bytes.count, 1))

        var index = 0
        while index < bytes.count {
            var matchLength = 0
            var matchDistance = 0

            if index + minMatchLength <= bytes.count {
                let hashValue = hash(of: bytes, at: index)
                var candidate = Int(head[hashValue])
                var chain = 0

                while candidate >= 0, candidate >= index - maxWindowDistance, chain < maxChainLength {
                    var length = 0
                    while length < maxMatchLength,
                          index + length < bytes.count,
                          bytes[candidate + length] == bytes[index + length] {
                        length += 1
                    }
                    if length > matchLength {
                        matchLength = length
                        matchDistance = index - candidate
                        if length == maxMatchLength {
                            break
                        }
                    }
                    candidate = Int(previous[candidate])
                    chain += 1
                }

                previous[index] = head[hashValue]
                head[hashValue] = Int32(index)
            }

            if matchLength >= minMatchLength {
                let lengthCode = lengthCodes[matchLength - minMatchLength]
                writeLiteralOrLength(lengthCode.symbol, to: &writer)
                writer.writeBits(lengthCode.extraValue, count: lengthCode.extraBits)

                let distanceCode = distanceCode(for: matchDistance)
                writer.writeCode(UInt32(distanceCode.symbol), count: 5)
                writer.writeBits(distanceCode.extraValue, count: distanceCode.extraBits)

                let matchEnd = index + matchLength
                for position in (index + 1)..<matchEnd where position + minMatchLength <= bytes.count {
                    let hashValue = hash(of: bytes, at: position)
                    previous[position] = head[hashValue]
                    head[hashValue] = Int32(position)
                }
                index = matchEnd
            } else {
                writeLiteralOrLength(Int(bytes[index]), to: &writer)
                index += 1
            }
        }

        writeLiteralOrLength(256, to: &writer)
        return writer.finish()
    }

    private static func hash(of bytes: [UInt8], at index: Int) -> Int {
        (Int(bytes[index]) << 10 ^ Int(bytes[index + 1]) << 5 ^ Int(bytes[index + 2])) & (hashSize - 1)
    }

    private static func writeLiteralOrLength(_ symbol: Int, to writer: inout BitWriter) {
        switch symbol {
        case 0...143:
            writer.writeCode(UInt32(0x30 + symbol), count: 8)
        case 144...255:
            writer.writeCode(UInt32(0x190 + symbol - 144), count: 9)
        case 256...279:
            writer.writeCode(UInt32(symbol - 256), count: 7)
        default:
            writer.writeCode(UInt32(0xC0 + symbol - 280), count: 8)
        }
    }
}

private struct BitWriter {
    private var bytes: [UInt8] = []
    private var bitBuffer: UInt8 = 0
    private var bitCount = 0

    mutating func writeBits(_ value: Int, count: Int) {
        guard count > 0 else { return }
        for index in 0..<count {
            writeBit((value >> index) & 1)
        }
    }

    mutating func writeCode(_ code: UInt32, count: Int) {
        guard count > 0 else { return }
        for index in stride(from: count - 1, through: 0, by: -1) {
            writeBit(Int((code >> index) & 1))
        }
    }

    mutating func finish() -> Data {
        if bitCount > 0 {
            bytes.append(bitBuffer)
            bitBuffer = 0
            bitCount = 0
        }
        return Data(bytes)
    }

    private mutating func writeBit(_ bit: Int) {
        if bit == 1 {
            bitBuffer |= 1 << bitCount
        }
        bitCount += 1
        if bitCount == 8 {
            bytes.append(bitBuffer)
            bitBuffer = 0
            bitCount = 0
        }
    }
}

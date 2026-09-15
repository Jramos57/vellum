import Foundation

/// A pure Swift raw DEFLATE (RFC 1951) decoder.
enum ZipInflate {
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

    private static let fixedLiteralDecoder: HuffmanDecoder = {
        let codeLengths: [Int] = (0..<288).map { symbol in
            switch symbol {
            case 0...143: 8
            case 144...255: 9
            case 256...279: 7
            default: 8
            }
        }
        do {
            return try HuffmanDecoder(codeLengths: codeLengths)
        } catch {
            preconditionFailure("Fixed DEFLATE literal table must be valid: \(error)")
        }
    }()

    private static let fixedDistanceDecoder: HuffmanDecoder = {
        do {
            return try HuffmanDecoder(codeLengths: [Int](repeating: 5, count: 32))
        } catch {
            preconditionFailure("Fixed DEFLATE distance table must be valid: \(error)")
        }
    }()

    static func decompress(_ data: Data, expectedSize: Int? = nil) throws -> Data {
        var reader = BitReader(data: data)
        var buffer = ByteBuffer(expectedSize: expectedSize)

        var isFinal = false
        repeat {
            isFinal = try readBlock(reader: &reader, buffer: &buffer)
        } while !isFinal

        if let expectedSize, buffer.count != expectedSize {
            throw ZipArchiveError.invalidArchive(
                "DEFLATE stream produced \(buffer.count) bytes, expected \(expectedSize)."
            )
        }
        return buffer.finish()
    }

    private static func readBlock(reader: inout BitReader, buffer: inout ByteBuffer) throws -> Bool {
        let isFinal = try reader.readBit() == 1
        let blockType = try reader.readBits(2)

        switch blockType {
        case 0:
            try readStoredBlock(reader: &reader, buffer: &buffer)
        case 1:
            try decodeHuffmanBlock(
                reader: &reader,
                buffer: &buffer,
                literal: fixedLiteralDecoder,
                distance: fixedDistanceDecoder
            )
        case 2:
            let decoders = try readDynamicDecoders(reader: &reader)
            try decodeHuffmanBlock(
                reader: &reader,
                buffer: &buffer,
                literal: decoders.literal,
                distance: decoders.distance
            )
        default:
            throw ZipArchiveError.invalidArchive("Invalid DEFLATE block type \(blockType).")
        }

        return isFinal
    }

    private static func readStoredBlock(reader: inout BitReader, buffer: inout ByteBuffer) throws {
        reader.alignToByte()
        let length = Int(try reader.readUInt16())
        let complement = Int(try reader.readUInt16())
        guard (length ^ complement) == 0xFFFF else {
            throw ZipArchiveError.invalidArchive("Invalid DEFLATE stored block length.")
        }
        guard length > 0 else { return }

        let storedBytes = try reader.readBytes(length)
        try buffer.append(contentsOf: storedBytes)
    }

    private static func decodeHuffmanBlock(
        reader: inout BitReader,
        buffer: inout ByteBuffer,
        literal: HuffmanDecoder,
        distance: HuffmanDecoder
    ) throws {
        while true {
            let symbol = try literal.decode(&reader)
            switch symbol {
            case 0..<256:
                try buffer.append(UInt8(symbol))
            case 256:
                return
            case 257..<286:
                let lengthIndex = symbol - 257
                let length = lengthBase[lengthIndex] + (try reader.readBits(lengthExtraBits[lengthIndex]))
                let distanceSymbol = try distance.decode(&reader)
                guard distanceSymbol < distanceBase.count else {
                    throw ZipArchiveError.invalidArchive("Invalid DEFLATE distance symbol \(distanceSymbol).")
                }
                let distanceValue = distanceBase[distanceSymbol] + (try reader.readBits(distanceExtraBits[distanceSymbol]))
                try buffer.copyBack(distance: distanceValue, length: length)
            default:
                throw ZipArchiveError.invalidArchive("Invalid DEFLATE literal/length symbol \(symbol).")
            }
        }
    }

    private static func readDynamicDecoders(reader: inout BitReader) throws -> (literal: HuffmanDecoder, distance: HuffmanDecoder) {
        let literalCount = try reader.readBits(5) + 257
        let distanceCount = try reader.readBits(5) + 1
        let codeLengthCount = try reader.readBits(4) + 4

        guard literalCount <= 286, distanceCount <= 32 else {
            throw ZipArchiveError.invalidArchive("Invalid DEFLATE dynamic table counts.")
        }

        let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var codeLengthLengths = [Int](repeating: 0, count: 19)
        for index in 0..<codeLengthCount {
            codeLengthLengths[order[index]] = try reader.readBits(3)
        }

        let codeLengthDecoder = try HuffmanDecoder(codeLengths: codeLengthLengths)
        let total = literalCount + distanceCount
        var lengths: [Int] = []
        lengths.reserveCapacity(total)

        while lengths.count < total {
            let symbol = try codeLengthDecoder.decode(&reader)
            switch symbol {
            case 0...15:
                lengths.append(symbol)
            case 16:
                guard let previous = lengths.last else {
                    throw ZipArchiveError.invalidArchive("DEFLATE repeat code has no previous length.")
                }
                let repeatCount = try reader.readBits(2) + 3
                guard lengths.count + repeatCount <= total else {
                    throw ZipArchiveError.invalidArchive("DEFLATE code length repeat exceeds the table size.")
                }
                lengths.append(contentsOf: repeatElement(previous, count: repeatCount))
            case 17:
                let repeatCount = try reader.readBits(3) + 3
                guard lengths.count + repeatCount <= total else {
                    throw ZipArchiveError.invalidArchive("DEFLATE code length repeat exceeds the table size.")
                }
                lengths.append(contentsOf: repeatElement(0, count: repeatCount))
            case 18:
                let repeatCount = try reader.readBits(7) + 11
                guard lengths.count + repeatCount <= total else {
                    throw ZipArchiveError.invalidArchive("DEFLATE code length repeat exceeds the table size.")
                }
                lengths.append(contentsOf: repeatElement(0, count: repeatCount))
            default:
                throw ZipArchiveError.invalidArchive("Invalid DEFLATE code-length symbol \(symbol).")
            }
        }

        let literal = try HuffmanDecoder(codeLengths: Array(lengths[0..<literalCount]))
        let distance = try HuffmanDecoder(codeLengths: Array(lengths[literalCount..<total]))
        return (literal, distance)
    }
}

private struct BitReader {
    private let bytes: [UInt8]
    private var byteIndex = 0
    private var bitMask: UInt8 = 0x01

    init(data: Data) {
        self.bytes = [UInt8](data)
    }

    mutating func readBit() throws -> Int {
        guard byteIndex < bytes.count else {
            throw ZipArchiveError.invalidArchive("Unexpected end of DEFLATE stream.")
        }
        let bit = (bytes[byteIndex] & bitMask) == 0 ? 0 : 1
        if bitMask == 0x80 {
            bitMask = 0x01
            byteIndex += 1
        } else {
            bitMask <<= 1
        }
        return bit
    }

    mutating func readBits(_ count: Int) throws -> Int {
        var value = 0
        for index in 0..<count {
            value |= try readBit() << index
        }
        return value
    }

    mutating func alignToByte() {
        if bitMask != 0x01 {
            bitMask = 0x01
            byteIndex += 1
        }
    }

    mutating func readUInt16() throws -> UInt16 {
        let lower = UInt16(try readByte())
        let upper = UInt16(try readByte()) << 8
        return lower | upper
    }

    mutating func readByte() throws -> UInt8 {
        guard byteIndex < bytes.count else {
            throw ZipArchiveError.invalidArchive("Unexpected end of DEFLATE stream.")
        }
        let byte = bytes[byteIndex]
        byteIndex += 1
        return byte
    }

    mutating func readBytes(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, byteIndex + count <= bytes.count else {
            throw ZipArchiveError.invalidArchive("Unexpected end of DEFLATE stream.")
        }
        let slice = bytes[byteIndex..<(byteIndex + count)]
        byteIndex += count
        return slice
    }
}

private struct HuffmanDecoder {
    private let counts: [Int]
    private let symbols: [Int]

    init(codeLengths: [Int]) throws {
        var counts = [Int](repeating: 0, count: 16)
        for length in codeLengths {
            guard length >= 0, length <= 15 else {
                throw ZipArchiveError.invalidArchive("Invalid DEFLATE Huffman code length \(length).")
            }
            counts[length] += 1
        }
        counts[0] = 0

        var left = 1
        for length in 1...15 {
            left <<= 1
            left -= counts[length]
            if left < 0 {
                throw ZipArchiveError.invalidArchive("Oversubscribed DEFLATE Huffman table.")
            }
        }

        var offsets = [Int](repeating: 0, count: 16)
        var total = 0
        for length in 1...15 {
            offsets[length] = total
            total += counts[length]
        }

        var symbols = [Int](repeating: 0, count: total)
        for (symbol, length) in codeLengths.enumerated() where length > 0 {
            guard offsets[length] < symbols.count else {
                throw ZipArchiveError.invalidArchive("Invalid DEFLATE Huffman table.")
            }
            symbols[offsets[length]] = symbol
            offsets[length] += 1
        }

        self.counts = counts
        self.symbols = symbols
    }

    func decode(_ reader: inout BitReader) throws -> Int {
        guard !symbols.isEmpty else {
            throw ZipArchiveError.invalidArchive("DEFLATE stream references an empty Huffman table.")
        }

        var code = 0
        var first = 0
        var index = 0
        for length in 1...15 {
            code |= try reader.readBit()
            let count = counts[length]
            if code - first < count {
                return symbols[index + code - first]
            }
            index += count
            first = (first + count) << 1
            code <<= 1
        }

        throw ZipArchiveError.invalidArchive("Invalid DEFLATE Huffman code.")
    }
}

private struct ByteBuffer {
    private static let maxOutputBytes = 512 * 1024 * 1024
    private static let maxBackReferenceDistance = 32_768

    private var bytes: [UInt8] = []
    private let expectedSize: Int?

    init(expectedSize: Int?) {
        self.expectedSize = expectedSize
        if let expectedSize, expectedSize > 0 {
            bytes.reserveCapacity(expectedSize)
        }
    }

    var count: Int {
        bytes.count
    }

    mutating func append(_ byte: UInt8) throws {
        try ensureCapacity(for: 1)
        bytes.append(byte)
    }

    mutating func append(contentsOf slice: ArraySlice<UInt8>) throws {
        try ensureCapacity(for: slice.count)
        bytes.append(contentsOf: slice)
    }

    mutating func copyBack(distance: Int, length: Int) throws {
        guard distance >= 1, distance <= Self.maxBackReferenceDistance, distance <= bytes.count else {
            throw ZipArchiveError.invalidArchive("Invalid DEFLATE back-reference distance \(distance).")
        }
        try ensureCapacity(for: length)

        var index = bytes.count - distance
        for _ in 0..<length {
            bytes.append(bytes[index])
            index += 1
        }
    }

    func finish() -> Data {
        Data(bytes)
    }

    private func ensureCapacity(for additionalBytes: Int) throws {
        let newCount = bytes.count + additionalBytes
        guard newCount <= Self.maxOutputBytes else {
            throw ZipArchiveError.invalidArchive("DEFLATE stream exceeds the supported output size.")
        }
        if let expectedSize, newCount > expectedSize {
            throw ZipArchiveError.invalidArchive("DEFLATE stream exceeds the expected uncompressed size.")
        }
    }
}

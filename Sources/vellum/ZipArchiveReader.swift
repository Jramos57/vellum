import Foundation

enum ZipCompressionMethod: UInt16 {
    case store = 0
    case deflate = 8
}

struct ZipEntry {
    let path: String
    let compressionMethod: ZipCompressionMethod
    let crc32: UInt32
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int
    let dataOffset: Int

    var isDirectory: Bool {
        path.hasSuffix("/")
    }

    var isCompressed: Bool {
        compressionMethod != .store
    }
}

struct ZipArchiveReader {
    private static let localHeaderSignature: UInt32 = 0x0403_4b50
    private static let centralDirectorySignature: UInt32 = 0x0201_4b50
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50

    let archiveData: Data
    let entries: [ZipEntry]

    init(url: URL) throws {
        do {
            archiveData = try Data(contentsOf: url, options: [.mappedIfSafe])
            entries = try Self.parseEntries(from: archiveData)
        } catch let error as ZipArchiveError {
            throw error
        } catch {
            throw ZipArchiveError.ioFailure("Failed to read ZIP archive at \(url.path): \(error.localizedDescription)")
        }
    }

    func data(for entry: ZipEntry) throws -> Data {
        guard entry.compressedSize >= 0, entry.dataOffset + entry.compressedSize <= archiveData.count else {
            throw ZipArchiveError.invalidArchive("Entry \(entry.path) has an invalid compressed data range.")
        }

        let compressedData = archiveData.subdata(in: entry.dataOffset..<(entry.dataOffset + entry.compressedSize))
        let decompressedData: Data
        switch entry.compressionMethod {
        case .store:
            decompressedData = compressedData
        case .deflate:
            decompressedData = try ZipDeflate.decompress(compressedData)
        }

        guard decompressedData.count == entry.uncompressedSize else {
            throw ZipArchiveError.invalidArchive("Entry \(entry.path) has an invalid uncompressed size.")
        }

        let computedCRC = ZipCRC32.checksum(decompressedData)
        guard computedCRC == entry.crc32 else {
            throw ZipArchiveError.invalidArchive("Entry \(entry.path) failed CRC32 validation.")
        }

        return decompressedData
    }

    private static func parseEntries(from data: Data) throws -> [ZipEntry] {
        let endOfCentralDirectoryOffset = try findEndOfCentralDirectory(in: data)
        let diskNumber = try ZipBinary.readUInt16(from: data, at: endOfCentralDirectoryOffset + 4)
        let startDiskNumber = try ZipBinary.readUInt16(from: data, at: endOfCentralDirectoryOffset + 6)
        let numberOfEntriesThisDisk = try ZipBinary.readUInt16(from: data, at: endOfCentralDirectoryOffset + 8)
        let totalNumberOfEntries = try ZipBinary.readUInt16(from: data, at: endOfCentralDirectoryOffset + 10)
        let centralDirectorySize = try ZipBinary.readUInt32(from: data, at: endOfCentralDirectoryOffset + 12)
        let centralDirectoryOffset = try ZipBinary.readUInt32(from: data, at: endOfCentralDirectoryOffset + 16)

        guard diskNumber == 0, startDiskNumber == 0 else {
            throw ZipArchiveError.unsupported("Multi-disk ZIP archives are not supported.")
        }

        guard numberOfEntriesThisDisk == totalNumberOfEntries else {
            throw ZipArchiveError.unsupported("Split ZIP archives are not supported.")
        }

        if numberOfEntriesThisDisk == UInt16.max
            || centralDirectorySize == UInt32.max
            || centralDirectoryOffset == UInt32.max {
            throw ZipArchiveError.unsupported("ZIP64 archives are not supported.")
        }

        let cdOffset = Int(centralDirectoryOffset)
        let cdSize = Int(centralDirectorySize)
        guard cdOffset >= 0, cdSize >= 0, cdOffset + cdSize <= data.count else {
            throw ZipArchiveError.invalidArchive("Central directory exceeds archive bounds.")
        }

        var entries: [ZipEntry] = []
        entries.reserveCapacity(Int(totalNumberOfEntries))

        var offset = cdOffset
        for _ in 0..<Int(totalNumberOfEntries) {
            let signature = try ZipBinary.readUInt32(from: data, at: offset)
            guard signature == centralDirectorySignature else {
                throw ZipArchiveError.invalidArchive("Invalid central directory record signature.")
            }

            let generalPurposeBitFlag = try ZipBinary.readUInt16(from: data, at: offset + 8)
            let compressionMethodRaw = try ZipBinary.readUInt16(from: data, at: offset + 10)
            let crc32 = try ZipBinary.readUInt32(from: data, at: offset + 16)
            let compressedSizeRaw = try ZipBinary.readUInt32(from: data, at: offset + 20)
            let uncompressedSizeRaw = try ZipBinary.readUInt32(from: data, at: offset + 24)
            let fileNameLength = Int(try ZipBinary.readUInt16(from: data, at: offset + 28))
            let extraFieldLength = Int(try ZipBinary.readUInt16(from: data, at: offset + 30))
            let fileCommentLength = Int(try ZipBinary.readUInt16(from: data, at: offset + 32))
            let diskStartNumber = try ZipBinary.readUInt16(from: data, at: offset + 34)
            let localHeaderOffsetRaw = try ZipBinary.readUInt32(from: data, at: offset + 42)

            if compressedSizeRaw == UInt32.max
                || uncompressedSizeRaw == UInt32.max
                || localHeaderOffsetRaw == UInt32.max {
                throw ZipArchiveError.unsupported("ZIP64 archives are not supported.")
            }

            guard diskStartNumber == 0 else {
                throw ZipArchiveError.unsupported("Multi-disk ZIP archives are not supported.")
            }

            guard (generalPurposeBitFlag & 0x0001) == 0 else {
                throw ZipArchiveError.unsupported("Encrypted ZIP entries are not supported.")
            }

            guard let compressionMethod = ZipCompressionMethod(rawValue: compressionMethodRaw) else {
                throw ZipArchiveError.unsupported("Unsupported ZIP compression method \(compressionMethodRaw).")
            }

            let fileNameOffset = offset + 46
            let fileNameData = try ZipBinary.readData(from: data, at: fileNameOffset, length: fileNameLength)
            let path = String(decoding: fileNameData, as: UTF8.self)
            guard !path.isEmpty else {
                throw ZipArchiveError.invalidArchive("ZIP entry has an empty path.")
            }

            let localHeaderOffset = Int(localHeaderOffsetRaw)
            let dataOffset = try localDataOffset(for: localHeaderOffset, in: data)

            let compressedSize = Int(compressedSizeRaw)
            guard dataOffset + compressedSize <= data.count else {
                throw ZipArchiveError.invalidArchive("Entry \(path) exceeds archive bounds.")
            }

            let entry = ZipEntry(
                path: path,
                compressionMethod: compressionMethod,
                crc32: crc32,
                compressedSize: compressedSize,
                uncompressedSize: Int(uncompressedSizeRaw),
                localHeaderOffset: localHeaderOffset,
                dataOffset: dataOffset
            )
            entries.append(entry)

            offset = fileNameOffset + fileNameLength + extraFieldLength + fileCommentLength
        }

        return entries
    }

    private static func localDataOffset(for localHeaderOffset: Int, in data: Data) throws -> Int {
        let signature = try ZipBinary.readUInt32(from: data, at: localHeaderOffset)
        guard signature == localHeaderSignature else {
            throw ZipArchiveError.invalidArchive("Invalid local file header signature.")
        }

        let fileNameLength = Int(try ZipBinary.readUInt16(from: data, at: localHeaderOffset + 26))
        let extraFieldLength = Int(try ZipBinary.readUInt16(from: data, at: localHeaderOffset + 28))
        let offset = localHeaderOffset + 30 + fileNameLength + extraFieldLength
        guard offset <= data.count else {
            throw ZipArchiveError.invalidArchive("Invalid local file header offsets.")
        }
        return offset
    }

    private static func findEndOfCentralDirectory(in data: Data) throws -> Int {
        let endRecordMinimumLength = 22
        guard data.count >= endRecordMinimumLength else {
            throw ZipArchiveError.invalidArchive("Archive is too small to be a ZIP file.")
        }

        let maxCommentLength = 65_535
        let searchStart = max(0, data.count - (endRecordMinimumLength + maxCommentLength))
        let searchEnd = data.count - endRecordMinimumLength

        for offset in stride(from: searchEnd, through: searchStart, by: -1) {
            guard let signature = try? ZipBinary.readUInt32(from: data, at: offset),
                  signature == endOfCentralDirectorySignature else {
                continue
            }

            let commentLength = Int(try ZipBinary.readUInt16(from: data, at: offset + 20))
            let recordEnd = offset + endRecordMinimumLength + commentLength
            guard recordEnd <= data.count else {
                continue
            }
            return offset
        }

        throw ZipArchiveError.invalidArchive("Missing ZIP end of central directory record.")
    }
}

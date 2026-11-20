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
    let limits: ZIPResourceLimits

    init(url: URL, limits: ZIPResourceLimits = .default) throws {
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let parsedEntries = try Self.parseEntries(from: data)
            try Self.validateDeclaredSizes(parsedEntries, limits: limits)
            archiveData = data
            entries = parsedEntries
            self.limits = limits
        } catch let error as ZipArchiveError {
            throw error
        } catch {
            throw ZipArchiveError.ioFailure("Failed to read ZIP archive at \(url.path): \(error.localizedDescription)")
        }
    }

    func data(for entry: ZipEntry) throws -> Data {
        // Re-validate the entry even though `init` already checked the parsed entries:
        // callers can hand in a forged `ZipEntry` and must not be able to trigger a
        // proportional allocation beyond the archive's configured per-entry limit.
        guard entry.uncompressedSize >= 0 else {
            throw ZipArchiveError.invalidArchive("Entry \(entry.path) has a negative uncompressed size.")
        }
        guard entry.uncompressedSize <= limits.maxEntryByteCount else {
            throw ZipArchiveError.resourceLimitExceeded(
                "Entry \(entry.path) declares \(entry.uncompressedSize) uncompressed bytes, above the "
                    + "\(limits.maxEntryByteCount)-byte per-entry limit."
            )
        }
        guard entry.compressedSize >= 0,
              entry.dataOffset >= 0,
              entry.dataOffset <= archiveData.count,
              entry.compressedSize <= archiveData.count - entry.dataOffset else {
            throw ZipArchiveError.invalidArchive("Entry \(entry.path) has an invalid compressed data range.")
        }

        // Stored entries are already uncompressed. Reject inconsistent sizes before
        // copying their payload, not after allocating an attacker-sized Data value.
        if entry.compressionMethod == .store, entry.compressedSize != entry.uncompressedSize {
            throw ZipArchiveError.invalidArchive("Stored entry \(entry.path) has inconsistent sizes.")
        }
        let compressedData = archiveData.subdata(in: entry.dataOffset..<(entry.dataOffset + entry.compressedSize))
        let decompressedData: Data
        switch entry.compressionMethod {
        case .store:
            decompressedData = compressedData
        case .deflate:
            decompressedData = try ZipInflate.decompress(
                compressedData,
                expectedSize: entry.uncompressedSize,
                expectedCRC32: entry.crc32,
                maxOutputBytes: limits.maxEntryByteCount
            )
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

    /// Rejects archives whose declared uncompressed sizes exceed the configured
    /// per-entry or per-archive budget. This runs during initialization, before any
    /// extraction, so a hostile declaration is never used to size a buffer.
    private static func validateDeclaredSizes(_ entries: [ZipEntry], limits: ZIPResourceLimits) throws {
        guard limits.maxEntryByteCount >= 0, limits.maxTotalByteCount >= 0 else {
            throw ZipArchiveError.resourceLimitExceeded("ZIP resource limits must not be negative.")
        }

        var declaredTotal = 0
        for entry in entries {
            let declared = entry.uncompressedSize
            guard declared >= 0 else {
                throw ZipArchiveError.invalidArchive("Entry \(entry.path) has a negative uncompressed size.")
            }
            guard declared <= limits.maxEntryByteCount else {
                throw ZipArchiveError.resourceLimitExceeded(
                    "Entry \(entry.path) declares \(declared) uncompressed bytes, above the "
                        + "\(limits.maxEntryByteCount)-byte per-entry limit."
                )
            }

            let (runningTotal, overflow) = declaredTotal.addingReportingOverflow(declared)
            guard !overflow, runningTotal <= limits.maxTotalByteCount else {
                throw ZipArchiveError.resourceLimitExceeded(
                    "Archive declares more than the \(limits.maxTotalByteCount)-byte aggregate uncompressed budget."
                )
            }
            declaredTotal = runningTotal
        }
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

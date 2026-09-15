import Foundation

struct ZipArchiveWriter {
    struct Entry {
        let path: String
        let data: Data
        let compressionMethod: ZipCompressionMethod
        let crc32Override: UInt32?

        init(
            path: String,
            data: Data,
            compressionMethod: ZipCompressionMethod,
            crc32Override: UInt32? = nil
        ) {
            self.path = path
            self.data = data
            self.compressionMethod = compressionMethod
            self.crc32Override = crc32Override
        }
    }

    private struct CentralDirectoryRecord {
        let path: String
        let compressionMethod: ZipCompressionMethod
        let crc32: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32
    }

    private static let localHeaderSignature: UInt32 = 0x0403_4b50
    private static let centralDirectorySignature: UInt32 = 0x0201_4b50
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50

    static func write(entries: [Entry], to archiveURL: URL) throws {
        guard FileManager.default.createFile(atPath: archiveURL.path, contents: nil) else {
            throw ZipArchiveError.ioFailure("Failed to create archive at \(archiveURL.path).")
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: archiveURL)
        } catch {
            throw ZipArchiveError.ioFailure("Failed to open archive for writing at \(archiveURL.path): \(error.localizedDescription)")
        }

        defer {
            try? handle.close()
        }

        var offset = 0
        var centralDirectoryRecords: [CentralDirectoryRecord] = []
        centralDirectoryRecords.reserveCapacity(entries.count)

        for entry in entries {
            let pathData = Data(entry.path.utf8)
            guard !pathData.isEmpty else {
                throw ZipArchiveError.invalidArchive("ZIP entry path cannot be empty.")
            }
            guard pathData.count <= Int(UInt16.max) else {
                throw ZipArchiveError.unsupported("ZIP entry path exceeds supported length.")
            }

            let compressedData: Data
            switch entry.compressionMethod {
            case .store:
                compressedData = entry.data
            case .deflate:
                compressedData = try ZipDeflate.compress(entry.data)
            }

            guard entry.data.count <= Int(UInt32.max), compressedData.count <= Int(UInt32.max) else {
                throw ZipArchiveError.unsupported("ZIP entry size exceeds non-ZIP64 limits.")
            }
            guard offset <= Int(UInt32.max) else {
                throw ZipArchiveError.unsupported("Archive exceeds non-ZIP64 offset limits.")
            }

            let crc32 = entry.crc32Override ?? ZipCRC32.checksum(entry.data)
            let localHeaderOffset = UInt32(offset)

            var localHeader = Data()
            localHeader.appendLittleEndian(localHeaderSignature)
            localHeader.appendLittleEndian(UInt16(20))
            localHeader.appendLittleEndian(UInt16(0))
            localHeader.appendLittleEndian(entry.compressionMethod.rawValue)
            localHeader.appendLittleEndian(UInt16(0))
            localHeader.appendLittleEndian(UInt16(0))
            localHeader.appendLittleEndian(crc32)
            localHeader.appendLittleEndian(UInt32(compressedData.count))
            localHeader.appendLittleEndian(UInt32(entry.data.count))
            localHeader.appendLittleEndian(UInt16(pathData.count))
            localHeader.appendLittleEndian(UInt16(0))
            localHeader.append(pathData)

            try write(localHeader, to: handle, offset: &offset)
            try write(compressedData, to: handle, offset: &offset)

            centralDirectoryRecords.append(
                CentralDirectoryRecord(
                    path: entry.path,
                    compressionMethod: entry.compressionMethod,
                    crc32: crc32,
                    compressedSize: UInt32(compressedData.count),
                    uncompressedSize: UInt32(entry.data.count),
                    localHeaderOffset: localHeaderOffset
                )
            )
        }

        guard centralDirectoryRecords.count <= Int(UInt16.max) else {
            throw ZipArchiveError.unsupported("ZIP entry count exceeds non-ZIP64 limits.")
        }
        guard offset <= Int(UInt32.max) else {
            throw ZipArchiveError.unsupported("Archive exceeds non-ZIP64 offset limits.")
        }

        let centralDirectoryOffset = UInt32(offset)

        for record in centralDirectoryRecords {
            let pathData = Data(record.path.utf8)
            var centralHeader = Data()
            centralHeader.appendLittleEndian(centralDirectorySignature)
            centralHeader.appendLittleEndian(UInt16(20))
            centralHeader.appendLittleEndian(UInt16(20))
            centralHeader.appendLittleEndian(UInt16(0))
            centralHeader.appendLittleEndian(record.compressionMethod.rawValue)
            centralHeader.appendLittleEndian(UInt16(0))
            centralHeader.appendLittleEndian(UInt16(0))
            centralHeader.appendLittleEndian(record.crc32)
            centralHeader.appendLittleEndian(record.compressedSize)
            centralHeader.appendLittleEndian(record.uncompressedSize)
            centralHeader.appendLittleEndian(UInt16(pathData.count))
            centralHeader.appendLittleEndian(UInt16(0))
            centralHeader.appendLittleEndian(UInt16(0))
            centralHeader.appendLittleEndian(UInt16(0))
            centralHeader.appendLittleEndian(UInt16(0))
            centralHeader.appendLittleEndian(UInt32(0))
            centralHeader.appendLittleEndian(record.localHeaderOffset)
            centralHeader.append(pathData)

            try write(centralHeader, to: handle, offset: &offset)
        }

        let centralDirectorySize = UInt32(offset) - centralDirectoryOffset

        var endOfCentralDirectory = Data()
        endOfCentralDirectory.appendLittleEndian(endOfCentralDirectorySignature)
        endOfCentralDirectory.appendLittleEndian(UInt16(0))
        endOfCentralDirectory.appendLittleEndian(UInt16(0))
        endOfCentralDirectory.appendLittleEndian(UInt16(centralDirectoryRecords.count))
        endOfCentralDirectory.appendLittleEndian(UInt16(centralDirectoryRecords.count))
        endOfCentralDirectory.appendLittleEndian(centralDirectorySize)
        endOfCentralDirectory.appendLittleEndian(centralDirectoryOffset)
        endOfCentralDirectory.appendLittleEndian(UInt16(0))

        try write(endOfCentralDirectory, to: handle, offset: &offset)
    }

    private static func write(_ data: Data, to handle: FileHandle, offset: inout Int) throws {
        do {
            try handle.write(contentsOf: data)
            offset += data.count
        } catch {
            throw ZipArchiveError.ioFailure("Failed while writing ZIP archive: \(error.localizedDescription)")
        }
    }
}

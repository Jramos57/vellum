import Foundation
import zlib

enum ZipDeflate {
    static func compress(_ data: Data) throws -> Data {
        var stream = z_stream()
        let initStatus = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            -MAX_WBITS,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )

        guard initStatus == Z_OK else {
            throw ZipArchiveError.ioFailure("Failed to initialize zlib deflate stream (status: \(initStatus)).")
        }
        defer { deflateEnd(&stream) }

        return try data.withUnsafeBytes { inputBytes in
            let input = inputBytes.bindMemory(to: Bytef.self)
            stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress)
            stream.avail_in = uInt(input.count)

            var output = Data()
            let chunkSize = 64 * 1024
            var status: Int32 = Z_OK

            repeat {
                var buffer = [UInt8](repeating: 0, count: chunkSize)
                let produced = try buffer.withUnsafeMutableBytes { outputBytes -> Int in
                    let bytes = outputBytes.bindMemory(to: Bytef.self)
                    stream.next_out = bytes.baseAddress
                    stream.avail_out = uInt(chunkSize)

                    status = deflate(&stream, Z_FINISH)
                    if status != Z_OK && status != Z_STREAM_END {
                        throw ZipArchiveError.ioFailure("Failed to deflate ZIP entry (status: \(status)).")
                    }

                    return chunkSize - Int(stream.avail_out)
                }

                if produced > 0 {
                    output.append(buffer, count: produced)
                }
            } while status != Z_STREAM_END

            return output
        }
    }

    static func decompress(_ data: Data) throws -> Data {
        var stream = z_stream()
        let initStatus = inflateInit2_(
            &stream,
            -MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )

        guard initStatus == Z_OK else {
            throw ZipArchiveError.ioFailure("Failed to initialize zlib inflate stream (status: \(initStatus)).")
        }
        defer { inflateEnd(&stream) }

        return try data.withUnsafeBytes { inputBytes in
            let input = inputBytes.bindMemory(to: Bytef.self)
            stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress)
            stream.avail_in = uInt(input.count)

            var output = Data()
            let chunkSize = 64 * 1024
            var status: Int32 = Z_OK

            repeat {
                var buffer = [UInt8](repeating: 0, count: chunkSize)
                let produced = try buffer.withUnsafeMutableBytes { outputBytes -> Int in
                    let bytes = outputBytes.bindMemory(to: Bytef.self)
                    stream.next_out = bytes.baseAddress
                    stream.avail_out = uInt(chunkSize)

                    status = inflate(&stream, Z_NO_FLUSH)
                    if status != Z_OK && status != Z_STREAM_END {
                        throw ZipArchiveError.invalidArchive("Failed to inflate ZIP entry (status: \(status)).")
                    }

                    return chunkSize - Int(stream.avail_out)
                }

                if produced > 0 {
                    output.append(buffer, count: produced)
                }
            } while status != Z_STREAM_END

            return output
        }
    }
}

import Foundation
import zlib

/// Minimal gzip (RFC 1952) compressor used to match the reference producer's
/// wire format when a request body reaches the size threshold. Backed by the
/// system zlib with a gzip-framed deflate stream (windowBits 15 + 16).
public enum GzipCompressor {
    /// Compresses the input into a gzip stream. Returns nil if zlib reports an
    /// initialization or stream error, letting the caller fall back to sending
    /// the body uncompressed rather than failing the request outright.
    public static func compress(_ input: Data) -> Data? {
       if input.isEmpty {
           // Still produce a valid (empty-payload) gzip stream for consistency.
            return gzipDeflate(Data())
       }
        return gzipDeflate(input)
    }

    private static func gzipDeflate(_ input: Data) -> Data? {
        var stream = z_stream()
        let windowBits: Int32 = 15 + 16 // 15 = max window, +16 = gzip wrapper
        let memLevel: Int32 = 8
        let initResult = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            windowBits,
            memLevel,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initResult == Z_OK else { return nil }
        defer { deflateEnd(&stream) }

        var output = Data()
        let chunkSize = 16 * 1024
        var outBuffer = [UInt8](repeating: 0, count: chunkSize)

        var result: Int32 = Z_OK
        let success = input.withUnsafeBytes { (rawInput: UnsafeRawBufferPointer) -> Bool in
            let inputBase = rawInput.bindMemory(to: UInt8.self).baseAddress
            stream.next_in = UnsafeMutablePointer(mutating: inputBase)
            stream.avail_in = uInt(input.count)

            repeat {
                let flushed: Bool = outBuffer.withUnsafeMutableBufferPointer { outPtr -> Bool in
                    stream.next_out = outPtr.baseAddress
                   stream.avail_out = uInt(chunkSize)
                    result = zlib.deflate(&stream, Z_FINISH)
                   if result == Z_STREAM_ERROR { return false }
                    let produced = chunkSize - Int(stream.avail_out)
                    if produced > 0 {
                        output.append(outPtr.baseAddress!, count: produced)
                    }
                    return true
                }
                if !flushed { return false }
            } while result != Z_STREAM_END
            return true
        }

        return success ? output : nil
    }
}

import Foundation

/// Reads a fixed stat snapshot even when the writer keeps appending.
@_spi(Verification)
public enum RuntimeFileSnapshotReader {
    public enum ReadError: Error {
        case invalidByteCount
        case unexpectedEnd
        case oversizedChunk
    }

    private static let chunkBytes = 64 * 1024

    public static func read(
        byteCount: Int,
        readChunk: (Int) throws -> Data?
    ) throws -> Data {
        guard byteCount >= 0 else { throw ReadError.invalidByteCount }
        var data = Data()
        data.reserveCapacity(byteCount)
        while data.count < byteCount {
            let requested = min(chunkBytes, byteCount - data.count)
            guard let chunk = try readChunk(requested), !chunk.isEmpty else {
                throw ReadError.unexpectedEnd
            }
            guard chunk.count <= requested else { throw ReadError.oversizedChunk }
            data.append(chunk)
        }
        return data
    }

    public static func read(from file: URL, offset: UInt64 = 0, byteCount: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try read(byteCount: byteCount) { try handle.read(upToCount: $0) }
    }
}

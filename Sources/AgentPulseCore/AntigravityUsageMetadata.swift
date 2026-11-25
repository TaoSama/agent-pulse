import Foundation

/// Reads the stable field numbers used by Antigravity's conversation database.
/// Other fields can contain prompts or replies and are skipped without decoding.
enum AntigravityUsageMetadata {
    enum DecodeError: Error { case invalidWireFormat, invalidUsage }

    struct Generation {
        let responseID: String
        let model: String
        let counts: UsageTokenCounts
        let firstStep: Int64
    }

    // A single count cannot reasonably approach Int64.max. Reject unsupported
    // values before they can overflow totals across several dimensions.
    private static let maximumTokenCount: UInt64 = UInt64(Int32.max)
    private static let maximumIdentifierBytes = 512
    private static let maximumModelBytes = 128
    private static let maximumTimestamp: UInt64 = 253_402_300_799

    static func generation(_ bytes: Data) throws -> Generation? {
        let message = Message(bytes)
        var fields = message.reader()
        var modelMetadata: Range<Int>?
        var firstStep: UInt64?
        while let field = try fields.next() {
            switch (field.number, field.value) {
            case (1, let .bytes(range)): modelMetadata = range
            case (2, let .varint(index)): if firstStep == nil { firstStep = index }
            case (2, let .bytes(range)):
                if firstStep == nil && !range.isEmpty {
                    var packed = message.reader(range)
                    firstStep = try packed.varint()
                }
            default: break
            }
        }
        guard let modelMetadata else { return nil }

        var chat = message.reader(modelMetadata)
        var usage: Range<Int>?
        var responseModel: Range<Int>?
        var fullModel: Range<Int>?
        var displayModel: Range<Int>?
        while let field = try chat.next() {
            guard case let .bytes(range) = field.value else { continue }
            switch field.number {
            case 4: usage = range
            case 19: responseModel = range
            case 21: displayModel = range
            case 22: fullModel = range
            default: break
            }
        }
        guard let usage else { return nil }

        var stats = message.reader(usage)
        var input: UInt64 = 0
        var output: UInt64?
        var write: UInt64 = 0
        var cache: UInt64 = 0
        var reasoning: UInt64 = 0
        var response: UInt64?
        var responseID: Range<Int>?
        while let field = try stats.next() {
            switch (field.number, field.value) {
            case (2, let .varint(value)): input = value
            case (3, let .varint(value)): output = value
            case (4, let .varint(value)): write = value
            case (5, let .varint(value)): cache = value
            case (9, let .varint(value)): reasoning = value
            case (10, let .varint(value)): response = value
            case (11, let .bytes(range)): responseID = range
            default: break
            }
        }
        // Input excludes cached counts. The stored output total includes
        // reasoning, while the response field counts only displayed output.
        guard [input, output ?? 0, write, cache, reasoning, response ?? 0]
            .allSatisfy({ $0 <= maximumTokenCount }) else { throw DecodeError.invalidUsage }
        let inclusiveOutput = output ?? ((response ?? 0) + reasoning)
        guard inclusiveOutput >= reasoning,
              response.map({ $0 == inclusiveOutput - reasoning }) ?? true
        else { throw DecodeError.invalidUsage }

        let counts = UsageTokenCounts(input: Int64(input), output: Int64(inclusiveOutput - reasoning),
                                     cachedInput: Int64(cache), cacheCreationInput: Int64(write),
                                     reasoningOutput: Int64(reasoning))
        guard counts.total > 0 else { return nil }
        guard let responseID = message.string(responseID, maximumBytes: maximumIdentifierBytes),
              let firstStep, firstStep <= UInt32.max
        else { throw DecodeError.invalidUsage }

        let model = [fullModel, responseModel, displayModel].lazy
            .compactMap { message.string($0, maximumBytes: maximumModelBytes) }.first ?? "unknown"
        return Generation(responseID: responseID, model: model, counts: counts, firstStep: Int64(firstStep))
    }

    static func createdAt(_ bytes: Data) throws -> Date {
        let message = Message(bytes)
        var metadata = message.reader()
        while let field = try metadata.next() {
            guard field.number == 1, case let .bytes(range) = field.value else { continue }
            var timestamp = message.reader(range)
            var seconds: UInt64 = 0
            var nanos: UInt64 = 0
            while let time = try timestamp.next() {
                switch (time.number, time.value) {
                case (1, let .varint(value)): seconds = value
                case (2, let .varint(value)): nanos = value
                default: break
                }
            }
            guard seconds > 0, seconds <= maximumTimestamp, nanos < 1_000_000_000
            else { throw DecodeError.invalidUsage }
            return Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)
        }
        throw DecodeError.invalidUsage
    }

    private struct Message {
        let bytes: [UInt8]
        init(_ data: Data) { bytes = Array(data) }

        func reader(_ range: Range<Int>? = nil) -> FieldReader {
            FieldReader(bytes: bytes, range: range ?? bytes.indices)
        }

        func string(_ field: Range<Int>?, maximumBytes: Int) -> String? {
            guard let field, (1...maximumBytes).contains(field.count),
                  let text = String(bytes: bytes[field], encoding: .utf8),
                  !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private struct FieldReader {
        enum Value {
            case varint(UInt64)
            case bytes(Range<Int>)
            case ignored
        }

        let bytes: [UInt8]
        let end: Int
        var index: Int

        init(bytes: [UInt8], range: Range<Int>) {
            self.bytes = bytes
            end = range.upperBound
            index = range.lowerBound
        }

        mutating func next() throws -> (number: UInt64, value: Value)? {
            guard index < end else { return nil }
            let tag = try varint()
            let number = tag >> 3
            guard number > 0, number < (1 << 29) else { throw DecodeError.invalidWireFormat }
            switch tag & 7 {
            case 0: return (number, .varint(try varint()))
            case 1:
                _ = try advance(8)
                return (number, .ignored)
            case 2:
                let length = try varint()
                guard length <= UInt64(end - index) else { throw DecodeError.invalidWireFormat }
                return (number, .bytes(try advance(Int(length))))
            case 5:
                _ = try advance(4)
                return (number, .ignored)
            default: throw DecodeError.invalidWireFormat
            }
        }

        mutating func varint() throws -> UInt64 {
            var result: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard index < end else { throw DecodeError.invalidWireFormat }
                let byte = bytes[index]
                index += 1
                if shift == 63 && byte > 1 { throw DecodeError.invalidWireFormat }
                result |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 { return result }
            }
            throw DecodeError.invalidWireFormat
        }

        private mutating func advance(_ length: Int) throws -> Range<Int> {
            guard length <= end - index else { throw DecodeError.invalidWireFormat }
            let start = index
            index += length
            return start..<index
        }
    }
}

import Foundation

/// Statistics-only state mutations committed atomically with a parser batch.
public struct UsageParserStateChanges: Sendable {
    public let values: [String: Data]
    public let removedKeys: [String]

    public init(values: [String: Data], removedKeys: [String]) {
        self.values = values
        self.removedKeys = removedKeys
    }
}

/// A batch reads only the identities it touches. The ledger owns durable state;
/// this short-lived cache never loads an entire session's history.
final class UsageParserState {
    let lookup: (String) throws -> Data?
    var values: [String: Data] = [:]
    var removedKeys = Set<String>()
    var firstError: Error?
    var removedEventIDs = Set<String>()
    var removedEditIDs = Set<String>()
    var codexUnknownModel: String?

    init(lookup: @escaping (String) throws -> Data? = { _ in nil }) {
        self.lookup = lookup
    }

    func read<Value: Codable>(_ key: String, as: Value.Type) -> Value? {
        do {
            if removedKeys.contains(key) { return nil }
            guard let data = try values[key] ?? lookup(key) else { return nil }
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            if firstError == nil { firstError = error }
            return nil
        }
    }

    func write<Value: Codable>(_ value: Value?, key: String) {
        do {
            if let value {
                values[key] = try JSONEncoder().encode(value)
                removedKeys.remove(key)
            } else {
                values[key] = nil
                removedKeys.insert(key)
            }
        } catch {
            if firstError == nil { firstError = error }
        }
    }

    /// Subscripts cannot throw; surface every deferred storage/codec failure
    /// before returning results, so no incomplete batch can be committed.
    func changes() throws -> UsageParserStateChanges {
        if let firstError { throw firstError }
        return UsageParserStateChanges(values: values, removedKeys: Array(removedKeys))
    }
}

struct UsageParserMap<Value: Codable>: Sequence {
    private let state: UsageParserState
    private let namespace: String
    private var loaded: [String: Value] = [:]
    private var missing = Set<String>()

    init(_ namespace: String, state: UsageParserState) {
        self.namespace = namespace
        self.state = state
    }

    private func storageKey(_ key: String) -> String {
        namespace + ":" + ContentDigest.sha256(key)
    }

    subscript(key: String) -> Value? {
        mutating get {
            if let value = loaded[key] { return value }
            if missing.contains(key) { return nil }
            guard let value = state.read(storageKey(key), as: Value.self) else {
                missing.insert(key)
                return nil
            }
            loaded[key] = value
            return value
        }
        set {
            loaded[key] = newValue
            if newValue == nil { missing.insert(key) } else { missing.remove(key) }
            state.write(newValue, key: storageKey(key))
        }
    }

    subscript(key: String, default defaultValue: @autoclosure () -> Value) -> Value {
        mutating get { self[key] ?? defaultValue() }
        set { self[key] = newValue }
    }

    var keys: Set<String> { Set(loaded.keys).union(missing) }
    var values: Dictionary<String, Value>.Values { loaded.values }
    func makeIterator() -> Dictionary<String, Value>.Iterator { loaded.makeIterator() }
}

struct UsageParserSet {
    private var entries: UsageParserMap<Bool>

    init(_ namespace: String, state: UsageParserState) {
        entries = UsageParserMap(namespace, state: state)
    }

    @discardableResult
    mutating func insert(_ key: String) -> (inserted: Bool, memberAfterInsert: String) {
        let inserted = entries[key] != true
        if inserted { entries[key] = true }
        return (inserted, key)
    }

    mutating func contains(_ key: String) -> Bool { entries[key] == true }
}

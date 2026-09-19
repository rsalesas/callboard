// An ordered JSON value (PD14).
//
// The project file is `JSON.stringify(document, null, 2) + "\n"`, and
// JavaScript writes an object's keys in the order they were inserted. That
// order is therefore part of the bytes on disk, and neither `JSONEncoder`
// nor `JSONSerialization` keeps it — so the engine carries its own value
// type, and every place that builds an object decides its key order by
// building it in that order, exactly as the TypeScript does.
//
// `==` is what Swift synthesises: order-sensitive, exact. Comparing two
// trees the way a test's `toEqual` would — keys in any order, numbers
// within a tolerance — is `matches(_:tolerance:)`.

public enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object(JSONObject)
}

/// An object whose keys keep JavaScript's own order: integer-like keys
/// first, ascending, then every other key in the order it was first set.
/// Setting a key that exists replaces its value where it stands.
public struct JSONObject: Sendable, Equatable {
    public private(set) var keys: [String] = []
    private var values: [String: JSON] = [:]

    public init() {}

    public init(_ pairs: [(String, JSON)]) {
        for (key, value) in pairs { self[key] = value }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    /// The pairs, in the order `JSON.stringify` would write them.
    public var pairs: [(key: String, value: JSON)] { keys.map { ($0, values[$0]!) } }

    public func has(_ key: String) -> Bool { values[key] != nil }

    public subscript(key: String) -> JSON? {
        get { values[key] }
        set {
            guard let newValue else {
                if values.removeValue(forKey: key) != nil { keys.removeAll { $0 == key } }
                return
            }
            if values.updateValue(newValue, forKey: key) == nil { insert(key) }
        }
    }

    /// ECMAScript's OrdinaryOwnPropertyKeys: array indices ascending, then
    /// strings by insertion. No document field is an index today; an
    /// id-keyed map that one day holds a stand-in called "7" would be, and
    /// the file it wrote would differ from the old engine's by exactly this.
    private mutating func insert(_ key: String) {
        guard let index = Self.arrayIndex(key) else { keys.append(key); return }
        var at = 0
        while at < keys.count, let other = Self.arrayIndex(keys[at]), other < index { at += 1 }
        keys.insert(key, at: at)
    }

    /// A canonical array index: a decimal integer below 2³²−1 with no sign,
    /// no leading zero and nothing after it.
    static func arrayIndex(_ key: String) -> UInt32? {
        guard !key.isEmpty, key.utf8.count <= 10, key.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        if key.utf8.count > 1, key.utf8.first == 0x30 { return nil }
        guard let n = UInt64(key), n < 4_294_967_295 else { return nil }
        return UInt32(n)
    }
}

// MARK: - Reading

extension JSON {
    public var isNull: Bool { if case .null = self { true } else { false } }
    public var boolValue: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var numberValue: Double? { if case .number(let v) = self { v } else { nil } }
    public var stringValue: String? { if case .string(let v) = self { v } else { nil } }
    public var arrayValue: [JSON]? { if case .array(let v) = self { v } else { nil } }
    public var objectValue: JSONObject? { if case .object(let v) = self { v } else { nil } }

    /// `value["key"]` — nil for a missing key and for anything that is not
    /// an object, which is what optional chaining gives in the TypeScript.
    public subscript(key: String) -> JSON? { objectValue?[key] }

    public subscript(index: Int) -> JSON? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }

    /// Deep equality the way a test means it: object keys in any order,
    /// numbers equal within `tolerance`. Everything else is exact.
    public func matches(_ other: JSON, tolerance: Double = 0) -> Bool {
        switch (self, other) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b || abs(a - b) <= tolerance
        case (.array(let a), .array(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.matches($1, tolerance: tolerance) }
        case (.object(let a), .object(let b)):
            return a.count == b.count && a.keys.allSatisfy { key in
                guard let theirs = b[key] else { return false }
                return a[key]!.matches(theirs, tolerance: tolerance)
            }
        default: return false
        }
    }
}

// MARK: - Writing literals

extension JSON: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    /// A dictionary *literal* is an ordered list of pairs, so this keeps the
    /// order it was written in — which is the point.
    public init(dictionaryLiteral elements: (String, JSON)...) { self = .object(JSONObject(elements)) }
}

// A JSON parser that keeps key order (PD14).
//
// RFC 8259, strict, over UTF-8 bytes. A duplicate key behaves as it does in
// `JSON.parse`: the later value wins and the key stays where it first
// appeared. Numbers go through the platform's correctly rounded
// string-to-double, as V8's do, so a value read here is the value the old
// engine read from the same file.

public struct JSONParseError: Error, Equatable, CustomStringConvertible {
    public let offset: Int
    public let message: String
    public var description: String { "\(message) at byte \(offset)" }
}

extension JSON {
    public static func parse(_ text: String) throws -> JSON {
        var parser = Parser(bytes: Array(text.utf8))
        return try parser.document()
    }

    public static func parse(bytes: [UInt8]) throws -> JSON {
        var parser = Parser(bytes: bytes)
        return try parser.document()
    }
}

private struct Parser {
    let bytes: [UInt8]
    var at = 0
    var depth = 0

    /// Deep enough for anything the engine reads, shallow enough that a
    /// hostile file cannot run the stack out.
    static let maxDepth = 256

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func document() throws -> JSON {
        // A BOM is not JSON, but a file saved by some editors has one, and
        // `JSON.parse` would have refused it too — so refuse it, by name.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { throw fail("a byte-order mark before the document") }
        skipSpace()
        let value = try value()
        skipSpace()
        if at != bytes.count { throw fail("something after the end of the document") }
        return value
    }

    func fail(_ message: String) -> JSONParseError { JSONParseError(offset: at, message: message) }

    mutating func skipSpace() {
        while at < bytes.count, bytes[at] == 0x20 || bytes[at] == 0x0A || bytes[at] == 0x0D || bytes[at] == 0x09 { at += 1 }
    }

    mutating func value() throws -> JSON {
        guard at < bytes.count else { throw fail("the document ends where a value should be") }
        switch bytes[at] {
        case UInt8(ascii: "{"): return try object()
        case UInt8(ascii: "["): return try array()
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try number())
        default: throw fail("not the start of a value")
        }
    }

    mutating func literal(_ word: StaticString) throws {
        let expected = Array(word.description.utf8)
        guard at + expected.count <= bytes.count, Array(bytes[at..<at + expected.count]) == expected else {
            throw fail("expected \(word)")
        }
        at += expected.count
    }

    mutating func object() throws -> JSON {
        depth += 1; defer { depth -= 1 }
        if depth > Self.maxDepth { throw fail("nested too deeply") }
        at += 1
        var out = JSONObject()
        skipSpace()
        if at < bytes.count, bytes[at] == UInt8(ascii: "}") { at += 1; return .object(out) }
        while true {
            skipSpace()
            guard at < bytes.count, bytes[at] == UInt8(ascii: "\"") else { throw fail("expected a key") }
            let key = try string()
            skipSpace()
            guard at < bytes.count, bytes[at] == UInt8(ascii: ":") else { throw fail("expected ':' after a key") }
            at += 1
            skipSpace()
            out[key] = try value()
            skipSpace()
            guard at < bytes.count else { throw fail("the document ends inside an object") }
            if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
            if bytes[at] == UInt8(ascii: "}") { at += 1; return .object(out) }
            throw fail("expected ',' or '}'")
        }
    }

    mutating func array() throws -> JSON {
        depth += 1; defer { depth -= 1 }
        if depth > Self.maxDepth { throw fail("nested too deeply") }
        at += 1
        var out: [JSON] = []
        skipSpace()
        if at < bytes.count, bytes[at] == UInt8(ascii: "]") { at += 1; return .array(out) }
        while true {
            skipSpace()
            out.append(try value())
            skipSpace()
            guard at < bytes.count else { throw fail("the document ends inside an array") }
            if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
            if bytes[at] == UInt8(ascii: "]") { at += 1; return .array(out) }
            throw fail("expected ',' or ']'")
        }
    }

    mutating func number() throws -> Double {
        let start = at
        if bytes[at] == UInt8(ascii: "-") { at += 1 }
        guard at < bytes.count else { throw fail("a sign with no number") }
        if bytes[at] == UInt8(ascii: "0") {
            at += 1
        } else if bytes[at] >= UInt8(ascii: "1"), bytes[at] <= UInt8(ascii: "9") {
            while at < bytes.count, isDigit(bytes[at]) { at += 1 }
        } else {
            throw fail("a sign with no number")
        }
        if at < bytes.count, bytes[at] == UInt8(ascii: ".") {
            at += 1
            guard at < bytes.count, isDigit(bytes[at]) else { throw fail("a decimal point with no digits after it") }
            while at < bytes.count, isDigit(bytes[at]) { at += 1 }
        }
        if at < bytes.count, bytes[at] == UInt8(ascii: "e") || bytes[at] == UInt8(ascii: "E") {
            at += 1
            if at < bytes.count, bytes[at] == UInt8(ascii: "+") || bytes[at] == UInt8(ascii: "-") { at += 1 }
            guard at < bytes.count, isDigit(bytes[at]) else { throw fail("an exponent with no digits") }
            while at < bytes.count, isDigit(bytes[at]) { at += 1 }
        }
        // The grammar above admits only what strtod reads the same way, so
        // this cannot fail — and an overflow is ±infinity, as in JavaScript.
        return Double(String(decoding: bytes[start..<at], as: UTF8.self))!
    }

    func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

    mutating func string() throws -> String {
        at += 1
        var out: [UInt8] = []
        while true {
            guard at < bytes.count else { throw fail("the document ends inside a string") }
            let byte = bytes[at]
            if byte == UInt8(ascii: "\"") { at += 1; break }
            if byte < 0x20 { throw fail("a raw control character inside a string") }
            if byte != UInt8(ascii: "\\") { out.append(byte); at += 1; continue }
            at += 1
            guard at < bytes.count else { throw fail("the document ends inside an escape") }
            let escape = bytes[at]; at += 1
            switch escape {
            case UInt8(ascii: "\""): out.append(0x22)
            case UInt8(ascii: "\\"): out.append(0x5C)
            case UInt8(ascii: "/"): out.append(0x2F)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                var scalar = UInt32(try hex4())
                if scalar >= 0xD800, scalar <= 0xDBFF,
                   at + 1 < bytes.count, bytes[at] == UInt8(ascii: "\\"), bytes[at + 1] == UInt8(ascii: "u") {
                    let mark = at
                    at += 2
                    let low = UInt32(try hex4())
                    if low >= 0xDC00, low <= 0xDFFF {
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        at = mark
                    }
                }
                // A lone surrogate is a thing a JavaScript string can hold
                // and a Swift one cannot. U+FFFD, which is what writing the
                // string back out as UTF-8 would have made of it anyway.
                let unicode = Unicode.Scalar(scalar) ?? "\u{FFFD}"
                out.append(contentsOf: Array(String(Character(unicode)).utf8))
            default:
                at -= 1
                throw fail("an escape JSON does not have")
            }
        }
        // The bytes as they are, not by way of a C string: that road is
        // deprecated as of Swift 6.4, and it ended at the first NUL, which
        // `\u0000` is entitled to put in the middle of a string.
        guard let text = String(validating: out, as: UTF8.self) else {
            throw fail("a string that is not valid UTF-8")
        }
        return text
    }

    mutating func hex4() throws -> UInt16 {
        guard at + 4 <= bytes.count else { throw fail("a \\u escape cut short") }
        var value: UInt16 = 0
        for _ in 0..<4 {
            let byte = bytes[at]
            let digit: UInt16
            switch byte {
            case 0x30...0x39: digit = UInt16(byte - 0x30)
            case 0x41...0x46: digit = UInt16(byte - 0x41 + 10)
            case 0x61...0x66: digit = UInt16(byte - 0x61 + 10)
            default: throw fail("a \\u escape with a digit that is not hex")
            }
            value = value << 4 | digit
            at += 1
        }
        return value
    }
}

// `JSON.stringify`, to the byte (PD14).
//
// Two forms are used and both are reproduced: `stringify(v, null, 2)` for
// everything that lands on disk — the project file, `ids_map.json`,
// `prompt.json`, an exported document — and the compact form for
// a frame on the channel. A non-finite number is `null`, −0 is `0`, and the
// only characters escaped are the ones JavaScript escapes: the quote, the
// backslash and the C0 controls. Not `/`, not U+2028, not anything above
// ASCII.

extension JSON {
    /// `JSON.stringify(value)` when `indent` is 0, `JSON.stringify(value,
    /// null, indent)` otherwise.
    public func stringified(indent: Int = 0) -> String {
        var out = ""
        write(into: &out, indent: indent, level: 0)
        return out
    }

    private func write(into out: inout String, indent: Int, level: Int) {
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .number(let value): out += value.isFinite ? JS.string(value) : "null"
        case .string(let value): Self.quote(value, into: &out)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                Self.newline(into: &out, indent: indent, level: level + 1)
                item.write(into: &out, indent: indent, level: level + 1)
            }
            Self.newline(into: &out, indent: indent, level: level)
            out += "]"
        case .object(let object):
            if object.isEmpty { out += "{}"; return }
            out += "{"
            for (i, pair) in object.pairs.enumerated() {
                if i > 0 { out += "," }
                Self.newline(into: &out, indent: indent, level: level + 1)
                Self.quote(pair.key, into: &out)
                out += indent > 0 ? ": " : ":"
                pair.value.write(into: &out, indent: indent, level: level + 1)
            }
            Self.newline(into: &out, indent: indent, level: level)
            out += "}"
        }
    }

    private static func newline(into out: inout String, indent: Int, level: Int) {
        guard indent > 0 else { return }
        out += "\n" + String(repeating: " ", count: indent * level)
    }

    /// QuoteJSONString. The short escapes JavaScript has names for, `\u00xx`
    /// in lowercase hex for the other controls, and everything else as is.
    static func quote(_ text: String, into out: inout String) {
        out += "\""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0..<0x20:
                let hex = String(scalar.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}

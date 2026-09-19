// Codex's half of `<command> mcp install`.
//
// The old helper's `codex` target wrote `~/.codex/mcp.json`, in the shape
// the other hosts share, and Codex has never read such a file. What it reads
// is `~/.codex/config.toml` — one file for everything it is told — and in it
// a table to a server:
//
//     [mcp_servers.example]
//     command = "/Applications/Example.app/Contents/Helpers/example"
//     args = []
//
// (OpenAI's Codex documentation, "Model Context Protocol", read 2026-09-19:
// `command` required, `args` and `env` optional, a project's own
// `.codex/config.toml` read the same way. `codex mcp add` writes this table.)
//
// So the guest's manners MCPInstall.swift keeps in a JSON file have to be
// kept in a TOML one, and the package has no dependencies and is not going
// to get its first for the sake of three lines. Nor would one serve: a parser that reads a config into a tree and writes
// the tree back is how the old helper came to alphabetise people's files,
// and TOML has comments to lose as well. This does the other thing. The file
// is never parsed into values and never written from them. It is walked as
// LINES, with just enough of TOML's lexical grammar — strings of all four
// kinds, comments, brackets that nest — to know which lines are table
// headers and where a statement that runs over several lines ends; the one
// table that is ours is found; and the lines of `command` and `args` in it
// are replaced, or the table is appended to the end, and every other byte
// of the file is handed back as it came, line endings included.
//
// What it cannot see to the bottom of, it refuses, and prints the table to
// paste. `mcp_servers` written as an inline table or through dotted keys is
// legal TOML and means the same thing, and there is no editing it a line at
// a time; a header that will not parse, or a string that never closes, means
// the walk cannot be trusted about anything after it. A refusal has changed
// nothing.

import Foundation
import CallboardTransport

public enum CodexConfig {
    /// The table, as it is written into a file that has none and as it is
    /// printed for a person to paste.
    public static func table(executablePath: String, dev: Bool, product: Product, newline: String = "\n") -> String {
        var lines = ["[mcp_servers.\(product.serverKey)]", commandLine(executablePath), argsLine]
        if dev { lines.append(devEnvLine(product)) }
        return lines.map { $0 + newline }.joined()
    }

    public static func status(in text: String, executablePath: String, product: Product) throws -> MCPServerRegistration.Status {
        let file = try Walk(text, serverKey: product.serverKey)
        guard let main = file.ours.first(where: { $0.path.count == 2 }) else {
            // A sub-table alone — `[mcp_servers.<key>.env]` — declares
            // the server and gives it nothing to run.
            return file.ours.isEmpty ? .notRegistered : .registeredElsewhere("")
        }
        let command = main.statements.first { $0.key == ["command"] }.flatMap { file.stringValue(of: $0) } ?? ""
        return command == executablePath ? .registered : .registeredElsewhere(command)
    }

    /// The file with the product registered in it. Twice is once: a file
    /// that already says this comes back byte for byte.
    public static func installing(_ text: String, executablePath: String, dev: Bool, product: Product) throws -> String {
        do { return try edited(text, executablePath: executablePath, dev: dev, product: product) } catch let refused as MCPConfigError {
            throw MCPConfigError("\(refused.description) — this command edits a plain [mcp_servers.\(product.serverKey)] "
                + "table and nothing else, and has changed nothing. Add this to the file by hand:\n\n"
                + table(executablePath: executablePath, dev: dev, product: product))
        }
    }

    private static func edited(_ text: String, executablePath: String, dev: Bool, product: Product) throws -> String {
        var file = try Walk(text, serverKey: product.serverKey)
        let newline = file.newline
        guard let main = file.ours.first(where: { $0.path.count == 2 }) else {
            if let orphan = file.ours.first {
                throw file.refusal("there is a [\(orphan.path.joined(separator: "."))] with no [mcp_servers.\(product.serverKey)] above it", orphan.header)
            }
            var out = text
            // (By the byte: to Swift a `\r\n` is one character, and not `\n`.)
            if !out.isEmpty, out.utf8.last != UInt8(ascii: "\n") { out += newline }
            if !out.isEmpty { out += newline }
            return out + table(executablePath: executablePath, dev: dev, product: product, newline: newline)
        }

        // In place: `command` and `args` are ours, and whatever else a
        // person has put in the table — a timeout, `enabled = false` — is
        // theirs and stays where it is.
        let env = main.statements.first { $0.key.first == "env" }
        let envTable = file.ours.first { $0.path.count > 2 && $0.path[2] == "env" }
        var edits: [(range: Range<Int>, with: [String])] = []
        var insert = main.header + 1
        for (key, line) in [("command", commandLine(executablePath)), ("args", argsLine)] {
            if let found = main.statements.first(where: { $0.key == [key] }) {
                // A line that already says it is left as its owner wrote it,
                // comment and spacing and all — which is also what makes a
                // second install change nothing.
                let says = key == "command" ? file.stringValue(of: found) == executablePath : file.isEmptyArray(found)
                if !says { edits.append((found.lines, [line])) }
                insert = found.lines.upperBound
            } else {
                edits.append((insert..<insert, [line]))
            }
        }
        // The two variables `--dev` sets are the only `env` this command
        // ever wrote, so they are the only `env` it will take away or write
        // over; one a person made is refused rather than merged by guess.
        let oursToTake = env.map { file.text(of: $0).contains(product.environmentVariable("DEV")) } ?? false
        if dev {
            if let env, oursToTake { edits.append((env.lines, [devEnvLine(product)])) }
            else if let theirs = env?.lines.lowerBound ?? envTable?.header {
                throw file.refusal("the table has an env of its own, and --dev would have to merge into it", theirs)
            } else { edits.append((insert..<insert, [devEnvLine(product)])) }
        } else if let env, oursToTake {
            edits.append((env.lines, []))
        }
        file.apply(edits)
        return file.joined
    }

    /// The file without it: the table, and any sub-table of it, from each
    /// header to the last of its statements. Comments and blank lines after
    /// that are the next table's, or nobody's, and stay.
    public static func removing(_ text: String, product: Product) throws -> String {
        var file: Walk
        do { file = try Walk(text, serverKey: product.serverKey) } catch let refused as MCPConfigError {
            throw MCPConfigError("\(refused.description) — this command edits a plain [mcp_servers.\(product.serverKey)] "
                + "table and nothing else, and has changed nothing. Take \(product.name) out of the file by hand.")
        }
        var edits: [(range: Range<Int>, with: [String])] = []
        for table in file.ours {
            var range = table.header..<(table.statements.last?.lines.upperBound ?? table.header + 1)
            // The blank line that set the table apart goes with it, when
            // leaving it would leave two together, or one at the very end.
            let before = range.lowerBound - 1
            if before >= 0, file.isBlank(before), range.upperBound >= file.count || file.isBlank(range.upperBound) {
                range = before..<range.upperBound
            }
            edits.append((range, []))
        }
        file.apply(edits)
        return file.joined
    }

    // ------------------------------------------------------------ lines ----

    private static func commandLine(_ path: String) -> String { "command = \(quoted(path))" }
    private static let argsLine = "args = []"
    /// MCPServerRegistration.entry's `env`, as an inline table so that it is
    /// one line of one table.
    private static func devEnvLine(_ product: Product) -> String {
        "env = { \(product.environmentVariable("SOCKET")) = \(quoted(RemoteEngine.defaultSocketPath(for: product))), "
            + "\(product.environmentVariable("DEV")) = \"1\" }"
    }

    /// A TOML basic string. A path may hold anything a file name may.
    static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    let hex = String(scalar.value, radix: 16, uppercase: true)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}

// --------------------------------------------------------------- the walk ---

/// A config file as its lines, with the tables that are the product's found
/// in it. Line numbers are indices into `lines`; a line keeps its `\r` if it
/// came with one, so joining with `\n` gives the file back.
private struct Walk {
    struct Statement {
        /// The key as written, dotted keys split: `env.FOO = 1` is ["env", "FOO"].
        var key: [String]
        /// Every line of it — a value may run over several.
        var lines: Range<Int>
        /// Where the value starts, on the first of them.
        var valueColumn: Int
    }

    struct Table {
        var path: [String]
        var header: Int
        var statements: [Statement] = []
    }

    private(set) var lines: [[UInt8]]
    private(set) var ours: [Table] = []
    let newline: String

    var count: Int { lines.count }
    var joined: String { String(decoding: Array(lines.joined(separator: [UInt8(ascii: "\n")])), as: UTF8.self) }

    func isBlank(_ line: Int) -> Bool { lines[line].allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D } }
    func text(of statement: Statement) -> String {
        String(decoding: Array(lines[statement.lines].joined(separator: [UInt8(ascii: "\n")])), as: UTF8.self)
    }

    func refusal(_ why: String, _ line: Int) -> MCPConfigError {
        MCPConfigError("line \(line + 1): \(why)")
    }

    /// Bottom up, so that an edit does not move the lines of the next.
    mutating func apply(_ edits: [(range: Range<Int>, with: [String])]) {
        let ending: [UInt8] = newline == "\r\n" ? [0x0D] : []
        // (Stable for equal starts: two insertions at one line keep their order.)
        for edit in edits.enumerated().sorted(by: { ($0.element.range.lowerBound, $0.offset) > ($1.element.range.lowerBound, $1.offset) }).map(\.element) {
            // The file's last line has no newline after it to carry a `\r` —
            // until a line is put after it, and then it has.
            let last = edit.range.upperBound >= lines.count
            if edit.range.lowerBound >= lines.count, !ending.isEmpty, !edit.with.isEmpty,
               let end = lines.last, !end.isEmpty, end.last != 0x0D {
                lines[lines.count - 1].append(0x0D)
            }
            var with = edit.with.map { Array($0.utf8) + ending }
            if last, !with.isEmpty, lines.last?.isEmpty == false { with[with.count - 1] = Array(edit.with.last!.utf8) }
            lines.replaceSubrange(edit.range, with: with)
        }
    }

    init(_ text: String, serverKey: String) throws {
        lines = text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map(Array.init)
        newline = text.contains("\r\n") ? "\r\n" : "\n"

        let server = serverKey
        var current: [String] = []          // the table the walk is in
        var mine: Int?                      // its index in `ours`, if it is one
        var line = 0
        while line < lines.count {
            var cursor = Cursor(lines[line], line)
            cursor.skipSpace()
            guard let first = cursor.peek, first != UInt8(ascii: "#") else { line += 1; continue }

            if first == UInt8(ascii: "[") {
                cursor.advance()
                let array = cursor.peek == UInt8(ascii: "[")
                if array { cursor.advance() }
                let path = try cursor.key(until: UInt8(ascii: "]"), self)
                cursor.advance()
                if array { guard cursor.peek == UInt8(ascii: "]") else { throw refusal("a table header that does not close", line) }; cursor.advance() }
                try cursor.endOfStatement(self)

                current = path
                mine = nil
                if path.count >= 2, path[0] == "mcp_servers", path[1] == server {
                    if array { throw refusal("[[mcp_servers.\(server)…]] is an array of tables, which is not how a server is written", line) }
                    ours.append(Table(path: path, header: line))
                    mine = ours.count - 1
                }
                line += 1
                continue
            }

            // A statement: a key, `=`, and a value that ends where every
            // bracket and string it opened has closed.
            let key = try cursor.key(until: UInt8(ascii: "="), self)
            cursor.advance()
            cursor.skipSpace()
            let column = cursor.column
            let start = line
            var depth = 0
            try cursor.value(&depth, in: &line, of: self)

            // The same server said another way: through the root's dotted
            // keys or an inline table, or through `[mcp_servers]`'s.
            let full = current + key
            if mine == nil, full.first == "mcp_servers", full.count == 1 || full[1] == server {
                throw refusal(full.count == 1 ? "mcp_servers is written as an inline table"
                                              : "mcp_servers.\(server) is written as an inline table or with dotted keys", start)
            }
            if let mine { ours[mine].statements.append(Statement(key: key, lines: start..<(line + 1), valueColumn: column)) }
            line += 1
        }
    }

    /// `args = []`, however it is spaced and whatever is said after it.
    func isEmptyArray(_ statement: Statement) -> Bool {
        guard statement.lines.count == 1 else { return false }
        let value = lines[statement.lines.lowerBound][statement.valueColumn...].prefix { $0 != UInt8(ascii: "#") }
        return value.filter { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D }.elementsEqual("[]".utf8)
    }

    /// A statement's value, if it is one string on one line — which a
    /// `command` is.
    func stringValue(of statement: Statement) -> String? {
        guard statement.lines.count == 1 else { return nil }
        var cursor = Cursor(lines[statement.lines.lowerBound], statement.lines.lowerBound)
        cursor.column = statement.valueColumn
        return try? cursor.string(self)
    }
}

/// A place on a line. Bytes, because everything TOML's grammar cares about
/// is ASCII and a byte of a longer character is never mistaken for it.
private struct Cursor {
    var bytes: [UInt8]
    var column = 0
    let line: Int

    init(_ bytes: [UInt8], _ line: Int) { self.bytes = bytes; self.line = line }

    var peek: UInt8? { column < bytes.count ? bytes[column] : nil }
    mutating func advance(_ n: Int = 1) { column += n }
    func starts(with text: String) -> Bool { bytes[column...].starts(with: text.utf8) }
    mutating func skipSpace() { while let b = peek, b == 0x20 || b == 0x09 || b == 0x0D { advance() } }

    /// Nothing more on the line but space and a comment.
    mutating func endOfStatement(_ walk: Walk) throws {
        skipSpace()
        if let b = peek, b != UInt8(ascii: "#") { throw walk.refusal("something follows where the line should end", line) }
    }

    /// A key, dotted or not, up to and not including `end`.
    mutating func key(until end: UInt8, _ walk: Walk) throws -> [String] {
        var parts: [String] = []
        while true {
            skipSpace()
            guard let b = peek else { throw walk.refusal("a key with nothing after it", line) }
            if b == UInt8(ascii: "\"") || b == UInt8(ascii: "'") {
                parts.append(try string(walk))
            } else {
                let from = column
                while let c = peek, (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x2D { advance() }
                if column == from { throw walk.refusal("a key this command cannot read", line) }
                parts.append(String(decoding: bytes[from..<column], as: UTF8.self))
            }
            skipSpace()
            if peek == UInt8(ascii: ".") { advance(); continue }
            guard peek == end else { throw walk.refusal("a key this command cannot read", line) }
            return parts
        }
    }

    /// A one-line string, basic or literal, decoded; the cursor is left
    /// after its closing quote.
    mutating func string(_ walk: Walk) throws -> String {
        guard let quote = peek, quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") else {
            throw walk.refusal("not a string", line)
        }
        if starts(with: "\"\"\"") || starts(with: "'''") { throw walk.refusal("a multi-line string where a plain one was expected", line) }
        advance()
        var out: [UInt8] = []
        while let b = peek {
            advance()
            if b == quote { return String(decoding: out, as: UTF8.self) }
            guard b == UInt8(ascii: "\\"), quote == UInt8(ascii: "\"") else { out.append(b); continue }
            guard let escaped = peek else { break }
            advance()
            switch escaped {
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "e"): out.append(0x1B)
            case UInt8(ascii: "u"), UInt8(ascii: "U"), UInt8(ascii: "x"):
                let digits = escaped == UInt8(ascii: "u") ? 4 : escaped == UInt8(ascii: "U") ? 8 : 2
                guard column + digits <= bytes.count,
                      let value = UInt32(String(decoding: bytes[column..<(column + digits)], as: UTF8.self), radix: 16),
                      let scalar = Unicode.Scalar(value) else { throw walk.refusal("an escape this command cannot read", line) }
                advance(digits)
                out.append(contentsOf: Array(String(Character(scalar)).utf8))
            default: out.append(escaped)     // `\"` and `\\`
            }
        }
        throw walk.refusal("a string that does not close", line)
    }

    /// Steps over a value, moving on to further lines while a bracket, a
    /// brace or a multi-line string is open. Nothing is decoded: the walk
    /// only has to know where the value ends.
    mutating func value(_ depth: inout Int, in line: inout Int, of walk: Walk) throws {
        let first = line
        while true {
            while let b = peek {
                if b == UInt8(ascii: "#") { column = bytes.count; break }
                if starts(with: "\"\"\"") || starts(with: "'''") {
                    let quote = b, basic = b == UInt8(ascii: "\"")
                    advance(3)
                    // To the closing three, over as many lines as it takes.
                    while true {
                        guard let c = peek else {
                            guard line + 1 < walk.count else { throw walk.refusal("a multi-line string that does not close", first) }
                            line += 1
                            self = Cursor(walk.lines[line], line)
                            continue
                        }
                        if basic, c == UInt8(ascii: "\\") { advance(2); continue }
                        if c == quote, column + 2 < bytes.count, bytes[column + 1] == quote, bytes[column + 2] == quote {
                            advance(3)
                            // Up to two more quotes may belong to the string.
                            while peek == quote { advance() }
                            break
                        }
                        advance()
                    }
                    continue
                }
                if b == UInt8(ascii: "\"") || b == UInt8(ascii: "'") { _ = try string(walk); continue }
                if b == UInt8(ascii: "[") || b == UInt8(ascii: "{") { depth += 1 }
                if b == UInt8(ascii: "]") || b == UInt8(ascii: "}") { depth -= 1 }
                if depth < 0 { throw walk.refusal("a bracket that closes nothing", line) }
                advance()
            }
            if depth == 0 { return }
            guard line + 1 < walk.count else { throw walk.refusal("a bracket that does not close", first) }
            line += 1
            self = Cursor(walk.lines[line], line)
        }
    }
}

// `example mcp install codex` (PLAN §12.4). The old target wrote
// `~/.codex/mcp.json`, which Codex does not read; this one edits
// `~/.codex/config.toml`, which is a person's whole Codex configuration and
// not only a list of servers. So the first thing held here is the guest's
// rule — every byte that is not ours comes back as it was — and the second
// is that a file this cannot see to the bottom of is refused, with the table
// to paste, and not guessed at.

import Foundation
import Testing
@testable import CallboardMCP

private let BIN = "/Applications/Example.app/Contents/MacOS/example"
private let OURS = """
[mcp_servers.example]
command = "\(BIN)"
args = []

"""

/// Somebody's config, with the things in it a line-at-a-time edit could
/// trip on: comments, a multi-line string that holds a header of ours, an
/// array over several lines with brackets in it, a quoted table name.
private let THEIRS = """
# Robert's Codex. Do not alphabetise.
model = "gpt-5.1-codex"   # the good one
approval_policy = "on-request"

developer_instructions = \"\"\"
Keep answers short.
[mcp_servers.example]
command = "not a table: this is inside a string"
\"\"\"

[mcp_servers.context7]
command = "npx"
args = [
  "-y",            # [not.a.header]
  "@upstash/context7-mcp",
]

[mcp_servers.context7.env]
MY_ENV_VAR = 'a # that is not a comment'

[projects."/Users/robert/Git/Example"]
trust_level = "trusted"

"""

@Suite("the codex target writes the file Codex reads (§12.4)")
struct CodexConfigTests {
    @Test("the target is ~/.codex/config.toml, and TOML")
    func target() {
        #expect(MCPClientTarget.codex.configURL.path.hasSuffix("/.codex/config.toml"))
        #expect(MCPClientTarget.codex.format == .toml)
        #expect(MCPClientTarget.allCases.filter { $0 != .codex }.allSatisfy { $0.format == .json })
        #expect(MCPConfigFormat(for: URL(fileURLWithPath: "/tmp/x/config.toml")) == .toml)
        #expect(MCPConfigFormat(for: URL(fileURLWithPath: "/tmp/x/mcp.json")) == .json)
    }

    @Test("an empty or absent file becomes the one table, with command and args")
    func fromNothing() throws {
        #expect(try CodexConfig.installing("", executablePath: BIN, dev: false, product: example) == OURS)
        #expect(try CodexConfig.status(in: "", executablePath: BIN, product: example) == .notRegistered)
        #expect(try CodexConfig.status(in: OURS, executablePath: BIN, product: example) == .registered)
    }

    @Test("appends to somebody's file and changes no byte of theirs")
    func appends() throws {
        let after = try CodexConfig.installing(THEIRS, executablePath: BIN, dev: false, product: example)
        #expect(after == THEIRS + "\n" + OURS)
        #expect(try CodexConfig.status(in: after, executablePath: BIN, product: example) == .registered)
        // The header inside the multi-line string was not taken for a table.
        #expect(try CodexConfig.status(in: THEIRS, executablePath: BIN, product: example) == .notRegistered)
    }

    @Test("installing twice is installing once, and uninstalling gives the file back byte for byte")
    func idempotent() throws {
        let once = try CodexConfig.installing(THEIRS, executablePath: BIN, dev: false, product: example)
        #expect(try CodexConfig.installing(once, executablePath: BIN, dev: false, product: example) == once)
        #expect(try CodexConfig.removing(once, product: example) == THEIRS)
        #expect(try CodexConfig.removing(THEIRS, product: example) == THEIRS)
        #expect(try CodexConfig.removing(OURS, product: example) == "")

        // A file with no newline at its end gets one, and only one.
        let bare = "model = \"o3\""
        let installed = try CodexConfig.installing(bare, executablePath: BIN, dev: false, product: example)
        #expect(installed == "model = \"o3\"\n\n" + OURS)
        #expect(try CodexConfig.removing(installed, product: example) == "model = \"o3\"\n")
    }

    @Test("repoints a table that is already there, in place, and keeps what a person added to it")
    func inPlace() throws {
        let before = """
        [mcp_servers.example]   # the blocking tool
        startup_timeout_sec = 20
        command = '/old/place/example'
        args = ["--verbose",
                "--more"]
        enabled = true

        # Context7 comes after.
        [mcp_servers.context7]
        command = "npx"

        """
        #expect(try CodexConfig.status(in: before, executablePath: BIN, product: example) == .registeredElsewhere("/old/place/example"))
        let after = try CodexConfig.installing(before, executablePath: BIN, dev: false, product: example)
        #expect(after == """
        [mcp_servers.example]   # the blocking tool
        startup_timeout_sec = 20
        command = "\(BIN)"
        args = []
        enabled = true

        # Context7 comes after.
        [mcp_servers.context7]
        command = "npx"

        """)
        #expect(try CodexConfig.installing(after, executablePath: BIN, dev: false, product: example) == after)

        // A line that already says it keeps its owner's spelling and comment.
        let said = "[mcp_servers.example]\ncommand = '\(BIN)' # mine\nargs = [ ]\n"
        #expect(try CodexConfig.installing(said, executablePath: BIN, dev: false, product: example) == said)

        // A table with neither gets both, under its header.
        #expect(try CodexConfig.installing("[mcp_servers.example]\nenabled = false\n", executablePath: BIN, dev: false, product: example)
            == "[mcp_servers.example]\ncommand = \"\(BIN)\"\nargs = []\nenabled = false\n")
    }

    @Test("uninstall takes the table and its sub-tables, and leaves the comment that belongs to the next one")
    func removes() throws {
        let before = """
        model = "o3"

        [mcp_servers.example]
        command = "\(BIN)"
        args = []

        [mcp_servers.example.env]
        FOO = "bar"

        # Context7 comes after.
        [mcp_servers.context7]
        command = "npx"

        """
        #expect(try CodexConfig.removing(before, product: example) == """
        model = "o3"

        # Context7 comes after.
        [mcp_servers.context7]
        command = "npx"

        """)
    }

    @Test("keeps a file's CRLF line endings, in what it adds as in what it leaves")
    func crlf() throws {
        let before = "model = \"o3\"\r\n\r\n[mcp_servers.example]\r\ncommand = \"/old\"\r\n"
        let after = try CodexConfig.installing(before, executablePath: BIN, dev: false, product: example)
        #expect(after == "model = \"o3\"\r\n\r\n[mcp_servers.example]\r\ncommand = \"\(BIN)\"\r\nargs = []\r\n")
        #expect(try CodexConfig.installing("model = \"o3\"\r\n", executablePath: BIN, dev: false, product: example)
            == "model = \"o3\"\r\n\r\n[mcp_servers.example]\r\ncommand = \"\(BIN)\"\r\nargs = []\r\n")
    }

    @Test("a path with a quote, a backslash or an accent in it is written as a TOML string and read back the same")
    func quoting() throws {
        let odd = "/Users/zoë/My \"Apps\"/under\\study"
        let text = try CodexConfig.installing("", executablePath: odd, dev: false, product: example)
        #expect(text.contains(#"command = "/Users/zoë/My \"Apps\"/under\\study""#))
        #expect(try CodexConfig.status(in: text, executablePath: odd, product: example) == .registered)
    }

    @Test("--dev adds its env as one line of the table, and a plain install takes it away again")
    func dev() throws {
        let dev = try CodexConfig.installing(THEIRS, executablePath: BIN, dev: true, product: example)
        #expect(dev.hasSuffix("args = []\nenv = { EXAMPLE_SOCKET = \"\(RemoteEngine.defaultSocketPath(for: example))\", EXAMPLE_DEV = \"1\" }\n"))
        #expect(try CodexConfig.installing(dev, executablePath: BIN, dev: true, product: example) == dev)
        #expect(try CodexConfig.installing(dev, executablePath: BIN, dev: false, product: example) == THEIRS + "\n" + OURS)

        // An env a person wrote is theirs: kept by a plain install, and not
        // merged into by --dev.
        let theirs = OURS + "env = { TOKEN = \"x\" }\n"
        #expect(try CodexConfig.installing(theirs, executablePath: BIN, dev: false, product: example) == theirs)
        #expect(throws: MCPConfigError.self) { try CodexConfig.installing(theirs, executablePath: BIN, dev: true, product: example) }
    }

    @Test("refuses a shape it cannot edit a line at a time, changes nothing, and prints the table to paste",
          arguments: [
            "mcp_servers = { example = { command = \"/x\" } }\n",
            "[mcp_servers]\nexample = { command = \"/x\" }\n",
            "[mcp_servers]\nexample.command = \"/x\"\n",
            "mcp_servers.example.command = \"/x\"\n",
            "[[mcp_servers.example]]\ncommand = \"/x\"\n",
            "[mcp_servers.example.env]\nFOO = \"bar\"\n",
            "[mcp_servers.example\ncommand = \"/x\"\n",
            "model = \"never closes\n",
            "notes = \"\"\"\nnever closes\n",
            "args = [\n  \"never closes\",\n",
            "\u{FEFF}model = \"o3\"\n",
          ])
    func refuses(text: String) throws {
        let refused = try #require(throws: MCPConfigError.self) { try CodexConfig.installing(text, executablePath: BIN, dev: false, product: example) }
        #expect(refused.description.hasPrefix("line "), "\(refused.description)")
        #expect(refused.description.contains("has changed nothing"))
        #expect(refused.description.hasSuffix(OURS), "the table to paste: \(refused.description)")
    }

    @Test("the same server under a quoted or spaced header is the same server")
    func spelledOtherwise() throws {
        for header in ["[ mcp_servers . example ]", "[\"mcp_servers\".'example']", "[mcp_servers.example] # ours"] {
            let text = "\(header)\ncommand = \"/old\"\n"
            #expect(try CodexConfig.status(in: text, executablePath: BIN, product: example) == .registeredElsewhere("/old"))
            #expect(try CodexConfig.installing(text, executablePath: BIN, dev: false, product: example) == "\(header)\ncommand = \"\(BIN)\"\nargs = []\n")
        }
        // …and one that only starts the same is somebody else's.
        let other = "[mcp_servers.example-old]\ncommand = \"/old\"\n"
        #expect(try CodexConfig.status(in: other, executablePath: BIN, product: example) == .notRegistered)
        #expect(try CodexConfig.removing(other, product: example) == other)
    }

    @Test("through the command itself: a backup of the person's file, their permissions kept, and nothing else touched")
    func throughTheCommand() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("config.toml")
        try Data(THEIRS.utf8).write(to: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)

        try MCPInstall.run(["install", "--path", config.path], product: example)
        let installed = try String(contentsOf: config, encoding: .utf8)
        #expect(installed.hasPrefix(THEIRS) && installed.contains("[mcp_servers.example]\ncommand = \""))
        #expect(try String(contentsOf: config.appendingPathExtension("example-backup"), encoding: .utf8) == THEIRS)
        #expect(try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? Int == 0o600)

        try MCPInstall.run(["install", "--path", config.path], product: example)
        #expect(try String(contentsOf: config, encoding: .utf8) == installed)
        try MCPInstall.run(["uninstall", "--path", config.path], product: example)
        #expect(try String(contentsOf: config, encoding: .utf8) == THEIRS)

        // A refusal is a CLI error with the table in it, and an unchanged file.
        let inline = "mcp_servers = { example = { command = \"/x\" } }\n"
        try Data(inline.utf8).write(to: config)
        let refused = try #require(throws: CLIError.self) { try MCPInstall.run(["install", "--path", config.path], product: example) }
        #expect(refused.description.contains("[mcp_servers.example]\ncommand = \""))
        #expect(try String(contentsOf: config, encoding: .utf8) == inline)
    }
}

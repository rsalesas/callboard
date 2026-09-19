// Who is using Callboard. Everything that would otherwise name a product —
// its support directory, its lock file, its environment variables, the key it
// is registered under in a host's config, the label on its diagnostics — is
// derived from this one value, so that no product's name is written anywhere
// in this package.
//
//     let example = Product(name: "Example", command: "example", environmentPrefix: "EXAMPLE")
//
//     example.supportDirectoryName             "Example"
//     example.lockFileName                     ".example.lock"
//     example.environmentVariable("DEBUG")     "EXAMPLE_DEBUG"
//     example.serverKey                        "example"

public struct Product: Sendable, Hashable {
    /// As a person reads it, in sentences and in a folder name: "Example".
    public let name: String
    /// The executable a host launches, and the key it is registered under:
    /// "example".
    public let command: String
    /// Every environment variable the product reads starts with this and an
    /// underscore: "EXAMPLE".
    public let environmentPrefix: String

    public init(name: String, command: String, environmentPrefix: String) {
        self.name = name
        self.command = command
        self.environmentPrefix = environmentPrefix
    }

    /// `~/Library/Application Support/<this>`.
    public var supportDirectoryName: String { name }

    /// The file in a project root whose lock is the project's lock.
    public var lockFileName: String { ".\(command).lock" }

    /// `<PREFIX>_<suffix>` — `SUPPORT_DIR`, `DEBUG`, `SOCKET`, `CLIENT`, `DEV`.
    public func environmentVariable(_ suffix: String) -> String { "\(environmentPrefix)_\(suffix)" }

    /// The name under `mcpServers` in a host's JSON config, and the table
    /// under `mcp_servers` in Codex's TOML one.
    public var serverKey: String { command }

    /// The extension on the one-time backup of a host's config file.
    public var backupExtension: String { "\(command)-backup" }

    /// What diagnostics on stderr are prefixed with: `[example]`.
    public var diagnosticsLabel: String { command }
}

// `<command> mcp install|uninstall|status [client]`, for any product.
// Vaelora's shape, verbatim where it applies: the merge, the one-time
// backup and the write keep everything in a host's config that is not ours,
// because it is somebody else's file and we are a guest in it.
//
// Carried over from the old helper essentially as it stood — what it
// registers is the same binary at the same path, and that the binary now
// *is* the server rather than a bridge to one (D54) changes nothing a host's
// config can see. One thing did change, and for the better: the file is
// read and written as ordered JSON (PD14) instead of through
// `JSONSerialization` with `.sortedKeys`, so a host's config comes back
// with its keys where its owner left them rather than in the alphabet's
// order. The price is the one PD14 always has: numbers pass through a
// `Double`, so an integer above 2⁵³ in somebody's config would be rounded
// where `JSONSerialization` kept it whole to 2⁶³. No host's config is known
// to hold such a number; the one-time backup is there for the day one does.
//
// And one target was wrong from the start (PLAN §12.4): `codex` wrote
// `~/.codex/mcp.json`, a file Codex does not read. Codex keeps its servers in
// `~/.codex/config.toml`, so that target is TOML now, edited a line at a
// time by CodexConfig.swift; what the two shapes share is below — which
// file, the one-time backup, the permissions, and what is said about it.

import Foundation
import CallboardJSON
import CallboardTransport

public struct CLIError: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { description = message }
}

public enum MCPClientTarget: String, CaseIterable, Sendable {
    case claudeDesktop = "claude-desktop"
    case claudeCode = "claude-code"
    /// `.mcp.json` in the current directory — meaningful for a CLI, and the
    /// right scope for trying a product on one project.
    case claudeCodeProject = "claude-code-project"
    case cursor
    case codex

    public var displayName: String {
        switch self {
        case .claudeDesktop: return "Claude Desktop"
        case .claudeCode: return "Claude Code"
        case .claudeCodeProject: return "Claude Code (this project)"
        case .cursor: return "Cursor"
        case .codex: return "Codex"
        }
    }

    public var configURL: URL {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        switch self {
        case .claudeDesktop:
            return home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        case .claudeCode:
            return home.appendingPathComponent(".claude.json")
        case .claudeCodeProject:
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".mcp.json")
        case .cursor:
            return home.appendingPathComponent(".cursor/mcp.json")
        case .codex:
            return home.appendingPathComponent(".codex/config.toml")
        }
    }

    public var format: MCPConfigFormat { self == .codex ? .toml : .json }
}

/// How a host writes its servers down: `mcpServers` in a JSON object, which
/// is everybody but Codex, or `[mcp_servers.<name>]` tables in a TOML file,
/// which is Codex.
public enum MCPConfigFormat: Sendable {
    case json, toml

    /// For a bare `--path`, where the file is all there is to go on.
    public init(for url: URL) { self = url.pathExtension.lowercased() == "toml" ? .toml : .json }
}

public struct MCPConfigError: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { description = message }
}

public enum MCPServerRegistration {
    // The key a product claims under `mcpServers` is `product.serverKey`.
    // Everything else in the file is somebody else's and is passed through
    // untouched.

    public static func entry(executablePath: String, dev: Bool, product: Product) -> JSONObject {
        var entry = JSONObject([("command", .string(executablePath)), ("args", [])])
        // --dev makes the server a bridge again: instead of running the
        // engine in its own process it attaches, through `RemoteEngine`, to
        // the Node development harness's socket (PD4), so a host can drive
        // the TypeScript engine — the oracle — over the shipped MCP layer.
        // The harness goes at N8, and this flag goes with it.
        if dev {
            entry["env"] = .object(JSONObject([
                (product.environmentVariable("SOCKET"), .string(RemoteEngine.defaultSocketPath(for: product))),
                (product.environmentVariable("DEV"), .string("1")),
            ]))
        }
        return entry
    }

    public enum Status: Equatable, Sendable {
        case notRegistered
        case registered
        /// Registered, but launching a different binary — a copy that has
        /// moved or been replaced. The command is carried so it can be shown.
        case registeredElsewhere(String)
    }

    public static func status(in document: JSONObject, executablePath: String, product: Product) -> Status {
        guard let installed = document["mcpServers"]?[product.serverKey], installed.objectValue != nil else {
            return .notRegistered
        }
        let command = installed["command"]?.stringValue ?? ""
        return command == executablePath ? .registered : .registeredElsewhere(command)
    }

    public static func installing(_ document: JSONObject, executablePath: String, dev: Bool, product: Product) -> JSONObject {
        var document = document
        var servers = document["mcpServers"]?.objectValue ?? JSONObject()
        servers[product.serverKey] = .object(entry(executablePath: executablePath, dev: dev, product: product))
        document["mcpServers"] = .object(servers)
        return document
    }

    public static func removing(_ document: JSONObject, product: Product) -> JSONObject {
        var document = document
        var servers = document["mcpServers"]?.objectValue ?? JSONObject()
        servers[product.serverKey] = nil
        document["mcpServers"] = .object(servers)
        return document
    }

    /// An absent file reads as an empty document; anything that is not a
    /// JSON object is an error rather than something to overwrite.
    public static func read(_ url: URL) throws -> JSONObject {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return JSONObject() }
        guard let document = (try? JSON.parse(bytes: Array(data)))?.objectValue else {
            throw MCPConfigError("\(url.lastPathComponent) is not a JSON object — refusing to "
                + "overwrite it. Fix or move the file, then try again.")
        }
        return document
    }

    /// Writes, keeping the original's permissions and leaving a one-time
    /// backup of a file we did not create.
    public static func write(_ document: JSONObject, to url: URL, product: Product) throws {
        try write(text: serialized(document) + "\n", to: url, product: product)
    }

    /// The same for a file that is not JSON: the text is the whole file.
    public static func write(text: String, to url: URL, product: Product) throws {
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let attributes = try? manager.attributesOfItem(atPath: url.path)
        if manager.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension(product.backupExtension)
            if !manager.fileExists(atPath: backup.path) {
                try? manager.copyItem(at: url, to: backup)
            }
        }
        let data = Data(text.utf8)
        do { try data.write(to: url, options: .atomic) } catch { try data.write(to: url) }
        if let permissions = attributes?[.posixPermissions] {
            try? manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
    }

    /// Two-space `JSON.stringify`, which is how Claude Desktop and Claude
    /// Code write the same files themselves.
    public static func serialized(_ document: JSONObject) -> String {
        JSON.object(document).stringified(indent: 2)
    }
}

public enum MCPInstall {
    /// This binary's own path, which is what the client will launch.
    public static var executablePath: String {
        URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    }

    public static var clientListing: String {
        MCPClientTarget.allCases.map {
            "  \($0.rawValue.padding(toLength: 22, withPad: " ", startingAt: 0)) \($0.displayName)"
        }.joined(separator: "\n")
    }

    public static func run(_ arguments: [String], product: Product) throws {
        var arguments = arguments
        let action = arguments.isEmpty ? "status" : arguments.removeFirst()

        var dryRun = false, dev = false
        var explicitPath: URL?
        var targetNames: [String] = []
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--dry-run": dryRun = true
            case "--dev": dev = true
            case "--path":
                guard let value = iterator.next() else { throw CLIError("--path needs a file") }
                explicitPath = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            default:
                guard !argument.hasPrefix("-") else { throw CLIError("unknown option '\(argument)'") }
                targetNames.append(argument)
            }
        }

        switch action {
        case "status": try status(explicitPath: explicitPath, product: product)
        case "install", "uninstall":
            guard !targetNames.isEmpty || explicitPath != nil else {
                throw CLIError("`\(product.command) mcp \(action)` needs a client:\n\(clientListing)")
            }
            let targets = try targetNames.map { name -> MCPClientTarget in
                guard let target = MCPClientTarget(rawValue: name) else {
                    throw CLIError("unknown client '\(name)' — choose one of:\n\(clientListing)")
                }
                return target
            }
            if targets.isEmpty, let explicitPath {
                try apply(action, to: explicitPath, format: MCPConfigFormat(for: explicitPath), label: explicitPath.path,
                          dryRun: dryRun, dev: dev, product: product, named: false)
            }
            for target in targets {
                try apply(action, to: explicitPath ?? target.configURL, format: target.format,
                          label: target.displayName, dryRun: dryRun, dev: dev, product: product)
            }
        default:
            throw CLIError("unknown mcp command '\(action)' — try install, uninstall or status")
        }
    }

    /// `named` is false when the caller gave a bare `--path`, where the
    /// label IS the file — so the messages stop saying things like
    /// "/tmp/x.json: registered … → /tmp/x.json" and "Restart /tmp/x.json".
    private static func apply(
        _ action: String, to url: URL, format: MCPConfigFormat, label: String, dryRun: Bool, dev: Bool,
        product: Product, named: Bool = true
    ) throws {
        do {
            let file = try MCPConfigFile(url, format)
            if action == "uninstall", try file.status(executablePath, product: product) == .notRegistered {
                print(named ? "\(label): \(product.name) was not registered — nothing to remove"
                            : "\(product.name) was not registered in \(url.path) — nothing to remove")
                return
            }
            let updated = action == "install" ? try file.installing(executablePath, dev: dev, product: product)
                                              : try file.removing(product: product)

            guard !dryRun else {
                print("\(label) — would write to \(url.path):")
                print(try MCPConfigFile.empty(format).installing(executablePath, dev: dev, product: product), terminator: "")
                return
            }
            try MCPServerRegistration.write(text: updated, to: url, product: product)
            let where_ = named ? "\(label) → \(url.path)" : url.path
            print(action == "install" ? "Registered \(product.name) in \(where_)"
                                      : "Removed \(product.name) from \(where_)")
            if action == "install" {
                print(named ? "Restart \(label) to pick up the change."
                            : "Restart whichever client reads that file to pick up the change.")
            }
        } catch let error as MCPConfigError {
            throw CLIError(error.description)
        } catch {
            throw CLIError("could not write \(url.path): \(error)")
        }
    }

    private static func status(explicitPath: URL?, product: Product) throws {
        print("\(product.name) MCP server: \(executablePath)\n")
        if let explicitPath {
            try report(url: explicitPath, format: MCPConfigFormat(for: explicitPath), label: explicitPath.path, hint: nil,
                       product: product)
            return
        }
        for target in MCPClientTarget.allCases {
            try report(url: target.configURL, format: target.format,
                       label: target.displayName.padding(toLength: 28, withPad: " ", startingAt: 0),
                       hint: target.rawValue, product: product)
        }
    }

    private static func report(url: URL, format: MCPConfigFormat, label: String, hint: String?, product: Product) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("  \(label) no config file at \(url.path)")
            return
        }
        switch try MCPConfigFile(url, format).status(executablePath, product: product) {
        case .notRegistered:
            print("  \(label) not registered")
        case .registered:
            print("  \(label) registered")
        case let .registeredElsewhere(command):
            let indent = String(repeating: " ", count: 32)
            let repoint = hint.map { "\n\(indent)run `\(product.command) mcp install \($0)` to repoint it" } ?? ""
            print("  \(label) registered, but points at a different binary:\n" + indent + command + repoint)
        }
    }
}

/// A host's config as it was read, in whichever of the two shapes it has,
/// and the three things this command does to one — each answering with the
/// whole file's new text, so that writing it is the same act for both.
enum MCPConfigFile {
    case json(JSONObject)
    case toml(String)

    init(_ url: URL, _ format: MCPConfigFormat) throws {
        switch format {
        case .json: self = .json(try MCPServerRegistration.read(url))
        case .toml:
            // An absent file reads as an empty one, as it does for JSON.
            guard let data = try? Data(contentsOf: url) else { self = .toml(""); return }
            guard let text = String(data: data, encoding: .utf8) else {
                throw MCPConfigError("\(url.lastPathComponent) is not UTF-8 text — refusing to overwrite it. "
                    + "Fix or move the file, then try again.")
            }
            self = .toml(text)
        }
    }

    static func empty(_ format: MCPConfigFormat) -> MCPConfigFile { format == .json ? .json(JSONObject()) : .toml("") }

    func status(_ executablePath: String, product: Product) throws -> MCPServerRegistration.Status {
        switch self {
        case .json(let document): MCPServerRegistration.status(in: document, executablePath: executablePath, product: product)
        case .toml(let text): try CodexConfig.status(in: text, executablePath: executablePath, product: product)
        }
    }

    func installing(_ executablePath: String, dev: Bool, product: Product) throws -> String {
        switch self {
        case .json(let document):
            MCPServerRegistration.serialized(MCPServerRegistration.installing(document, executablePath: executablePath,
                                                                              dev: dev, product: product)) + "\n"
        case .toml(let text): try CodexConfig.installing(text, executablePath: executablePath, dev: dev, product: product)
        }
    }

    func removing(product: Product) throws -> String {
        switch self {
        case .json(let document): MCPServerRegistration.serialized(MCPServerRegistration.removing(document, product: product)) + "\n"
        case .toml(let text): try CodexConfig.removing(text, product: product)
        }
    }
}

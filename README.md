# Callboard

Shared plumbing for Mac apps that are driven by AI agents over MCP. On a stage, the
callboard is the backstage board where calls and notices are posted for every show in
the house; this package is the part of that job two products share.

Used by Understudy (shot authoring) and [Standby](https://github.com/rsalesas/Standby)
(editing).

## The rule

**No product logic.** If a file knows what a shot, a score, a clip or a stand-in is, it
does not belong here. Callboard moves messages, holds locks and installs itself into
hosts; what the messages mean is the product's business. Every name, path and
environment variable a product needs comes from the `Product` value it passes in.

## What is in it

| Module | What it does |
|---|---|
| `CallboardJSON` | A JSON value, parser and writer that keep keys in order and print numbers the way JavaScript does. |
| `CallboardTransport` | Unix-domain sockets and line framing (`SocketServer`, `SessionLink`), the support directory and the session descriptors servers publish there (`SupportPaths`, `SessionDescriptor`, `SessionDirectory`), a project lock held by the kernel (`ProjectLock`), `Product`, and `Diagnostics`. |
| `CallboardMCP` | MCP over stdio (`MCPServer`, `StdioTransport`), the `EngineClient` seam and a relay to a server over a socket (`RemoteEngine`), the tool catalogue as data (`Catalogue`), and installation into hosts' configuration, Codex's TOML included (`MCPInstall`). |

## The shape it assumes

A host launches a small command-line **MCP tool**, which relays to a long-lived
**server** that owns the work; a desktop **viewer** is a second client of the same
server. Callboard provides the relay, the socket between them and the lock; each
product provides its own server and viewer.

## Using it

```swift
// Package.swift
.package(url: "https://github.com/rsalesas/callboard", from: "0.1.0"),
// …
.product(name: "CallboardMCP", package: "callboard"),
```

```swift
import CallboardTransport
import CallboardMCP

let standby = Product(name: "Standby", command: "standby", environmentPrefix: "STANDBY")

Diagnostics.configure(for: standby)             // STANDBY_DEBUG → "[standby] …" on stderr

let paths = SupportPaths(product: standby)      // ~/Library/Application Support/Standby
let lock  = ProjectLock(holder: .init(client: "claude-ai"), product: standby)   // <root>/.standby.lock

// `standby mcp install claude-desktop`
try MCPInstall.run(["install", "claude-desktop"], product: standby)
```

A refused lock throws `ProjectLock.Refusal` — facts, not sentences. A product that wants
its own error type and its own words passes `refuse:` to `ProjectLock`'s initializer.

## Developing

```sh
swift build
swift test          # 110 tests: JSON 16, transport 40, MCP 54
```

To change Callboard and a product together, point the product at a local checkout —
`swift package edit callboard --path ../Callboard` — or temporarily replace its
dependency with `.package(path: "../Callboard")`. Tag a release before the product
goes back to depending on the URL.

## Where it came from

The code was written for Understudy and moved here, file by file, when Standby needed
the same pieces. Every Understudy name was replaced by the `Product` value; the tests
came with it and run against a neutral `Example` product. Some comments still cite the
design decisions that shaped the code (D-, PD- and § numbers from Understudy's
specification) where they explain *why*; they are history, not requirements.

## Licence

MIT — see [LICENSE](LICENSE).

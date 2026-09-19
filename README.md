# Callboard

Shared plumbing for Mac apps that are driven by AI agents over MCP. On a stage, the
callboard is the backstage board where calls and notices are posted for every show in
the house; this package is the part of that job two products share.

Used by [Understudy](https://github.com/rsalesas) (shot authoring) and
[Standby](https://github.com/rsalesas/Standby) (editing).

## The rule

**No product logic.** If a file knows what a shot, a score, a clip or a stand-in is, it
does not belong here. Callboard moves messages, holds locks and installs itself into
hosts; what the messages mean is the product's business.

## What goes in

| Module | What it does |
|---|---|
| `CallboardJSON` | A JSON value, parser and writer. |
| `CallboardMCP` | MCP over stdio: the protocol loop, installation into a host's configuration (Claude Desktop, Codex and others), and a **relay** that forwards every call unchanged to a server over a local socket. |
| `CallboardTransport` | Unix-domain sockets, line framing, session descriptors and the directory where running servers publish them, support paths, and the **project lock** — an advisory `flock` that dies with its process, so there is never a stale lock to clean up. |

## The shape it assumes

A host launches a small command-line **MCP tool**, which relays to a long-lived
**server** that owns the work; a desktop **viewer** is a second client of the same
server. Callboard provides the relay, the socket between them and the lock; each
product provides its own server and viewer.

## Status

Empty. The code already exists, tested and in use, inside Understudy's kit; it moves
here file by file, stripped of anything that names Understudy's own concepts, and
Understudy then depends on this package like Standby does.

## Licence

MIT — see [LICENSE](LICENSE).

// The one seam in the server (D54, PLAN §12 N3).
//
// Under PD1 the MCP layer sat in a helper and the engine sat in an app, and
// what joined them was a socket: `AppConnection` found the app, launched it
// if it had to, and turned §5.2's frames into calls. D54 put the engine in
// the process a host launches, so the socket between the two is gone — but
// the *shape* of what crossed it is worth keeping, because it is exactly
// what the line protocol carries (`catalogue`, `call`, `read`, `prompt`,
// and `updated` coming the other way) and it is small enough to fake.
//
// So the MCP layer is written against this protocol and nothing else. In
// the shipped server it is the engine actor in this process (PD16); for
// a product's own `open` and `status` commands, and for the viewer later, it is
// `RemoteEngine` speaking the same five things over a running server's
// local channel; in the tests it is a fake with a script.

import CallboardJSON

/// What the MCP layer needs from an engine. In the shipped server it is the
/// engine in this process; in tests it is a fake.
public protocol EngineClient: Sendable {
    /// `{server, instructions, tools, resources, prompts}` — the one reply
    /// everything a host is told about the surface is built from.
    func catalogue() async throws -> JSON

    /// Runs one tool and returns the §10.4 envelope, **ok or not**. A
    /// refusal is an answer, so it is returned, not thrown: the envelope
    /// reaches the host as the engine wrote it, keys in the engine's order.
    /// What is thrown is the absence of an answer — no engine, a channel
    /// that closed — as an `EngineError`.
    func call(name: String, arguments: JSON) async throws -> JSON

    /// A resource's body, as the line protocol's `read` result. A refusal
    /// (an unknown URI) is thrown as an `EngineError`: `resources/read` has
    /// no envelope to carry it in, only a JSON-RPC error.
    func read(uri: String) async throws -> JSON

    /// `{text}`, as the line protocol's `prompt` result; refusals thrown,
    /// for the same reason.
    func prompt(name: String, arguments: JSON) async throws -> JSON

    /// Resource URIs that changed since last asked, oldest first, for
    /// `notifications/resources/updated`. Asking empties the list.
    func drainUpdates() async -> [String]
}

/// Why an engine did not answer, or — for `read` and `prompt` — what it
/// refused. The same three fields an envelope's failure has, with the code
/// a string rather than Core's closed `ErrorCode`: a `RemoteEngine` may be
/// talking to a newer server whose codes this build has never heard of, and
/// "never rewrites them" (PD1) has to hold for those too.
public struct EngineError: Error, Sendable, Equatable, CustomStringConvertible {
    public var code: String
    public var error: String
    public var hint: String

    public init(_ error: String, code: String = EngineError.gone, hint: String = "") {
        self.code = code
        self.error = error
        self.hint = hint
    }


    /// There is nothing on the other end. PD1 called this E_APP_GONE, when
    /// the other end was an app; under D54 it is a server, and the only
    /// callers that can meet it are the ones attached to somebody else's —
    /// the viewer and the CLI conveniences. It is a transport fact rather
    /// than an Appendix B refusal, which is why it is not in `ErrorCode`.
    public static let gone = "E_SERVER_GONE"

    public var description: String { error }

    /// One line for a JSON-RPC error's `message`, where there is no
    /// separate place for the hint.
    public var sentence: String { hint.isEmpty ? error : "\(error) — \(hint)" }

    /// The §10.4 failure, in the order `fail()` has always built it.
    public var envelope: JSON {
        ["ok": false, "code": .string(code), "error": .string(error), "hint": .string(hint)]
    }
}

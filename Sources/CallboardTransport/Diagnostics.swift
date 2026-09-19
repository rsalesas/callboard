// Diagnostics: off unless asked for, and on stderr always — a server's stdout
// is its MCP channel, and one stray line on it ends the session.
//
// A process has one product, so this is configured once, at start-up:
//
//     Diagnostics.configure(for: example)   // on when EXAMPLE_DEBUG is set, "[example] …"
//
// Until then it answers to CALLBOARD_DEBUG and says "[callboard] …".

import Foundation
import os

public enum Diagnostics {
    private struct State: Sendable { var label: String; var enabled: Bool }

    private static let state = OSAllocatedUnfairLock(initialState: State(
        label: "callboard",
        enabled: ProcessInfo.processInfo.environment["CALLBOARD_DEBUG"] != nil))

    /// Labels every line with the product's command, and turns diagnostics on
    /// when `<PREFIX>_DEBUG` (or `CALLBOARD_DEBUG`) is set.
    public static func configure(for product: Product,
                                 environment: [String: String] = ProcessInfo.processInfo.environment) {
        let enabled = environment[product.environmentVariable("DEBUG")] != nil || environment["CALLBOARD_DEBUG"] != nil
        state.withLock { $0 = State(label: product.diagnosticsLabel, enabled: enabled) }
    }

    public static var isEnabled: Bool { state.withLock { $0.enabled } }

    public static func say(_ message: @autoclosure () -> String) {
        let current = state.withLock { $0 }
        guard current.enabled else { return }
        FileHandle.standardError.write(Data("[\(current.label)] \(message())\n".utf8))
    }
}

/// The name the transport's own diagnostics have always used.
enum Log {
    static func say(_ message: @autoclosure () -> String) { Diagnostics.say(message()) }
}

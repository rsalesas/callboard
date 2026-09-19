// Where the oracle's answers are (PD12): `fixtures/` at the repository
// root — goldens, recorded from the TypeScript engine and the JavaScript
// runtime under it before they left (fixtures/README.md).

import Foundation
import CallboardJSON

enum Fixtures {
    /// Walks up from this file rather than trusting the working directory,
    /// which is one thing under `swift test` and another under Xcode.
    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url.deleteLastPathComponent()
            let candidate = url.appendingPathComponent("fixtures")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("js").path) { return candidate }
        }
        fatalError("no fixtures/ above \(#filePath) — they are part of the repository (fixtures/README.md)")
    }()

    static func json(_ path: String) throws -> JSON {
        try JSON.parse(bytes: Array(try Data(contentsOf: root.appendingPathComponent(path))))
    }
}

extension Double {
    /// A double from the sixteen hex digits the oracle wrote it as.
    init(bits hex: String) { self.init(bitPattern: UInt64(hex, radix: 16)!) }
}

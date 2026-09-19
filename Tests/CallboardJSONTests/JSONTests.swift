// PD14: `JSON.stringify(document, null, 2)` is the file format, so the
// writer is tested against what JavaScript wrote, and the parser against
// what JavaScript would have read.

import Testing
import CallboardJSON

@Suite("JSON, in JavaScript's order") struct JSONTests {
    @Test("writes what JSON.stringify writes, pretty and compact")
    func stringify() throws {
        for c in try Fixtures.json("js/stringify.json").arrayValue! {
            let tree = try JSON.parse(c["source"]!.stringValue!)
            #expect(tree.stringified(indent: 2) == c["pretty"]!.stringValue!)
            #expect(tree.stringified() == c["compact"]!.stringValue!)
        }
    }

    @Test("keys keep the order they were set in — except indices, which go first")
    func keyOrder() {
        var object = JSONObject()
        object["z"] = 1; object["a"] = 2; object["10"] = 3; object["2"] = 4; object["01"] = 5
        #expect(object.keys == ["2", "10", "z", "a", "01"])
        object["z"] = 9                                     // replaced where it stands
        #expect(object.keys == ["2", "10", "z", "a", "01"])
        object["a"] = nil
        #expect(object.keys == ["2", "10", "z", "01"])
        let literal: JSON = ["t": 0, "x": 1, "ease": "out"]
        #expect(literal.stringified() == #"{"t":0,"x":1,"ease":"out"}"#)
    }

    @Test("a duplicate key: the later value, in the earlier place")
    func duplicateKeys() throws {
        let tree = try JSON.parse(#"{"a":1,"b":2,"a":3}"#)
        #expect(tree.stringified() == #"{"a":3,"b":2}"#)
    }

    @Test("reads escapes, surrogate pairs and numbers the way JSON.parse does")
    func parsing() throws {
        #expect(try JSON.parse(#""\ud83c\udfac \u00e9 \n \/""#) == .string("🎬 é \n /"))
        #expect(try JSON.parse("[1e2, -0.5, 1E-2, 0]") == [100, -0.5, 0.01, 0])
        #expect(try JSON.parse(" \n{ \"k\" : [ ] }\t") == ["k": []])
        #expect(try JSON.parse("1e999") == .number(.infinity))
        // An escaped NUL is a character like another. Decoding by way of a
        // C string ended the text at it, which is how this came to be here.
        let withNul = try JSON.parse("\"cut\\u" + "0000here\"").stringValue
        #expect(withNul.map { Array($0.utf8) } == Array("cut".utf8) + [0] + Array("here".utf8))
    }

    @Test("refuses what JSON.parse refuses", arguments: [
        "", "{", "[1,]", "{\"a\":1,}", "01", "1.", ".5", "+1", "'a'", "\"\t\"", "\"\\x\"", "nul",
        "[1] 2", "{\"a\" 1}", "\u{FEFF}{}", "NaN", "\"\\u12\"",
    ])
    func refusals(text: String) {
        #expect(throws: JSONParseError.self) { try JSON.parse(text) }
    }

    @Test("non-finite numbers are null, as they are in JavaScript")
    func nonFinite() {
        #expect(JSON.array([.number(.nan), .number(.infinity), .number(-0.0)]).stringified() == "[null,null,0]")
    }

    @Test("matches: any key order, numbers within a tolerance, nothing else loose")
    func matches() throws {
        let a = try JSON.parse(#"{"x":1.00000001,"y":[1,2],"s":"a"}"#)
        let b = try JSON.parse(#"{"s":"a","y":[1,2],"x":1}"#)
        #expect(a != b)
        #expect(!a.matches(b))
        #expect(a.matches(b, tolerance: 1e-6))
        #expect(!a.matches(try JSON.parse(#"{"s":"a","y":[2,1],"x":1}"#), tolerance: 1e-6))
        #expect(!a.matches(try JSON.parse(#"{"s":"a","y":[1,2],"x":1,"extra":null}"#), tolerance: 1e-6))
    }
}

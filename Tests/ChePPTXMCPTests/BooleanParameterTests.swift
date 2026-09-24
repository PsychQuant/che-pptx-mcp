import Testing
import Foundation
import MCP
import PPTXSwift
@testable import ChePPTXMCP

/// PsychQuant/che-pptx-mcp#10: every boolean tool parameter follows the same
/// strict-JSON-type rule #5 established for integers — only the JSON
/// literals `true`/`false` are accepted; strings ("true", "1", "false", ...),
/// numbers and other JSON types are rejected as an `isError` result instead
/// of being silently coerced.
///
/// Before this fix, `Value.boolValue` accepted the string `"true"` (or
/// `"1"`) as `true` — but its `default: return nil` branch was unreachable
/// for `.string`, because the `.string(let s)` case matched first and
/// always returned a non-optional `Bool` (`s == "true" || s == "1"`). So
/// *every other string*, including the literal `"false"`, silently became
/// `false` instead of being rejected. `autosave: "false"` and
/// `autosave: "no thanks"` both quietly behaved like `autosave: false` with
/// no error at all.
struct BooleanParameterTests {
    let server: PPTXMCPServer

    init() async throws {
        server = await PPTXMCPServer()
    }

    func call(_ tool: String, _ args: [String: Value]) async throws -> (isError: Bool, text: String) {
        let result = try await server.handleToolCall(CallTool.Parameters(name: tool, arguments: args))
        let text = result.content.compactMap { content -> String? in
            if case .text(let text, _, _) = content { return text } else { return nil }
        }.joined()
        return (result.isError == true, text)
    }

    /// A fresh, saved-to-disk .pptx file for `open_presentation` calls.
    func fixtureFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bool-param-\(UUID().uuidString).pptx")
        try PptxWriter.write(PptxWriter.createNew(), to: url)
        return url
    }

    /// Arguments (besides `doc_id` and the boolean parameter itself) each
    /// tool needs to reach its `autosave` handling.
    func baseArgs(_ tool: String, docId: String) throws -> [String: Value] {
        switch tool {
        case "open_presentation":
            return ["doc_id": .string(docId), "path": .string(try fixtureFile().path)]
        default:
            return ["doc_id": .string(docId)]
        }
    }

    static let booleanParameters: [(tool: String, key: String)] = [
        ("create_presentation", "autosave"),
        ("open_presentation", "autosave"),
    ]

    // MARK: - The table covers the schema

    /// Mirrors `IntegerParameterTests`' schema-coverage check (#5): every
    /// `boolean`-typed property across every tool schema must be listed in
    /// `booleanParameters`, so a newly added boolean parameter can't be
    /// forgotten by this suite.
    @Test func `Every boolean parameter in the tool schemas is covered by this suite`() throws {
        var schemaPairs: [String] = []
        for tool in server.allTools {
            guard case .object(let schema) = tool.inputSchema,
                  case .object(let properties)? = schema["properties"] else { continue }
            for (key, property) in properties {
                if case .object(let p) = property, p["type"] == .string("boolean") {
                    schemaPairs.append("\(tool.name).\(key)")
                }
            }
        }
        let tablePairs = Self.booleanParameters.map { "\($0.tool).\($0.key)" }
        #expect(schemaPairs.sorted() == tablePairs.sorted())
    }

    // MARK: - Scenario: JSON true/false are accepted

    @Test(arguments: booleanParameters)
    func `JSON true and false are both accepted`(tool: String, key: String) async throws {
        for value in [true, false] {
            let docId = "bool-ok-\(tool)-\(value)-\(UUID().uuidString)"
            var args = try baseArgs(tool, docId: docId)
            args[key] = .bool(value)
            let result = try await call(tool, args)
            #expect(!result.isError, "\(tool).\(key)=\(value): \(result.text)")
        }
    }

    // MARK: - Scenario: missing or null falls back to the documented default (false)

    @Test(arguments: booleanParameters)
    func `Missing or null falls back to the default without an error`(tool: String, key: String) async throws {
        for absent: Value? in [nil, .null] {
            let docId = "bool-absent-\(tool)-\(String(describing: absent))-\(UUID().uuidString)"
            var args = try baseArgs(tool, docId: docId)
            if let absent { args[key] = absent }
            let result = try await call(tool, args)
            #expect(!result.isError, "\(tool).\(key)=\(String(describing: absent)): \(result.text)")
        }
    }

    // MARK: - Scenario: non-boolean JSON types are rejected, not coerced

    /// Every value here used to be accepted (and silently misinterpreted)
    /// by the old lenient `Value.boolValue`: `.string("true")` became
    /// `true`; every other string — `.string("false")` included — became
    /// `false`. Numbers and other JSON types fell through to `nil`
    /// (→ the caller's default), not an error.
    static let nonBooleanValues: [Value] = [
        .string("true"), .string("false"), .string("1"), .string("0"), .string("yes"), .string(""),
        .int(1), .int(0), .double(1.0), .array([]), .object([:]),
    ]

    @Test(arguments: booleanParameters)
    func `Non-boolean JSON types are rejected as an isError result naming the parameter`(
        tool: String, key: String
    ) async throws {
        for bad in Self.nonBooleanValues {
            let docId = "bool-bad-\(tool)-\(UUID().uuidString)"
            var args = try baseArgs(tool, docId: docId)
            args[key] = bad
            let result = try await call(tool, args)
            #expect(result.isError, "\(tool).\(key)=\(bad): \(result.text)")
            #expect(result.text.contains(key), "\(tool).\(key)=\(bad) should name the parameter: \(result.text)")
            #expect(server.openPresentations[docId] == nil,
                    "\(tool).\(key)=\(bad): a rejected call must not create/replace the session")
        }
    }

    /// The exact regression this issue fixes: the string `"false"` used to
    /// be silently accepted and interpreted as `false` (see the old
    /// `Value.boolValue`'s `.string(let s): return s == "true" || s == "1"`
    /// — any string not "true"/"1" fell through to `false`, not `nil`). It
    /// must now be a real, named parameter error, not a quiet `false`.
    @Test func `The string "false" is rejected, not silently coerced to Bool false`() async throws {
        let docId = "bool-string-false-\(UUID().uuidString)"
        let result = try await call("create_presentation", [
            "doc_id": .string(docId), "autosave": .string("false"),
        ])
        #expect(result.isError, "\(result.text)")
        #expect(result.text.contains("autosave"), "\(result.text)")
        #expect(server.openPresentations[docId] == nil)
    }

    // MARK: - Scenario: the boolean actually reaches the autosave behavior it names

    /// Not just "the call doesn't error" — `autosave: true` must genuinely
    /// enable the write-back-on-edit path `markDirty` implements (Server.swift),
    /// and `autosave: false` (or omitted) must not. A validator that accepts
    /// the JSON type but drops the value on the floor would still pass every
    /// other test in this file.
    @Test func `autosave true on create_presentation actually autosaves on edit`() async throws {
        let docId = "bool-behavior-create-\(UUID().uuidString)"
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("bool-behavior-\(UUID().uuidString).pptx")
        defer { try? FileManager.default.removeItem(at: out) }

        let created = try await call("create_presentation", ["doc_id": .string(docId), "autosave": .bool(true)])
        #expect(!created.isError, "\(created.text)")
        let saved = try await call("save_presentation", ["doc_id": .string(docId), "path": .string(out.path)])
        #expect(!saved.isError, "\(saved.text)")
        #expect(server.dirtyState[docId] == false)

        let edited = try await call("insert_text_shape", [
            "doc_id": .string(docId), "slide_index": .int(0), "text": .string("autosaved"),
            "x": .int(0), "y": .int(0), "width": .int(914_400), "height": .int(914_400),
        ])
        #expect(!edited.isError, "\(edited.text)")
        #expect(server.dirtyState[docId] == false,
                "autosave=true must clear dirty by writing back to disk after the edit")
    }

    @Test func `autosave false on create_presentation leaves edits dirty until an explicit save`() async throws {
        let docId = "bool-behavior-nosave-\(UUID().uuidString)"
        let created = try await call("create_presentation", ["doc_id": .string(docId), "autosave": .bool(false)])
        #expect(!created.isError, "\(created.text)")

        let edited = try await call("insert_text_shape", [
            "doc_id": .string(docId), "slide_index": .int(0), "text": .string("not autosaved"),
            "x": .int(0), "y": .int(0), "width": .int(914_400), "height": .int(914_400),
        ])
        #expect(!edited.isError, "\(edited.text)")
        #expect(server.dirtyState[docId] == true,
                "autosave=false must leave the edit dirty — no path was even given to write back to")
    }
}

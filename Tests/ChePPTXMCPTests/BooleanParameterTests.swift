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
    /// Every call site is responsible for removing what this returns
    /// (review round 1, LOW 4: orphaned fixtures must not accumulate).
    func fixtureFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bool-param-\(UUID().uuidString).pptx")
        try PptxWriter.write(PptxWriter.createNew(), to: url)
        return url
    }

    /// Arguments (besides `doc_id` and the boolean parameter itself) each
    /// tool needs to reach its `autosave` handling. When `tool` is
    /// `open_presentation`, the fixture file's URL is also returned so the
    /// caller can remove it afterwards.
    func baseArgs(_ tool: String, docId: String) throws -> (args: [String: Value], fixture: URL?) {
        switch tool {
        case "open_presentation":
            let fixture = try fixtureFile()
            return (["doc_id": .string(docId), "path": .string(fixture.path)], fixture)
        default:
            return (["doc_id": .string(docId)], nil)
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
            let (baseArgs, fixture) = try baseArgs(tool, docId: docId)
            defer { if let fixture { try? FileManager.default.removeItem(at: fixture) } }
            var args = baseArgs
            args[key] = .bool(value)
            let result = try await call(tool, args)
            #expect(!result.isError, "\(tool).\(key)=\(value): \(result.text)")
        }
    }

    // MARK: - Scenario: missing or null falls back to the documented default (false)

    /// Not just "the call doesn't error" (review round 1, LOW 3): a
    /// regression that defaulted to `true` instead of `false` would still
    /// pass a bare `!result.isError` check. Establishing a save path and
    /// then editing distinguishes the two defaults the same way the
    /// `autosave true`/`autosave false` behavioral tests below do.
    @Test(arguments: booleanParameters)
    func `Missing or null falls back to false, not true, without an error`(tool: String, key: String) async throws {
        for absent: Value? in [nil, .null] {
            let docId = "bool-absent-\(tool)-\(String(describing: absent))-\(UUID().uuidString)"
            let (baseArgs, fixture) = try baseArgs(tool, docId: docId)
            defer { if let fixture { try? FileManager.default.removeItem(at: fixture) } }
            var args = baseArgs
            if let absent { args[key] = absent }
            let result = try await call(tool, args)
            #expect(!result.isError, "\(tool).\(key)=\(String(describing: absent)): \(result.text)")

            // Establish a save path (open_presentation already has one via
            // its fixture; create_presentation needs an explicit save), then
            // edit. If the default were `true`, this edit would autosave
            // and clear dirty; the documented default `false` leaves it dirty.
            //
            // The cleanup `defer` for `savePath` is declared here, at the
            // `for absent` iteration's own scope — NOT nested inside the
            // `if` block below — so it fires after the edit, not before it
            // (review round 2, LOW 2: a `defer` inside the `if` would delete
            // the file before `insert_text_shape` runs; a regression that
            // autosaves by default would then recreate an orphan file with
            // no cleanup left to remove it).
            var savePath: URL?
            defer { if let savePath { try? FileManager.default.removeItem(at: savePath) } }
            if tool == "create_presentation" {
                let path = try fixtureFile()
                savePath = path
                let saved = try await call("save_presentation", [
                    "doc_id": .string(docId), "path": .string(path.path),
                ])
                #expect(!saved.isError, "\(saved.text)")
            }
            let edited = try await call("insert_text_shape", [
                "doc_id": .string(docId), "slide_index": .int(0), "text": .string("x"),
                "x": .int(0), "y": .int(0), "width": .int(914_400), "height": .int(914_400),
            ])
            #expect(!edited.isError, "\(edited.text)")
            #expect(server.dirtyState[docId] == true,
                    "\(tool).\(key)=\(String(describing: absent)): default must be false — an edit must stay dirty, not autosave")
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
        // open_presentation only needs one fixture file for the whole loop
        // — every case is rejected before the file is ever read.
        let sharedFixture: URL? = tool == "open_presentation" ? try fixtureFile() : nil
        defer { if let sharedFixture { try? FileManager.default.removeItem(at: sharedFixture) } }

        for bad in Self.nonBooleanValues {
            let docId = "bool-bad-\(tool)-\(UUID().uuidString)"
            var args: [String: Value] = ["doc_id": .string(docId)]
            if let sharedFixture { args["path"] = .string(sharedFixture.path) }
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

    /// Not just "the call doesn't error" and not just "the dirty flag
    /// clears" (review round 1, MEDIUM 3: a broken implementation that
    /// clears the flag without writing would pass a dirty-flag-only check)
    /// — `autosave: true` must genuinely write the edit to disk. Reloading
    /// the file with a fresh `PptxReader` (not the in-memory session) is
    /// the only way to prove that.
    @Test func `autosave true on create_presentation actually persists the edit to disk`() async throws {
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

        let reloaded = try PptxReader.read(from: out)
        #expect(reloaded.slides[0].getText().contains("autosaved"),
                "autosave=true must have written the edit to disk, not just cleared the in-memory dirty flag")
    }

    /// Not just "the flag stays dirty" (review round 1, MEDIUM 2: without a
    /// save path even a regression that treats `false` as `true` would
    /// leave the edit dirty, because `markDirty` only writes back when
    /// `originalPaths[docId]` is set). Establishing a path first — exactly
    /// like the `true` test above — makes this test actually distinguish
    /// "autosave disabled" from "autosave enabled but nowhere to write",
    /// and the reload confirms the edit was never persisted.
    @Test func `autosave false on create_presentation leaves edits dirty and unpersisted even with a save path`() async throws {
        let docId = "bool-behavior-nosave-\(UUID().uuidString)"
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("bool-behavior-\(UUID().uuidString).pptx")
        defer { try? FileManager.default.removeItem(at: out) }

        let created = try await call("create_presentation", ["doc_id": .string(docId), "autosave": .bool(false)])
        #expect(!created.isError, "\(created.text)")
        let saved = try await call("save_presentation", ["doc_id": .string(docId), "path": .string(out.path)])
        #expect(!saved.isError, "\(saved.text)")
        #expect(server.dirtyState[docId] == false)

        let edited = try await call("insert_text_shape", [
            "doc_id": .string(docId), "slide_index": .int(0), "text": .string("not autosaved"),
            "x": .int(0), "y": .int(0), "width": .int(914_400), "height": .int(914_400),
        ])
        #expect(!edited.isError, "\(edited.text)")
        #expect(server.dirtyState[docId] == true,
                "autosave=false must leave the edit dirty even though a save path exists")

        let reloaded = try PptxReader.read(from: out)
        #expect(!reloaded.slides[0].getText().contains("not autosaved"),
                "autosave=false must not have written the unsaved edit to disk")
    }

    // MARK: - Scenario: the boolean actually reaches open_presentation too

    /// Review round 2, MEDIUM 1: the `create_presentation` behavioral tests
    /// above don't prove `open_presentation`'s own `autosave` argument
    /// actually reaches `initializeSession` — a regression that validates
    /// the JSON type but always passes a hardcoded value at that call site
    /// would still pass every other test in this file (including the
    /// generic `true`/`false` acceptance test, which only checks
    /// `!isError`). `open_presentation` already has a save path for free —
    /// it's the fixture file it opens — so no extra `save_presentation`
    /// step is needed before editing.
    @Test func `autosave true on open_presentation actually persists the edit to disk`() async throws {
        let fixture = try fixtureFile()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let docId = "bool-behavior-open-true-\(UUID().uuidString)"

        let opened = try await call("open_presentation", [
            "doc_id": .string(docId), "path": .string(fixture.path), "autosave": .bool(true),
        ])
        #expect(!opened.isError, "\(opened.text)")
        #expect(server.dirtyState[docId] == false)

        let edited = try await call("insert_text_shape", [
            "doc_id": .string(docId), "slide_index": .int(0), "text": .string("open-autosaved"),
            "x": .int(0), "y": .int(0), "width": .int(914_400), "height": .int(914_400),
        ])
        #expect(!edited.isError, "\(edited.text)")
        #expect(server.dirtyState[docId] == false,
                "autosave=true on open_presentation must clear dirty by writing back to disk after the edit")

        let reloaded = try PptxReader.read(from: fixture)
        #expect(reloaded.slides[0].getText().contains("open-autosaved"),
                "autosave=true on open_presentation must have written the edit to the opened file")
    }

    @Test func `autosave false on open_presentation leaves edits dirty and unpersisted`() async throws {
        let fixture = try fixtureFile()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let docId = "bool-behavior-open-false-\(UUID().uuidString)"

        let opened = try await call("open_presentation", [
            "doc_id": .string(docId), "path": .string(fixture.path), "autosave": .bool(false),
        ])
        #expect(!opened.isError, "\(opened.text)")
        #expect(server.dirtyState[docId] == false)

        let edited = try await call("insert_text_shape", [
            "doc_id": .string(docId), "slide_index": .int(0), "text": .string("open-not-autosaved"),
            "x": .int(0), "y": .int(0), "width": .int(914_400), "height": .int(914_400),
        ])
        #expect(!edited.isError, "\(edited.text)")
        #expect(server.dirtyState[docId] == true,
                "autosave=false on open_presentation must leave the edit dirty")

        let reloaded = try PptxReader.read(from: fixture)
        #expect(!reloaded.slides[0].getText().contains("open-not-autosaved"),
                "autosave=false on open_presentation must not have written the unsaved edit to disk")
    }
}

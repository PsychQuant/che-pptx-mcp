import Testing
import Foundation
import MCP
import PPTXSwift
@testable import ChePPTXMCP

/// Content-loss paths found by the cross-model review of PsychQuant/macdoc#90
/// follow-ups (che-pptx-mcp round 2, HIGH 1 and 2). Both predate the branch.
struct SessionSafetyTests {
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

    // MARK: - HIGH 1: a failed autosave keeps the edit and the dirty flag

    @Test func `A failed autosave leaves the session dirty, says so, and blocks close`() async throws {
        // A save path whose parent directory does not exist: every write fails.
        let missingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pptx-autosave-missing-\(UUID().uuidString)")
        let path = missingDir.appendingPathComponent("deck.pptx").path
        server.initializeSession(docId: "auto", presentation: PptxWriter.createNew(), sourcePath: path, autosave: true)

        let edit = try await call("insert_text_shape", [
            "doc_id": .string("auto"), "slide_index": .int(0), "text": .string("kept"),
        ])
        #expect(!edit.isError, "the edit itself succeeded: \(edit.text)")
        #expect(edit.text.contains("自動存檔失敗"), "the caller must learn the autosave failed: \(edit.text)")
        #expect(server.dirtyState["auto"] == true)
        #expect(!FileManager.default.fileExists(atPath: path))

        let close = try await call("close_presentation", ["doc_id": .string("auto")])
        #expect(close.isError, "closing would drop the only copy of the edit: \(close.text)")
        let pres = try #require(server.openPresentations["auto"])
        #expect(pres.slides[0].shapes.contains { $0.textBody?.getText() == "kept" })
    }

    @Test func `A successful autosave still clears the dirty flag without a warning`() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pptx-autosave-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("deck.pptx").path
        server.initializeSession(docId: "ok", presentation: PptxWriter.createNew(), sourcePath: path, autosave: true)

        let edit = try await call("insert_text_shape", [
            "doc_id": .string("ok"), "slide_index": .int(0), "text": .string("saved"),
        ])
        #expect(!edit.isError)
        #expect(!edit.text.contains("自動存檔失敗"))
        #expect(server.dirtyState["ok"] == false)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    // MARK: - HIGH 2: delete_image deletes pictures only

    @Test func `delete_image refuses to delete a text shape, a table or a group`() async throws {
        var pres = PptxWriter.createNew()
        pres.slides[0].elements = [
            .shape(Shape(id: 2, name: "Text")),
            .graphicFrame(GraphicFrame(id: 3, name: "Table",
                                       table: DrawingTable(columns: [TableColumn(width: 914400)],
                                                           rows: [TableRow(height: 370840, cells: [TableCell(text: "")])]))),
            .group(GroupShape(id: 4, name: "Group", elements: [.shape(Shape(id: 5, name: "child"))])),
            .picture(Picture(id: 6, name: "Pic")),
        ]
        server.initializeSession(docId: "del", presentation: pres, sourcePath: nil, autosave: false)

        for id in [2, 3, 4, 5] {
            let result = try await call("delete_image", ["doc_id": .string("del"), "slide_index": .int(0), "shape_id": .int(id)])
            #expect(result.isError, "id=\(id): \(result.text)")
            #expect(result.text.contains("shape_id"), "\(result.text)")
        }
        #expect(try #require(server.openPresentations["del"]).slides[0].elements.count == 4)
        #expect(server.dirtyState["del"] == false)

        let ok = try await call("delete_image", ["doc_id": .string("del"), "slide_index": .int(0), "shape_id": .int(6)])
        #expect(!ok.isError, "\(ok.text)")
        #expect(try #require(server.openPresentations["del"]).slides[0].pictures.isEmpty)
    }
}

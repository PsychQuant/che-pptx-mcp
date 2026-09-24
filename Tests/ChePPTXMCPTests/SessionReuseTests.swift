import XCTest
import Foundation
import MCP
import PPTXSwift
@testable import ChePPTXMCP

/// #8：`create_presentation`／`open_presentation` 重用 `doc_id` 時，不得蓋掉還沒存檔的 session。
/// 乾淨的 session 維持可替換，既有的「重新開啟同一個 doc_id」用法不受影響。
final class SessionReuseTests: XCTestCase {

    private var server: PPTXMCPServer!
    private let docId = "reuse"

    override func setUp() async throws {
        server = await PPTXMCPServer()
        _ = try call("create_presentation", ["doc_id": .string(docId)])
    }

    private func call(_ name: String, _ args: [String: Value]) throws -> String {
        try server.executeToolTask(name: name, args: args)
    }

    private func snapshot() throws -> String {
        let pres = try XCTUnwrap(server.openPresentations[docId])
        var out = ""
        dump(pres, to: &out)
        return out + "\ndirty=\(String(describing: server.dirtyState[docId]))"
    }

    private func makeDirty() throws {
        _ = try call("insert_text_shape", [
            "doc_id": .string(docId), "slide_index": .int(0), "text": .string("unsaved"),
            "x": .int(0), "y": .int(0), "width": .int(914400), "height": .int(914400),
        ])
        XCTAssertEqual(server.dirtyState[docId], true)
    }

    private func savedFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reuse-\(UUID().uuidString).pptx")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try PptxWriter.write(PptxWriter.createNew(), to: url)
        return url
    }

    func testCreateRefusesToReplaceADirtySession() throws {
        try makeDirty()
        let before = try snapshot()
        XCTAssertThrowsError(try call("create_presentation", ["doc_id": .string(docId)])) { error in
            XCTAssertTrue("\(error)".contains(docId), "錯誤要指名 doc_id：\(error)")
        }
        XCTAssertEqual(try snapshot(), before, "被拒絕時原 session 必須完全不變")
    }

    func testOpenRefusesToReplaceADirtySession() throws {
        let file = try savedFile()
        try makeDirty()
        let before = try snapshot()
        XCTAssertThrowsError(try call("open_presentation", ["doc_id": .string(docId), "path": .string(file.path)]))
        XCTAssertEqual(try snapshot(), before, "被拒絕時原 session 必須完全不變")
    }

    func testCleanSessionCanStillBeReplaced() throws {
        let file = try savedFile()
        XCTAssertEqual(server.dirtyState[docId], false)
        XCTAssertNoThrow(try call("open_presentation", ["doc_id": .string(docId), "path": .string(file.path)]))
        XCTAssertNoThrow(try call("create_presentation", ["doc_id": .string(docId)]))
        XCTAssertEqual(server.dirtyState[docId], false)
    }
}

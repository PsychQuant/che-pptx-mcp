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

    /// 替換必須真的換掉內容，不能只是「不拋錯」：open 載入檔案（3 張投影片），create 換回 1 張空白投影片。
    func testCleanSessionCanStillBeReplaced() throws {
        var threeSlides = PptxWriter.createNew()
        threeSlides.slides.append(contentsOf: [threeSlides.slides[0], threeSlides.slides[0]])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("reuse-\(UUID().uuidString).pptx")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        try PptxWriter.write(threeSlides, to: file)
        XCTAssertEqual(server.dirtyState[docId], false)
        XCTAssertEqual(server.openPresentations[docId]?.slideCount, 1)

        XCTAssertNoThrow(try call("open_presentation", ["doc_id": .string(docId), "path": .string(file.path)]))
        XCTAssertEqual(server.openPresentations[docId]?.slideCount, 3, "open 必須真的載入檔案內容")
        XCTAssertNoThrow(try call("create_presentation", ["doc_id": .string(docId)]))
        XCTAssertEqual(server.openPresentations[docId]?.slideCount, 1, "create 必須真的換成新文件")
        XCTAssertEqual(server.dirtyState[docId], false)
    }

    /// autosave 寫檔失敗時 dirty 必須保持（f564c8a），因此重用 doc_id 仍被拒絕。
    func testFailedAutosaveKeepsTheSessionProtected() throws {
        let unwritable = "/nonexistent-dir-\(UUID().uuidString)/deck.pptx"
        server.initializeSession(docId: "autosave", presentation: PptxWriter.createNew(),
                                 sourcePath: unwritable, autosave: true)
        _ = try call("insert_text_shape", [
            "doc_id": .string("autosave"), "slide_index": .int(0), "text": .string("unsaved"),
            "x": .int(0), "y": .int(0), "width": .int(914400), "height": .int(914400),
        ])
        XCTAssertEqual(server.dirtyState["autosave"], true, "autosave 失敗時 dirty 不得被清掉")
        XCTAssertThrowsError(try call("create_presentation", ["doc_id": .string("autosave")]))
    }

    /// 存檔之後 session 是乾淨的，可以重用。
    func testSavedSessionCanBeReplaced() throws {
        try makeDirty()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("reuse-\(UUID().uuidString).pptx")
        addTeardownBlock { try? FileManager.default.removeItem(at: out) }
        _ = try call("save_presentation", ["doc_id": .string(docId), "path": .string(out.path)])
        XCTAssertEqual(server.dirtyState[docId], false)
        XCTAssertNoThrow(try call("create_presentation", ["doc_id": .string(docId)]))
    }
}

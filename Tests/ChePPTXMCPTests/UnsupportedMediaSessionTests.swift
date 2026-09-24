import Testing
import Foundation
import MCP
import PPTXSwift
@testable import ChePPTXMCP

/// pptx-swift 0.4.0（PsychQuant/pptx-swift#5）起，含音訊、影片或換場音效的
/// 簡報一律拒絕寫出。開檔當下就要讓呼叫端知道這份簡報存不了，而不是等到每一次
/// autosave 或 save_presentation 失敗才發現。
struct UnsupportedMediaSessionTests {
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

    /// 以 pptx-swift 寫出一份空白簡報，再在第一張投影片的 XML 注入 DrawingML 的
    /// `a:audioFile`，模擬含音訊的真實簡報（不從別的 repo 複製二進位 fixture）。
    static func deckWithAudio() throws -> URL {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("pptx-audio-\(UUID().uuidString)")
        let unpacked = work.appendingPathComponent("unpacked")
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let source = work.appendingPathComponent("source.pptx")
        try PptxWriter.write(PptxWriter.createNew(), to: source)
        try run("/usr/bin/unzip", ["-q", source.path, "-d", unpacked.path])

        let slide = unpacked.appendingPathComponent("ppt/slides/slide1.xml")
        let xml = try String(contentsOf: slide, encoding: .utf8)
        let audio = #"<p:nvPr><a:audioFile xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"/></p:nvPr>"#
        guard let range = xml.range(of: "<p:nvPr/>") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try xml.replacingCharacters(in: range, with: audio).write(to: slide, atomically: true, encoding: .utf8)

        let deck = work.appendingPathComponent("audio.pptx")
        try run("/usr/bin/zip", ["-q", "-r", "-X", deck.path, "."], in: unpacked)
        return deck
    }

    static func run(_ tool: String, _ arguments: [String], in directory: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad)
        }
    }

    @Test func `Opening a deck with audio says up front that it cannot be saved`() async throws {
        let deck = try Self.deckWithAudio()
        defer { try? FileManager.default.removeItem(at: deck.deletingLastPathComponent()) }

        let open = try await call("open_presentation", [
            "path": .string(deck.path), "doc_id": .string("audio"),
        ])
        #expect(!open.isError, "reading is still supported: \(open.text)")
        #expect(open.text.contains("第 1 張"), "the warning names the slide: \(open.text)")
        #expect(open.text.contains("無法存檔"), "the caller learns before editing: \(open.text)")

        let save = try await call("save_presentation", [
            "doc_id": .string("audio"),
            "path": .string(deck.deletingLastPathComponent().appendingPathComponent("out.pptx").path),
        ])
        #expect(save.isError, "the writer still refuses: \(save.text)")
        #expect(save.text.contains("投影片 1"), "the refusal is a readable message, not a raw Swift error: \(save.text)")
    }

    @Test func `Opening a deck without media carries no warning`() async throws {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("pptx-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let deck = work.appendingPathComponent("plain.pptx")
        try PptxWriter.write(PptxWriter.createNew(), to: deck)

        let open = try await call("open_presentation", [
            "path": .string(deck.path), "doc_id": .string("plain"),
        ])
        #expect(!open.isError)
        #expect(!open.text.contains("無法存檔"), "\(open.text)")
    }
}

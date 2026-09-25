import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MCP
import PPTXSwift
@testable import ChePPTXMCP

/// pptx-swift 0.6.0 批次審查（PsychQuant/pptx-swift#11／#12 的 FAIL 項目）在
/// che-pptx-mcp 這一層的端到端驗證：
///
/// - H2：`set_shape_fill` 對讀進來的漸層／圖片填色形狀以前是靜默的 no-op
///   （回報成功、存檔後仍是原本的填色）。
/// - C1：圖片填色形狀引用 relationship，整份簡報無法存檔；`open_presentation`
///   要在開檔時就指出是哪張投影片的哪個元素，而用 `set_shape_fill` 換掉圖片填色
///   之後要能存檔。
/// - L5：`set_placeholder_geometry` 移動自訂路徑形狀後，存檔的檔案仍保有路徑。
@Suite(.serialized)
struct ShapePropertyToolTests {
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

    // MARK: - Fixture

    static let nsA = "http://schemas.openxmlformats.org/drawingml/2006/main"

    static func shapeXML(id: Int, name: String, spPrInner: String) -> String {
        "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"\(name)\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>"
            + "<p:spPr><a:xfrm><a:off x=\"914400\" y=\"914400\"/><a:ext cx=\"1828800\" cy=\"914400\"/></a:xfrm>"
            + spPrInner + "</p:spPr><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang=\"en-US\"/></a:p></p:txBody></p:sp>"
    }

    static let gradientShape = shapeXML(
        id: 20, name: "Gradient",
        spPrInner: "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:gradFill><a:gsLst><a:gs pos=\"0\"><a:srgbClr val=\"FF0000\"/></a:gs><a:gs pos=\"100000\"><a:srgbClr val=\"0000FF\"/></a:gs></a:gsLst><a:lin ang=\"0\" scaled=\"0\"/></a:gradFill>")
    /// `r:embed="rId2"`：寫出這份素材時 pptx-swift 把 rId2 配給投影片上的圖片。
    static let pictureFilledShape = shapeXML(
        id: 21, name: "PictureFilled",
        spPrInner: "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:blipFill><a:blip r:embed=\"rId2\"/><a:stretch><a:fillRect/></a:stretch></a:blipFill>")
    static let customPathShape = shapeXML(
        id: 22, name: "Cloud",
        spPrInner: "<a:custGeom><a:avLst/><a:gdLst/><a:ahLst/><a:cxnLst/><a:rect l=\"l\" t=\"t\" r=\"r\" b=\"b\"/><a:pathLst><a:path w=\"100\" h=\"100\"><a:moveTo><a:pt x=\"0\" y=\"0\"/></a:moveTo><a:cubicBezTo><a:pt x=\"30\" y=\"80\"/><a:pt x=\"70\" y=\"80\"/><a:pt x=\"100\" y=\"0\"/></a:cubicBezTo><a:close/></a:path></a:pathLst></a:custGeom>")

    /// 一份真實的 .pptx：pptx-swift 寫出含一張圖片的投影片，再把 `shapesXML`
    /// 接進 `p:spTree` 結尾（不從別的 repo 複製二進位 fixture）。
    static func deck(_ shapesXML: String) throws -> URL {
        var pres = PptxWriter.createNew()
        pres.images = [MediaFile(id: "p.png", fileName: "p.png", data: try png())]
        pres.slides[0].elements = [.picture(Picture(id: 2, name: "Photo", mediaFileName: "p.png"))]
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("pptx-sppr-\(UUID().uuidString)")
        let unpacked = work.appendingPathComponent("unpacked")
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let source = work.appendingPathComponent("source.pptx")
        try PptxWriter.write(pres, to: source)
        try UnsupportedMediaSessionTests.run("/usr/bin/unzip", ["-q", source.path, "-d", unpacked.path])

        let slide = unpacked.appendingPathComponent("ppt/slides/slide1.xml")
        let xml = try String(contentsOf: slide, encoding: .utf8)
        guard let range = xml.range(of: "</p:spTree>") else { throw CocoaError(.fileReadCorruptFile) }
        try xml.replacingCharacters(in: range, with: shapesXML + "</p:spTree>").write(to: slide, atomically: true, encoding: .utf8)

        let deck = work.appendingPathComponent("deck.pptx")
        try UnsupportedMediaSessionTests.run("/usr/bin/zip", ["-q", "-r", "-X", deck.path, "."], in: unpacked)
        return deck
    }

    static func png() throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return output as Data
    }

    static func shape(named name: String, in url: URL) throws -> Shape? {
        try PptxReader.read(from: url).slides[0].elements.compactMap { element -> Shape? in
            if case .shape(let s) = element, s.name == name { return s }
            return nil
        }.first
    }

    // MARK: - H2 + C1: set_shape_fill on gradient and picture fills

    @Test func `set_shape_fill replaces a gradient fill read from a file`() async throws {
        let deck = try Self.deck(Self.gradientShape)
        let out = deck.deletingLastPathComponent().appendingPathComponent("out-gradient.pptx")
        _ = try await call("open_presentation", ["doc_id": .string("grad"), "path": .string(deck.path)])
        let set = try await call("set_shape_fill", ["doc_id": .string("grad"), "slide_index": .int(0), "shape_id": .int(20), "color": .string("00FF00")])
        #expect(!set.isError, "\(set.text)")
        let save = try await call("save_presentation", ["doc_id": .string("grad"), "path": .string(out.path)])
        #expect(!save.isError, "\(save.text)")

        let back = try #require(try Self.shape(named: "Gradient", in: out))
        guard case .solid(let color)? = back.fill else {
            Issue.record("set_shape_fill was a silent no-op: \(String(describing: back.fill))")
            return
        }
        #expect(color == "00FF00")
    }

    @Test func `A picture-filled shape is named at open, blocks saving, and set_shape_fill makes the deck savable`() async throws {
        let deck = try Self.deck(Self.pictureFilledShape)
        let out = deck.deletingLastPathComponent().appendingPathComponent("out-picture.pptx")

        let opened = try await call("open_presentation", ["doc_id": .string("pic"), "path": .string(deck.path)])
        #expect(!opened.isError, "\(opened.text)")
        #expect(opened.text.contains("第 1 張"), "the notice must name the slide: \(opened.text)")
        #expect(opened.text.contains("id=21"), "the notice must name the element: \(opened.text)")

        let refused = try await call("save_presentation", ["doc_id": .string("pic"), "path": .string(out.path)])
        #expect(refused.isError, "saving must be refused while the picture fill's relationship is still there: \(refused.text)")
        #expect(!FileManager.default.fileExists(atPath: out.path))

        let set = try await call("set_shape_fill", ["doc_id": .string("pic"), "slide_index": .int(0), "shape_id": .int(21), "color": .string("00FF00")])
        #expect(!set.isError, "\(set.text)")
        let save = try await call("save_presentation", ["doc_id": .string("pic"), "path": .string(out.path)])
        #expect(!save.isError, "\(save.text)")

        let back = try #require(try Self.shape(named: "PictureFilled", in: out))
        guard case .solid(let color)? = back.fill else {
            Issue.record("the picture fill survived set_shape_fill: \(String(describing: back.fill))")
            return
        }
        #expect(color == "00FF00")
    }

    @Test func `A deck without unwritable content gets no save notice`() async throws {
        let deck = try Self.deck(Self.gradientShape)
        let opened = try await call("open_presentation", ["doc_id": .string("clean"), "path": .string(deck.path)])
        #expect(!opened.text.contains("無法存檔"), "\(opened.text)")
    }

    // MARK: - L5: set_placeholder_geometry keeps a custom path through a save

    @Test func `set_placeholder_geometry on a custom path shape keeps the path in the saved file`() async throws {
        let deck = try Self.deck(Self.customPathShape)
        let out = deck.deletingLastPathComponent().appendingPathComponent("out-cloud.pptx")
        _ = try await call("open_presentation", ["doc_id": .string("cloud"), "path": .string(deck.path)])
        let moved = try await call("set_placeholder_geometry", [
            "doc_id": .string("cloud"), "slide_index": .int(0), "shape_id": .int(22),
            "x_cm": .double(5), "y_cm": .double(6), "width_cm": .double(7), "height_cm": .double(8),
        ])
        #expect(!moved.isError, "\(moved.text)")
        let save = try await call("save_presentation", ["doc_id": .string("cloud"), "path": .string(out.path)])
        #expect(!save.isError, "\(save.text)")

        let unpacked = out.deletingLastPathComponent().appendingPathComponent("out-cloud")
        try UnsupportedMediaSessionTests.run("/usr/bin/unzip", ["-q", "-o", out.path, "-d", unpacked.path])
        let slide = try XMLDocument(contentsOf: unpacked.appendingPathComponent("ppt/slides/slide1.xml"))
        let spPr = try #require(try slide.nodes(forXPath: "//*[local-name()='cNvPr'][@name='Cloud']/../../*[local-name()='spPr']").first as? XMLElement)
        #expect(try spPr.nodes(forXPath: "*[local-name()='prstGeom']").isEmpty, "the cloud must not turn into a preset rectangle")
        #expect(try !spPr.nodes(forXPath: "*[local-name()='custGeom']//*[local-name()='cubicBezTo']").isEmpty,
                "the custom path must be in the saved file")
        let off = try spPr.nodes(forXPath: "*[local-name()='xfrm']/*[local-name()='off']").first as? XMLElement
        #expect(off?.attribute(forName: "x")?.stringValue == "1800000")
    }
}

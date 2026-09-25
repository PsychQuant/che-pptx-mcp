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
/// - L4：刪掉被連接線黏著的形狀後再插入新元素，新元素不得接手舊 id 上的連接線
///   綁定。
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

    // MARK: - R2 M-1 / L-6: the remedy the notice gives must be one the tools can carry out

    /// 審查者的 `probe_grouped.pptx` 情境：圖片填色形狀 id=21 包在群組 id=90 裡。
    /// `set_shape_fill`／`delete_shape` 只看頂層元素，找不到 id=21——提示要指名
    /// 群組，並給唯一走得通的補救：刪除整個群組。
    static let groupedPictureFill = "<p:grpSp><p:nvGrpSpPr><p:cNvPr id=\"90\" name=\"Group 90\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>"
        + "<p:grpSpPr><a:xfrm><a:off x=\"914400\" y=\"914400\"/><a:ext cx=\"1828800\" cy=\"914400\"/><a:chOff x=\"914400\" y=\"914400\"/><a:chExt cx=\"1828800\" cy=\"914400\"/></a:xfrm></p:grpSpPr>"
        + pictureFilledShape + "</p:grpSp>"

    @Test func `A blocker inside a group names the group and only suggests deleting the whole group`() async throws {
        let deck = try Self.deck(Self.groupedPictureFill)
        let out = deck.deletingLastPathComponent().appendingPathComponent("out-grouped.pptx")
        let opened = try await call("open_presentation", ["doc_id": .string("grouped"), "path": .string(deck.path)])
        #expect(opened.text.contains("群組 id=90 內的形狀 id=21"), "the notice must say which group: \(opened.text)")
        #expect(opened.text.contains("刪除整個群組 id=90"), "the only remedy the tools support is deleting the group: \(opened.text)")
        #expect(!opened.text.contains("set_shape_fill"), "set_shape_fill cannot reach a shape inside a group: \(opened.text)")

        let refused = try await call("save_presentation", ["doc_id": .string("grouped"), "path": .string(out.path)])
        #expect(refused.isError)
        #expect(refused.text.contains("群組 id=90 內的形狀 id=21"), "the save error must say which group too: \(refused.text)")
        #expect(refused.text.contains("刪除整個群組 id=90"), "\(refused.text)")

        let deleted = try await call("delete_shape", ["doc_id": .string("grouped"), "slide_index": .int(0), "shape_id": .int(90)])
        #expect(!deleted.isError, "\(deleted.text)")
        let saved = try await call("save_presentation", ["doc_id": .string("grouped"), "path": .string(out.path)])
        #expect(!saved.isError, "\(saved.text)")
    }

    /// 連接線的原樣片段擋住存檔時，`set_shape_fill` 不接受連接線，不能建議它。
    @Test func `A connector blocker does not suggest set_shape_fill`() async throws {
        let connector = "<p:cxnSp><p:nvCxnSpPr><p:cNvPr id=\"23\" name=\"Arrow\"/><p:cNvCxnSpPr/><p:nvPr/></p:nvCxnSpPr>"
            + "<p:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"914400\" cy=\"0\"/></a:xfrm><a:prstGeom prst=\"line\"><a:avLst/></a:prstGeom>"
            + "<a:effectDag><a:fillOverlay blend=\"over\"><a:blipFill><a:blip r:embed=\"rId2\"/></a:blipFill></a:fillOverlay></a:effectDag></p:spPr></p:cxnSp>"
        let deck = try Self.deck(connector)
        let opened = try await call("open_presentation", ["doc_id": .string("conn-block"), "path": .string(deck.path)])
        #expect(opened.text.contains("連接線 id=23"), "\(opened.text)")
        #expect(!opened.text.contains("set_shape_fill"), "set_shape_fill does not accept connectors: \(opened.text)")
        #expect(opened.text.contains("delete_shape"), "\(opened.text)")
    }

    static let chartFrame = "<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id=\"30\" name=\"Chart 1\"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr>"
        + "<p:xfrm><a:off x=\"914400\" y=\"914400\"/><a:ext cx=\"4572000\" cy=\"2743200\"/></p:xfrm>"
        + "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/chart\">"
        + "<c:chart xmlns:c=\"http://schemas.openxmlformats.org/drawingml/2006/chart\" r:id=\"rId9\"/></a:graphicData></a:graphic></p:graphicFrame>"

    @Test func `A chart is described as a chart, and moving it explains why it cannot be moved`() async throws {
        let deck = try Self.deck(Self.chartFrame)
        let opened = try await call("open_presentation", ["doc_id": .string("chart"), "path": .string(deck.path)])
        #expect(opened.text.contains("圖表 id=30"), "\(opened.text)")
        #expect(!opened.text.contains("<graphicFrame>"), "\(opened.text)")
        #expect(!opened.text.contains("set_shape_fill"), "\(opened.text)")
        #expect(opened.text.contains("delete_shape shape_id=30"), "\(opened.text)")

        let moved = try await call("set_placeholder_geometry", [
            "doc_id": .string("chart"), "slide_index": .int(0), "shape_id": .int(30),
            "x_cm": .double(1), "y_cm": .double(1), "width_cm": .double(2), "height_cm": .double(2),
        ])
        #expect(moved.isError)
        #expect(moved.text.contains("圖表"), "the error must say it is a chart: \(moved.text)")
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

    // MARK: - L4: a deleted shape's id must not inherit its connector bindings

    /// 形狀 id=10 是投影片上最大的 id，連接線 id=9 黏在它上面。刪掉 10 之後，
    /// 最大 id 變成 9，新元素以前會拿到 10——連接線就靜默改黏到新元素上。
    func installGluedSession(_ docId: String) {
        var pres = PptxWriter.createNew()
        pres.slides[0].elements = [
            .shape(Shape(id: 2, name: "Title", size: Size(width: 914400, height: 914400))),
            .connector(Connector(id: 9, name: "Connector 1",
                                 startConnection: ConnectionSite(shapeId: 2, index: 3),
                                 endConnection: ConnectionSite(shapeId: 10, index: 1))),
            .shape(Shape(id: 10, name: "Target", size: Size(width: 914400, height: 914400))),
        ]
        server.initializeSession(docId: docId, presentation: pres, sourcePath: nil, autosave: false)
    }

    func connectorEnds(_ docId: String) throws -> (start: Int?, end: Int?) {
        let slide = try #require(server.openPresentations[docId]?.slides[0])
        let connector = try #require(slide.elements.compactMap { element -> Connector? in
            if case .connector(let c) = element { return c }
            return nil
        }.first)
        return (connector.startConnection?.shapeId, connector.endConnection?.shapeId)
    }

    @Test func `Deleting a glued shape unbinds the connector so a new element does not inherit the binding`() async throws {
        installGluedSession("glued")
        let deleted = try await call("delete_shape", ["doc_id": .string("glued"), "slide_index": .int(0), "shape_id": .int(10)])
        #expect(!deleted.isError, "\(deleted.text)")
        #expect(try connectorEnds("glued").end == nil, "the connector end glued to the deleted shape must be released")
        #expect(try connectorEnds("glued").start == 2, "the other end stays glued")

        let inserted = try await call("insert_text_shape", [
            "doc_id": .string("glued"), "slide_index": .int(0), "text": .string("New"),
            "x": .int(0), "y": .int(0), "width": .int(914400), "height": .int(914400),
        ])
        let digits = inserted.text.split(separator: "=").last?.prefix { $0.isNumber } ?? ""
        let newId = try #require(Int(digits), "no id in response: \(inserted.text)")
        let ends = try connectorEnds("glued")
        #expect(ends.start != newId && ends.end != newId, "the new element (id=\(newId)) must not be glued to the old connector")
    }

    /// 連接線已經指向一個不存在的 id（其他工具留下的懸空綁定）時，配號也要避開它。
    @Test func `A new element never takes an id a connector still points at`() async throws {
        var pres = PptxWriter.createNew()
        pres.slides[0].elements = [
            .shape(Shape(id: 2, name: "Title")),
            .connector(Connector(id: 9, name: "Dangling", endConnection: ConnectionSite(shapeId: 10, index: 0))),
        ]
        server.initializeSession(docId: "dangling", presentation: pres, sourcePath: nil, autosave: false)
        let inserted = try await call("insert_text_shape", [
            "doc_id": .string("dangling"), "slide_index": .int(0), "text": .string("New"),
            "x": .int(0), "y": .int(0), "width": .int(914400), "height": .int(914400),
        ])
        let digits = inserted.text.split(separator: "=").last?.prefix { $0.isNumber } ?? ""
        let newId = try #require(Int(digits), "no id in response: \(inserted.text)")
        #expect(newId == 11, "id 10 is still referenced by the connector's endCxn")
    }
}

import Testing
import Foundation
import MCP
import PPTXSwift
@testable import ChePPTXMCP

/// PsychQuant/che-pptx-mcp#10: `SlideElement` gained two cases in
/// pptx-swift#9 (`.connector` for `p:cxnSp`, `.raw` for anything else the
/// reader does not model, e.g. `mc:AlternateContent`). Before this, every
/// exhaustive `switch` over `SlideElement` in this server failed to compile
/// against pptx-swift 0.6.0 — and, independently of the compiler forcing a
/// fix, `maxElementId(in:)` (che-pptx-mcp#6's id allocator) could not see
/// ids carried only by these two element kinds, meaning a newly inserted
/// element could collide with (and shadow) one already on the slide. This
/// file covers both: the id allocator now looks through `.connector`/`.raw`
/// via `Slide.allElementIds`, and the read tools that list a slide's
/// elements describe them instead of silently omitting them.
struct UnmodeledElementTests {
    let server: PPTXMCPServer

    init() async throws {
        server = await PPTXMCPServer()
    }

    /// A slide holding a title (id 2), a connector (id `connectorId`) and a
    /// raw passthrough element (ids `rawIds`).
    func installSession(_ docId: String, connectorId: Int, rawIds: [Int]) {
        var pres = PptxWriter.createNew()
        pres.slides[0].elements = [
            .shape(Shape(id: 2, name: "Title", size: Size(width: 914400, height: 914400))),
            .connector(Connector(id: connectorId, name: "Connector 1",
                                  startConnection: ConnectionSite(shapeId: 2, index: 0))),
            .raw(RawSlideElement(localName: "AlternateContent",
                                  xml: "<mc:AlternateContent xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\"><mc:Fallback/></mc:AlternateContent>",
                                  elementIds: rawIds)),
        ]
        server.initializeSession(docId: docId, presentation: pres, sourcePath: nil, autosave: false)
    }

    func call(_ tool: String, _ args: [String: Value]) throws -> String {
        try server.executeToolTask(name: tool, args: args)
    }

    // MARK: - Scenario: id allocation avoids ids only a connector or a raw element carries

    @Test func `A new element does not collide with a connector's id`() throws {
        installSession("conn-id", connectorId: 50, rawIds: [7])
        let text = try call("insert_text_shape", [
            "doc_id": .string("conn-id"), "slide_index": .int(0), "text": .string("New"),
            "x": .int(0), "y": .int(0), "width": .int(914400), "height": .int(914400),
        ])
        let digits = text.split(separator: "=").last?.prefix { $0.isNumber } ?? ""
        let newId = try #require(Int(digits), "no id in response: \(text)")
        // The largest id on the slide is the connector's 50, not the title's
        // 2 or the raw element's 7 — the new element must land above it.
        #expect(newId == 51)
    }

    @Test func `A new element does not collide with any id a raw element bundles`() throws {
        // The raw element's largest id (99) exceeds the connector's (12) and
        // the title's (2) — proves allocation looks at every id inside
        // .raw, not just a first/lowest one.
        installSession("raw-id", connectorId: 12, rawIds: [40, 99, 41])
        let text = try call("insert_table", [
            "doc_id": .string("raw-id"), "slide_index": .int(0), "columns": .int(2), "rows": .int(2),
            "x": .int(0), "y": .int(0), "width": .int(1828800), "height": .int(914400),
        ])
        let digits = text.split(separator: "=").last?.prefix { $0.isNumber } ?? ""
        let newId = try #require(Int(digits), "no id in response: \(text)")
        #expect(newId == 100)
    }

    // MARK: - Scenario: get_slide_shapes describes connector/raw instead of omitting them

    @Test func `get_slide_shapes lists the connector and the raw element, not just the shape`() throws {
        installSession("list", connectorId: 50, rawIds: [7])
        let text = try call("get_slide_shapes", ["doc_id": .string("list"), "slide_index": .int(0)])

        #expect(text.contains("Shape id=2"))
        #expect(text.contains("Connector id=50"), "connector must not be silently omitted: \(text)")
        #expect(text.contains("stCxn=(shape:2,idx:0)"), "connector's connection site must be visible: \(text)")
        #expect(text.contains("Raw(AlternateContent)"), "raw element must not be silently omitted: \(text)")
        #expect(text.contains("ids=7"), "raw element's ids must be visible: \(text)")
    }

    // MARK: - Scenario: delete_shape can find and remove a connector or a raw element by id

    @Test func `delete_shape finds and removes a connector by id`() throws {
        installSession("del-conn", connectorId: 50, rawIds: [7])
        _ = try call("delete_shape", ["doc_id": .string("del-conn"), "slide_index": .int(0), "shape_id": .int(50)])
        let slide = try #require(server.openPresentations["del-conn"]).slides[0]
        #expect(slide.elements.count == 2)
        #expect(!slide.elements.contains { if case .connector(let c) = $0 { return c.id == 50 } else { return false } })
    }

    @Test func `delete_shape finds and removes a raw element by any one of its ids`() throws {
        installSession("del-raw", connectorId: 50, rawIds: [40, 99])
        // Delete by the *second* id the raw element bundles, not just the first.
        _ = try call("delete_shape", ["doc_id": .string("del-raw"), "slide_index": .int(0), "shape_id": .int(99)])
        let slide = try #require(server.openPresentations["del-raw"]).slides[0]
        #expect(slide.elements.count == 2)
        #expect(!slide.elements.contains { if case .raw = $0 { return true } else { return false } })
    }

    // MARK: - Scenario: a geometry-writing tool can move a connector and reports its resulting geometry

    /// `set_placeholder_geometry` writes via `Slide.setGeometry` (which
    /// pptx-swift#9 taught to accept `.connector`) and then reads the result
    /// back via `topLevelGeometry` — this exercises the `.connector` case
    /// added to `topLevelGeometry`'s switch in this fix, not just the
    /// compiler-forced case label.
    @Test func `set_placeholder_geometry moves a connector and reports its new position`() throws {
        var pres = PptxWriter.createNew()
        pres.slides[0].elements = [.connector(Connector(id: 50, name: "Connector 1"))]
        server.initializeSession(docId: "geom-conn", presentation: pres, sourcePath: nil, autosave: false)
        let text = try call("set_placeholder_geometry", [
            "doc_id": .string("geom-conn"), "slide_index": .int(0), "shape_id": .int(50),
            "x_cm": .double(1), "y_cm": .double(2), "width_cm": .double(3), "height_cm": .double(4),
        ])
        #expect(text.contains("\"x\":1"))
        #expect(text.contains("\"y\":2"))

        let slide = try #require(server.openPresentations["geom-conn"]).slides[0]
        guard case .connector(let c) = slide.elements[0] else {
            Issue.record("expected the element to still be a connector: \(slide.elements)")
            return
        }
        #expect(c.position.xCm.rounded() == 1)
        #expect(c.position.yCm.rounded() == 2)
    }
}

import Testing
import Foundation
import MCP
import PPTXSwift
@testable import ChePPTXMCP

/// PsychQuant/che-pptx-mcp#6: every tool that adds an element allocates its
/// id above the largest id anywhere in the slide's shape tree — group
/// children included — and reports overflow as an error instead of trapping.
struct ElementIdAllocationTests {
    let server: PPTXMCPServer

    init() async throws {
        server = await PPTXMCPServer()
    }

    /// A slide holding a title (id 2) and a group (id 10) with `children`.
    func installGroupedSession(_ docId: String, children: [SlideElement]) {
        var pres = PptxWriter.createNew()
        pres.slides[0].elements = [
            .shape(Shape(id: 2, name: "Title", size: Size(width: 914400, height: 914400))),
            .group(GroupShape(id: 10, name: "Group", elements: children)),
        ]
        server.initializeSession(docId: docId, presentation: pres, sourcePath: nil, autosave: false)
    }

    /// The two tools named in #6, with arguments that insert one element.
    static let insertingTools: [(tool: String, args: [String: Value])] = [
        ("insert_text_shape", ["slide_index": .int(0), "text": .string("New"),
                               "x": .int(0), "y": .int(0), "width": .int(914400), "height": .int(914400)]),
        ("insert_table", ["slide_index": .int(0), "columns": .int(2), "rows": .int(2),
                          "x": .int(0), "y": .int(0), "width": .int(1828800), "height": .int(914400)]),
    ]

    func insert(_ tool: String, _ args: [String: Value], docId: String) throws -> Int {
        var args = args
        args["doc_id"] = .string(docId)
        let text = try server.executeToolTask(name: tool, args: args)
        // place_picture_at answers with JSON; the older tools with "… id=N…".
        if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            return try #require(object["shape_id"] as? Int, "no shape_id in response: \(text)")
        }
        let digits = text.split(separator: "=").last?.prefix { $0.isNumber } ?? ""
        return try #require(Int(digits), "no id in response: \(text)")
    }

    func slide(_ docId: String) throws -> Slide {
        try #require(server.openPresentations[docId]).slides[0]
    }

    @Test(arguments: insertingTools)
    func `A new element gets an id above the group's children`(tool: String, args: [String: Value]) throws {
        installGroupedSession("grp", children: [.shape(Shape(id: 11, name: "child"))])
        let id = try insert(tool, args, docId: "grp")
        #expect(id == 12)

        // id 11 still names only the group child: the new element did not take it.
        let slide = try slide("grp")
        #expect(slide.locateElement(id: 11) == .groupChild(groupId: 10))
        #expect(slide.locateElement(id: 12) == .topLevel(index: 2))
    }

    @Test(arguments: insertingTools)
    func `Id allocation looks through nested groups`(tool: String, args: [String: Value]) throws {
        installGroupedSession("nested", children: [
            .shape(Shape(id: 11, name: "child")),
            .group(GroupShape(id: 20, name: "Inner", elements: [.shape(Shape(id: 30, name: "grandchild"))])),
        ])
        #expect(try insert(tool, args, docId: "nested") == 31)
    }

    @Test(arguments: insertingTools)
    func `An id at Int.max inside a group is an error and leaves the slide unchanged`(
        tool: String, args: [String: Value]
    ) throws {
        installGroupedSession("maxid", children: [.shape(Shape(id: Int.max, name: "child"))])
        var args = args
        args["doc_id"] = .string("maxid")
        #expect(throws: PPTXError.self) {
            _ = try server.executeToolTask(name: tool, args: args)
        }
        #expect(try slide("maxid").elements.count == 2)
        #expect(server.dirtyState["maxid"] == false)
    }

    // MARK: - Review round 1, HIGH 1: ids stay inside ST_DrawingElementId

    /// Every tool that adds an element, with arguments that insert one.
    static let allInsertingTools: [(tool: String, args: [String: Value])] = insertingTools + [
        ("insert_image", ["slide_index": .int(0), "base64": .string(IntegerParameterTests.pngBase64),
                          "file_name": .string("i.png")]),
        ("place_picture_at", ["slide_index": .int(0), "image_base64": .string(IntegerParameterTests.pngBase64),
                              "x_cm": .double(1), "y_cm": .double(1), "width_cm": .double(4)]),
    ]

    /// `p:cNvPr/@id` is `ST_DrawingElementId`, an `xsd:unsignedInt`.
    static let maxDrawingElementId = Int(UInt32.max)

    @Test(arguments: allInsertingTools)
    func `The last id below the unsignedInt limit is still allocated`(tool: String, args: [String: Value]) throws {
        installGroupedSession("near", children: [.shape(Shape(id: Self.maxDrawingElementId - 1, name: "child"))])
        #expect(try insert(tool, args, docId: "near") == Self.maxDrawingElementId)
    }

    @Test(arguments: allInsertingTools)
    func `An id at the unsignedInt limit anywhere in the tree is an error and leaves the slide unchanged`(
        tool: String, args: [String: Value]
    ) throws {
        installGroupedSession("limit", children: [
            .group(GroupShape(id: 20, name: "Inner", elements: [.shape(Shape(id: Self.maxDrawingElementId, name: "deep"))])),
        ])
        var args = args
        args["doc_id"] = .string("limit")
        let error = #expect(throws: PPTXError.self) {
            _ = try server.executeToolTask(name: tool, args: args)
        }
        #expect(error?.errorDescription?.contains("\(Self.maxDrawingElementId)") == true, "\(String(describing: error))")
        let pres = try #require(server.openPresentations["limit"])
        #expect(pres.slides[0].elements.count == 2)
        #expect(pres.images.isEmpty)
        #expect(server.dirtyState["limit"] == false)
    }

    @Test(arguments: allInsertingTools)
    func `Non-positive existing ids still yield an id of at least 2`(tool: String, args: [String: Value]) throws {
        var pres = PptxWriter.createNew()
        pres.slides[0].elements = [.shape(Shape(id: -5, name: "odd")), .shape(Shape(id: 0, name: "zero"))]
        server.initializeSession(docId: "low", presentation: pres, sourcePath: nil, autosave: false)
        #expect(try insert(tool, args, docId: "low") == 2)
    }

    @Test(arguments: insertingTools)
    func `Without groups the next id is still one above the largest`(tool: String, args: [String: Value]) throws {
        installGroupedSession("flat", children: [])
        #expect(try insert(tool, args, docId: "flat") == 11)
        #expect(try insert(tool, args, docId: "flat") == 12)
    }
}

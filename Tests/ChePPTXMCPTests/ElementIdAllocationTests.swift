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

    @Test(arguments: insertingTools)
    func `Without groups the next id is still one above the largest`(tool: String, args: [String: Value]) throws {
        installGroupedSession("flat", children: [])
        #expect(try insert(tool, args, docId: "flat") == 11)
        #expect(try insert(tool, args, docId: "flat") == 12)
    }
}

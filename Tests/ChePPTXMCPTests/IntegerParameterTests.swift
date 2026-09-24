import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MCP
import PPTXSwift
@testable import ChePPTXMCP

/// PsychQuant/che-pptx-mcp#5: every integer tool parameter is validated —
/// JSON type, finiteness, `Int` range, then the parameter's own range —
/// before it is used, and an invalid value comes back as an `isError`
/// result instead of trapping the server. One rule for every tool: the
/// strict typing the v0.2.0 geometry tools introduced.
struct IntegerParameterTests {
    let server: PPTXMCPServer
    static let docId = "ints"

    /// Two slides; slide 0 holds a text shape (id 2), a 2 × 2 table (id 3)
    /// and a picture (id 4).
    init() async throws {
        server = await PPTXMCPServer()
        let doc = Value.string(Self.docId)
        _ = try server.executeToolTask(name: "create_presentation", args: ["doc_id": doc])
        _ = try server.executeToolTask(name: "add_slide", args: ["doc_id": doc])
        _ = try server.executeToolTask(name: "insert_text_shape", args: [
            "doc_id": doc, "slide_index": .int(0), "text": .string("Title"),
        ])
        _ = try server.executeToolTask(name: "insert_table", args: [
            "doc_id": doc, "slide_index": .int(0), "columns": .int(2), "rows": .int(2),
        ])
        _ = try server.executeToolTask(name: "insert_image", args: [
            "doc_id": doc, "slide_index": .int(0),
            "base64": .string(try Self.png().base64EncodedString()), "file_name": .string("p.png"),
        ])
    }

    // MARK: - A valid call for every tool that takes an integer

    static let pngBase64: String = (try? png().base64EncodedString()) ?? ""

    /// Arguments (besides `doc_id`) that succeed on the fixture session.
    static let validCalls: [String: [String: Value]] = [
        "get_slide_text": ["slide_index": .int(0)],
        "get_slide_shapes": ["slide_index": .int(0)],
        "get_shape_text": ["slide_index": .int(0), "shape_id": .int(2)],
        "get_slide_notes": ["slide_index": .int(0)],
        "insert_image": ["slide_index": .int(0), "base64": .string(pngBase64), "file_name": .string("q.png"),
                         "x": .int(0), "y": .int(0), "width": .int(914_400), "height": .int(914_400)],
        "delete_image": ["slide_index": .int(0), "shape_id": .int(4)],
        "get_tables": ["slide_index": .int(0)],
        "get_table_data": ["slide_index": .int(0), "shape_id": .int(3)],
        "insert_table": ["slide_index": .int(0), "columns": .int(2), "rows": .int(2),
                         "x": .int(0), "y": .int(0), "width": .int(1_828_800), "height": .int(914_400)],
        "update_cell": ["slide_index": .int(0), "shape_id": .int(3), "row": .int(0), "col": .int(1),
                        "text": .string("cell")],
        "add_slide": ["at_index": .int(1)],
        "delete_slide": ["slide_index": .int(1)],
        "reorder_slides": ["from_index": .int(0), "to_index": .int(1)],
        "duplicate_slide": ["slide_index": .int(0)],
        "insert_text_shape": ["slide_index": .int(0), "text": .string("New"),
                              "x": .int(0), "y": .int(0), "width": .int(914_400), "height": .int(914_400)],
        "update_shape_text": ["slide_index": .int(0), "shape_id": .int(2), "text": .string("New")],
        "delete_shape": ["slide_index": .int(0), "shape_id": .int(2)],
        "set_shape_position": ["slide_index": .int(0), "shape_id": .int(2), "x": .int(0), "y": .int(0)],
        "set_shape_size": ["slide_index": .int(0), "shape_id": .int(2),
                           "width": .int(914_400), "height": .int(914_400)],
        "set_shape_fill": ["slide_index": .int(0), "shape_id": .int(2), "color": .string("FF0000")],
        "set_placeholder_geometry": ["slide_index": .int(0), "shape_id": .int(2), "x_cm": .double(1),
                                     "y_cm": .double(1), "width_cm": .double(5), "height_cm": .double(2)],
        "place_picture_at": ["slide_index": .int(0), "image_base64": .string(pngBase64),
                             "x_cm": .double(1), "y_cm": .double(1), "width_cm": .double(5)],
        "fit_picture_to_native_aspect": ["slide_index": .int(0), "shape_id": .int(4), "anchor": .string("width")],
        "add_notes": ["slide_index": .int(0), "text": .string("notes")],
        "set_transition": ["slide_index": .int(0), "type": .string("fade")],
    ]

    /// Every `(tool, integer parameter)` pair in `validCalls`.
    static let integerParameters: [(tool: String, key: String)] = validCalls
        .flatMap { tool, args in args.compactMap { key, value in
            if case .int = value { return (tool, key) } else { return nil }
        } }
        .sorted { ($0.tool, $0.key) < ($1.tool, $1.key) }

    static let slideIndexTools: [String] = validCalls.keys.filter { validCalls[$0]?["slide_index"] != nil }.sorted()

    // MARK: - Helpers

    func call(_ tool: String, _ args: [String: Value]) async throws -> (isError: Bool, text: String) {
        var args = args
        args["doc_id"] = .string(Self.docId)
        let result = try await server.handleToolCall(CallTool.Parameters(name: tool, arguments: args))
        let text = result.content.compactMap { content -> String? in
            if case .text(let text, _, _) = content { return text } else { return nil }
        }.joined()
        return (result.isError == true, text)
    }

    /// The whole session: model tree, media bytes, dirty flag.
    func snapshot() throws -> String {
        let pres = try #require(server.openPresentations[Self.docId])
        var out = ""
        dump(pres, to: &out)
        for image in pres.images { out += "\nmedia \(image.fileName) \(image.data.base64EncodedString())" }
        return out + "\ndirty=\(String(describing: server.dirtyState[Self.docId]))"
    }

    static func png() throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return output as Data
    }

    // MARK: - The table covers the schema

    @Test func `Every integer parameter in the tool schemas has a valid call to test against`() throws {
        var schemaPairs: [String] = []
        for tool in server.allTools {
            guard case .object(let schema) = tool.inputSchema,
                  case .object(let properties)? = schema["properties"] else { continue }
            for (key, property) in properties {
                if case .object(let p) = property, p["type"] == .string("integer") {
                    schemaPairs.append("\(tool.name).\(key)")
                }
            }
        }
        let tablePairs = Self.integerParameters.map { "\($0.tool).\($0.key)" }
        #expect(schemaPairs.sorted() == tablePairs.sorted())
    }

    @Test(arguments: validCalls.keys.sorted())
    func `The valid call for each tool succeeds`(tool: String) async throws {
        let result = try await call(tool, try #require(Self.validCalls[tool]))
        #expect(!result.isError, "\(tool): \(result.text)")
    }

    // MARK: - Scenario: non-finite, fractional and out-of-Int values

    static let invalidNumbers: [Double] = [
        .nan, .infinity, -.infinity,
        1e300, -1e300,
        9_223_372_036_854_775_808,   // 2^63: one past Int.max
        -9_223_372_036_854_777_856,  // the first double below Int.min
        0.5, -0.25,
    ]

    @Test(arguments: integerParameters)
    func `Every integer parameter rejects non-finite, fractional and out-of-Int numbers as an isError result`(
        tool: String, key: String
    ) async throws {
        let before = try snapshot()
        for bad in Self.invalidNumbers {
            var args = try #require(Self.validCalls[tool])
            args[key] = .double(bad)
            let result = try await call(tool, args)
            #expect(result.isError, "\(tool).\(key)=\(bad): \(result.text)")
            #expect(result.text.contains(key), "\(tool).\(key)=\(bad) should name the parameter: \(result.text)")
        }
        #expect(try snapshot() == before, "\(tool).\(key): a rejected call changed the session")
    }

    @Test(arguments: integerParameters)
    func `Integer parameters take only JSON numbers, as the geometry tools do`(tool: String, key: String) async throws {
        let before = try snapshot()
        for bad: Value in [.string("0"), .bool(true), .array([.int(0)])] {
            var args = try #require(Self.validCalls[tool])
            args[key] = bad
            let result = try await call(tool, args)
            #expect(result.isError, "\(tool).\(key)=\(bad): \(result.text)")
            #expect(result.text.contains(key), "\(tool).\(key)=\(bad): \(result.text)")
        }
        #expect(try snapshot() == before)
    }

    @Test(arguments: integerParameters)
    func `An integral double is accepted for an integer parameter`(tool: String, key: String) async throws {
        var args = try #require(Self.validCalls[tool])
        guard case .int(let value)? = args[key] else { return }
        args[key] = .double(Double(value))
        let result = try await call(tool, args)
        #expect(!result.isError, "\(tool).\(key)=\(Double(value)): \(result.text)")
    }

    // MARK: - Scenario: values outside the parameter's own range

    @Test(arguments: slideIndexTools)
    func `A slide index outside the deck is an isError result for every tool`(tool: String) async throws {
        let before = try snapshot()
        for bad in [-1, 2, 99, Int.max, Int.min] {
            var args = try #require(Self.validCalls[tool])
            args["slide_index"] = .int(bad)
            let result = try await call(tool, args)
            #expect(result.isError, "\(tool) slide_index=\(bad): \(result.text)")
        }
        #expect(try snapshot() == before)
    }

    @Test func `insert_table needs between 1 and 1000 columns and rows`() async throws {
        let before = try snapshot()
        for key in ["columns", "rows"] {
            for bad in [0, -1, 1001, Int.max, Int.min] {
                var args = try #require(Self.validCalls["insert_table"])
                args[key] = .int(bad)
                let result = try await call("insert_table", args)
                #expect(result.isError, "\(key)=\(bad): \(result.text)")
                #expect(result.text.contains(key), "\(result.text)")
            }
        }
        #expect(try snapshot() == before)

        var edge = try #require(Self.validCalls["insert_table"])
        edge["columns"] = .int(1000)
        edge["rows"] = .int(1)
        let result = try await call("insert_table", edge)
        #expect(!result.isError, "\(result.text)")
    }

    @Test func `add_slide takes an insertion point from 0 through the slide count`() async throws {
        let before = try snapshot()
        for bad in [-1, 3, Int.max, Int.min] {
            let result = try await call("add_slide", ["at_index": .int(bad)])
            #expect(result.isError, "at_index=\(bad): \(result.text)")
        }
        #expect(try snapshot() == before)
        for good in [0, 2] {
            let result = try await call("add_slide", ["at_index": .int(good)])
            #expect(!result.isError, "at_index=\(good): \(result.text)")
        }
    }

    static let emuParameters: [(tool: String, key: String, isExtent: Bool)] = [
        ("insert_image", "x", false), ("insert_image", "y", false),
        ("insert_image", "width", true), ("insert_image", "height", true),
        ("insert_table", "x", false), ("insert_table", "y", false),
        ("insert_table", "width", true), ("insert_table", "height", true),
        ("insert_text_shape", "x", false), ("insert_text_shape", "y", false),
        ("insert_text_shape", "width", true), ("insert_text_shape", "height", true),
        ("set_shape_position", "x", false), ("set_shape_position", "y", false),
        ("set_shape_size", "width", true), ("set_shape_size", "height", true),
    ]

    @Test(arguments: emuParameters)
    func `EMU values outside the OOXML coordinate range are an isError result`(
        tool: String, key: String, isExtent: Bool
    ) async throws {
        let before = try snapshot()
        let lower = isExtent ? 0 : PPTXMetric.minCoordinateEmu
        for bad in [lower - 1, PPTXMetric.maxCoordinateEmu + 1, Int.max, Int.min] {
            var args = try #require(Self.validCalls[tool])
            args[key] = .int(bad)
            let result = try await call(tool, args)
            #expect(result.isError, "\(tool).\(key)=\(bad): \(result.text)")
            #expect(result.text.contains(key), "\(result.text)")
        }
        #expect(try snapshot() == before)

        for edge in [lower, PPTXMetric.maxCoordinateEmu] {
            var args = try #require(Self.validCalls[tool])
            args[key] = .int(edge)
            let result = try await call(tool, args)
            #expect(!result.isError, "\(tool).\(key)=\(edge): \(result.text)")
        }
    }

    // MARK: - Scenario: the values arrive as JSON

    static let oversizedJSONNumbers = ["1e300", "-1e300", "9223372036854775808", "-9223372036854775809", "0.5"]

    @Test(arguments: oversizedJSONNumbers)
    func `A JSON number that does not fit Int is an isError result, not a crash`(number: String) async throws {
        let json = #"{"name":"get_slide_text","arguments":{"doc_id":"\#(Self.docId)","slide_index":\#(number)}}"#
        let params = try JSONDecoder().decode(CallTool.Parameters.self, from: Data(json.utf8))
        let result = try await server.handleToolCall(params)
        #expect(result.isError == true)
    }
}

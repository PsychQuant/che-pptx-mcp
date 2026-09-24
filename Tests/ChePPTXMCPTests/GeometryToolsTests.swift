import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MCP
import PPTXSwift
@testable import ChePPTXMCP

/// Tasks 2.2–2.4 of PsychQuant/macdoc#90 (Spectra change `pptx-geometry-tools`).
///
/// Covers spec `pptx-mcp-server` Requirement "Centimeter-denominated geometry
/// tools": every Scenario is exercised through the same dispatch the MCP
/// `tools/call` handler uses (`executeToolTask`).
final class GeometryToolsTests: XCTestCase {

    private var server: PPTXMCPServer!
    private let docId = "geo"

    override func setUp() async throws {
        server = await PPTXMCPServer()
        _ = try call("create_presentation", ["doc_id": .string(docId)])
    }

    // MARK: - Tool registry

    func testToolListExposesThe3GeometryToolsFor40Total() {
        let names = server.allTools.map(\.name)
        XCTAssertEqual(names.count, 40)
        XCTAssertEqual(Set(names).count, 40, "tool names must be unique")
        for name in ["set_placeholder_geometry", "place_picture_at", "fit_picture_to_native_aspect"] {
            XCTAssertTrue(names.contains(name), "missing \(name)")
        }
    }

    func testGeometryToolSchemasAreCentimeterDenominated() throws {
        let tools = Dictionary(uniqueKeysWithValues: server.allTools.map { ($0.name, $0) })
        let setGeo = try XCTUnwrap(tools["set_placeholder_geometry"])
        XCTAssertEqual(requiredParams(setGeo),
                       ["doc_id", "height_cm", "shape_id", "slide_index", "width_cm", "x_cm", "y_cm"])
        XCTAssertTrue(setGeo.description?.contains("any shape (placeholder or otherwise)") == true)

        let place = try XCTUnwrap(tools["place_picture_at"])
        XCTAssertEqual(requiredParams(place), ["doc_id", "slide_index", "width_cm", "x_cm", "y_cm"])
        XCTAssertEqual(Set(propertyNames(place)),
                       ["doc_id", "slide_index", "image_path", "image_base64",
                        "x_cm", "y_cm", "width_cm", "height_cm"])

        let fit = try XCTUnwrap(tools["fit_picture_to_native_aspect"])
        XCTAssertEqual(requiredParams(fit), ["anchor", "doc_id", "shape_id", "slide_index"])
    }

    // MARK: - Scenario: set_placeholder_geometry mutates any shape's geometry

    func testSetPlaceholderGeometryWritesEMUAndReportsCmAndEMU() throws {
        let shapeId = try insertTextShape()
        let response = try json(call("set_placeholder_geometry", geometryArgs(shapeId, 2.0, 3.0, 10.0, 7.5)))

        let stored = try storedShape(shapeId)
        XCTAssertEqual(stored.position.x, 720000)
        XCTAssertEqual(stored.position.y, 1080000)
        XCTAssertEqual(stored.size.width, 3600000)
        XCTAssertEqual(stored.size.height, 2700000)

        XCTAssertEqual(response["shape_id"] as? Int, shapeId)
        try assertGeometry(response, cm: ("2.00", "3.00", "10.00", "7.50"),
                           emu: (720000, 1080000, 3600000, 2700000))
        XCTAssertNil(response["warnings"], "in-bounds placement must not carry a warnings field")
    }

    func testSetPlaceholderGeometryAlsoMovesPictures() throws {
        let placed = try json(call("place_picture_at", pictureArgs(base64: fourByThreePNG(), 2.0, 3.0, 10.0)))
        let pictureId = try XCTUnwrap(placed["shape_id"] as? Int)

        let response = try json(call("set_placeholder_geometry", geometryArgs(pictureId, 5.0, 5.0, 10.0, 7.5)))
        let stored = try storedPicture(pictureId)
        XCTAssertEqual(stored.position.x, 1800000)
        XCTAssertEqual(stored.position.y, 1800000)
        XCTAssertNil(response["warnings"])
    }

    // MARK: - Scenario: Off-slide placement warns but succeeds

    func testOffSlidePlacementIsAppliedWithAWarningNamingTheBound() throws {
        let shapeId = try insertTextShape()
        let response = try json(call("set_placeholder_geometry", geometryArgs(shapeId, 30.0, 3.0, 10.0, 7.5)))

        XCTAssertEqual(try storedShape(shapeId).position.x, 10800000, "geometry must still be applied")
        let warnings = try XCTUnwrap(response["warnings"] as? [[String: Any]])
        XCTAssertEqual(warnings.compactMap { $0["bound"] as? String }, ["right"])
        let message = try XCTUnwrap(warnings.first?["message"] as? String)
        XCTAssertTrue(message.contains("25.40"), "warning should cite the slide width: \(message)")
    }

    func testEachExceededBoundIsNamed() throws {
        let shapeId = try insertTextShape()
        let response = try json(call("set_placeholder_geometry", geometryArgs(shapeId, -1.0, -2.0, 30.0, 25.0)))
        let bounds = try XCTUnwrap(response["warnings"] as? [[String: Any]]).compactMap { $0["bound"] as? String }
        XCTAssertEqual(bounds, ["left", "top", "right", "bottom"])
    }

    // MARK: - Scenario: Non-positive dimensions are a hard error

    func testNonPositiveDimensionsAreRejectedWithoutMutation() throws {
        let shapeId = try insertTextShape()
        _ = try call("set_placeholder_geometry", geometryArgs(shapeId, 2.0, 3.0, 10.0, 7.5))

        XCTAssertThrowsError(try call("set_placeholder_geometry", geometryArgs(shapeId, 1.0, 1.0, 0.0, 7.5))) { error in
            XCTAssertTrue(error.localizedDescription.contains("widthCm"), "\(error.localizedDescription)")
        }
        XCTAssertThrowsError(try call("set_placeholder_geometry", geometryArgs(shapeId, 1.0, 1.0, 10.0, -1.0))) { error in
            XCTAssertTrue(error.localizedDescription.contains("heightCm"), "\(error.localizedDescription)")
        }

        let stored = try storedShape(shapeId)
        XCTAssertEqual(stored.position.x, 720000)
        XCTAssertEqual(stored.size.width, 3600000)
        XCTAssertEqual(stored.size.height, 2700000)
    }

    func testPlacePictureWithNonPositiveDimensionsInsertsNothing() throws {
        let before = try presentation()
        var zeroWidth = pictureArgs(base64: try fourByThreePNG(), 2.0, 3.0, 0.0)
        XCTAssertThrowsError(try call("place_picture_at", zeroWidth))
        zeroWidth["width_cm"] = .double(10.0)
        zeroWidth["height_cm"] = .double(-2.0)
        XCTAssertThrowsError(try call("place_picture_at", zeroWidth))

        let after = try presentation()
        XCTAssertEqual(after.slides[0].elements.count, before.slides[0].elements.count)
        XCTAssertEqual(after.images.count, before.images.count)
    }

    func testMissingOrNonNumericParametersAreErrors() throws {
        let shapeId = try insertTextShape()
        var args = geometryArgs(shapeId, 2.0, 3.0, 10.0, 7.5)
        args.removeValue(forKey: "height_cm")
        XCTAssertThrowsError(try call("set_placeholder_geometry", args)) { error in
            XCTAssertTrue(error.localizedDescription.contains("height_cm"), "\(error.localizedDescription)")
        }
        args["height_cm"] = .string("tall")
        XCTAssertThrowsError(try call("set_placeholder_geometry", args)) { error in
            XCTAssertTrue(error.localizedDescription.contains("height_cm"), "\(error.localizedDescription)")
        }
        XCTAssertThrowsError(try call("set_placeholder_geometry", geometryArgs(9999, 2.0, 3.0, 10.0, 7.5))) { error in
            XCTAssertTrue(error.localizedDescription.contains("9999"), "\(error.localizedDescription)")
        }
    }

    // MARK: - Group children are rejected (consistent with task 1.4)

    func testGroupChildrenAreRejectedByGeometryTools() throws {
        let child = PPTXSwift.Picture(id: 11, name: "child", size: Size(width: 3600000, height: 1800000),
                            imageRelationshipId: "rId2", mediaFileName: "child.png")
        var pres = try presentation()
        pres.slides[0].elements.append(.group(GroupShape(id: 10, name: "Group", elements: [.picture(child)])))
        pres.images.append(MediaFile(id: "child.png", fileName: "child.png", data: try fourByThreePNGData()))
        server.initializeSession(docId: "grouped", presentation: pres, sourcePath: nil, autosave: false)

        var args = geometryArgs(11, 2.0, 3.0, 10.0, 7.5)
        args["doc_id"] = .string("grouped")
        XCTAssertThrowsError(try call("set_placeholder_geometry", args)) { error in
            XCTAssertTrue(error.localizedDescription.contains("群組"), "\(error.localizedDescription)")
        }
        XCTAssertThrowsError(try call("fit_picture_to_native_aspect", [
            "doc_id": .string("grouped"), "slide_index": .int(0),
            "shape_id": .int(11), "anchor": .string("width"),
        ])) { error in
            XCTAssertTrue(error.localizedDescription.contains("群組"), "\(error.localizedDescription)")
        }
    }

    // MARK: - Scenario: place_picture_at inserts and positions in one call

    func testPlacePictureAtDerivesHeightFromNativeAspect() throws {
        let response = try json(call("place_picture_at", pictureArgs(base64: fourByThreePNG(), 2.0, 3.0, 10.0)))

        let pictureId = try XCTUnwrap(response["shape_id"] as? Int, "response must include the new shape_id")
        let stored = try storedPicture(pictureId)
        XCTAssertEqual(stored.position.x, 720000)
        XCTAssertEqual(stored.position.y, 1080000)
        XCTAssertEqual(stored.size.width, 3600000)
        XCTAssertEqual(stored.size.height, 2700000)
        try assertGeometry(response, cm: ("2.00", "3.00", "10.00", "7.50"),
                           emu: (720000, 1080000, 3600000, 2700000))
        XCTAssertEqual(response["height_source"] as? String, "native_aspect")
        XCTAssertNil(response["warnings"])

        let pres = try presentation()
        let media = try XCTUnwrap(pres.mediaFile(for: stored), "picture must be linked to its media")
        XCTAssertEqual(try NativeAspect.pixelDimensions(of: media.data).width, 1600)
    }

    func testPlacePictureAtReadsImagePathAndKeepsMediaNamesUnique() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("geo-\(UUID().uuidString)").appendingPathExtension("png")
        try fourByThreePNGData().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        var args = pictureArgs(base64: nil, 2.0, 3.0, 10.0)
        args["image_path"] = .string(url.path)
        let first = try json(call("place_picture_at", args))
        let second = try json(call("place_picture_at", args))

        XCTAssertEqual(first["media_file"] as? String, url.lastPathComponent)
        XCTAssertNotEqual(first["media_file"] as? String, second["media_file"] as? String)
        XCTAssertEqual(try storedPicture(XCTUnwrap(second["shape_id"] as? Int)).size.height, 2700000)
    }

    func testPlacePictureAtWithExplicitHeightSkipsDecoding() throws {
        let emfLike = Data([0x01, 0, 0, 0] + [UInt8](repeating: 0, count: 36) + Array(" EMF".utf8))
        var args = pictureArgs(base64: emfLike.base64EncodedString(), 2.0, 3.0, 10.0)
        args["height_cm"] = .double(5.0)
        let response = try json(call("place_picture_at", args))
        XCTAssertEqual(response["height_source"] as? String, "explicit")
        XCTAssertEqual(try storedPicture(XCTUnwrap(response["shape_id"] as? Int)).size.height, 1800000)
    }

    func testPlacePictureAtUndecodableWithoutHeightAsksForHeightAndInsertsNothing() throws {
        let before = try presentation()
        let noise = Data((0..<256).map { UInt8(($0 * 37 + 11) % 256) })
        XCTAssertThrowsError(try call("place_picture_at", pictureArgs(base64: noise.base64EncodedString(), 2.0, 3.0, 10.0))) { error in
            XCTAssertTrue(error.localizedDescription.contains("height_cm"), "\(error.localizedDescription)")
        }
        let after = try presentation()
        XCTAssertEqual(after.slides[0].elements.count, before.slides[0].elements.count)
        XCTAssertEqual(after.images.count, before.images.count)
    }

    func testPlacePictureAtRequiresExactlyOneImageSource() throws {
        XCTAssertThrowsError(try call("place_picture_at", pictureArgs(base64: nil, 2.0, 3.0, 10.0))) { error in
            XCTAssertTrue(error.localizedDescription.contains("image_path"), "\(error.localizedDescription)")
        }
        var both = pictureArgs(base64: try fourByThreePNG(), 2.0, 3.0, 10.0)
        both["image_path"] = .string("/tmp/whatever.png")
        XCTAssertThrowsError(try call("place_picture_at", both)) { error in
            XCTAssertTrue(error.localizedDescription.contains("擇一"), "\(error.localizedDescription)")
        }
    }

    func testGetSlideShapesReportsPlacedPictureInCm() throws {
        _ = try call("place_picture_at", pictureArgs(base64: fourByThreePNG(), 2.0, 3.0, 10.0))
        let listing = try call("get_slide_shapes", ["doc_id": .string(docId), "slide_index": .int(0)])
        let line = try XCTUnwrap(listing.split(separator: "\n").first { $0.hasPrefix("Picture") })
        XCTAssertTrue(line.contains("pos=(720000,1080000)"), String(line))
        XCTAssertTrue(line.contains("size=(3600000×2700000)"), String(line))
        XCTAssertTrue(line.contains("pos_cm=(2.00,3.00) size_cm=(10.00×7.50)"), String(line))
    }

    // MARK: - Scenario: fit_picture_to_native_aspect re-derives the non-anchored dimension

    func testFitRederivesHeightWhenAnchoredOnWidth() throws {
        let pictureId = try placeDistortedPicture()
        let response = try json(call("fit_picture_to_native_aspect", fitArgs(pictureId, "width")))

        let stored = try storedPicture(pictureId)
        XCTAssertEqual(stored.size.width, 3600000)
        XCTAssertEqual(stored.size.height, 2700000)
        XCTAssertEqual(stored.position.x, 720000, "fit must not move the picture")
        try assertGeometry(response, cm: ("2.00", "3.00", "10.00", "7.50"),
                           emu: (720000, 1080000, 3600000, 2700000))
        let pixels = try XCTUnwrap(response["native_pixels"] as? [String: Any])
        XCTAssertEqual(pixels["width"] as? Int, 1600)
        XCTAssertEqual(pixels["height"] as? Int, 1200)
    }

    func testFitRederivesWidthWhenAnchoredOnHeight() throws {
        let pictureId = try placeDistortedPicture()
        _ = try call("fit_picture_to_native_aspect", fitArgs(pictureId, "height"))
        let stored = try storedPicture(pictureId)
        XCTAssertEqual(stored.size.width, 2400000)
        XCTAssertEqual(stored.size.height, 1800000)
    }

    func testFitWorksOnPicturesInsertedByInsertImage() throws {
        let inserted = try call("insert_image", [
            "doc_id": .string(docId), "slide_index": .int(0),
            "base64": .string(fourByThreePNG()), "file_name": .string("legacy.png"),
            "x": .int(0), "y": .int(0), "width": .int(3600000), "height": .int(1800000),
        ])
        XCTAssertEqual(inserted, "已插入圖片: legacy.png (id=2)", "insert_image response must be unchanged")
        _ = try call("fit_picture_to_native_aspect", fitArgs(2, "width"))
        XCTAssertEqual(try storedPicture(2).size.height, 2700000)
    }

    // MARK: - Scenario: fit on a non-picture shape is an error

    func testFitOnANonPictureShapeIsAnError() throws {
        let shapeId = try insertTextShape()
        XCTAssertThrowsError(try call("fit_picture_to_native_aspect", fitArgs(shapeId, "width"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("不是圖片"), "\(error.localizedDescription)")
        }
    }

    func testFitRejectsUnknownAnchorAndUndecodableMedia() throws {
        let pictureId = try placeDistortedPicture()
        XCTAssertThrowsError(try call("fit_picture_to_native_aspect", fitArgs(pictureId, "diagonal"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("anchor"), "\(error.localizedDescription)")
        }

        let emfLike = Data([0x01, 0, 0, 0] + [UInt8](repeating: 0, count: 36) + Array(" EMF".utf8))
        var args = pictureArgs(base64: emfLike.base64EncodedString(), 2.0, 3.0, 10.0)
        args["height_cm"] = .double(5.0)
        let emfId = try XCTUnwrap(json(call("place_picture_at", args))["shape_id"] as? Int)
        XCTAssertThrowsError(try call("fit_picture_to_native_aspect", fitArgs(emfId, "width"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("EMF"), "\(error.localizedDescription)")
        }
        XCTAssertEqual(try storedPicture(emfId).size.height, 1800000, "failed fit must not mutate")
    }

    // MARK: - Review HIGH 2: validate everything before mutating

    /// A session holding one 4:3 picture whose existing geometry is extreme.
    private func installExtremePicture(docId: String, position: Position, size: Size) throws {
        var pres = PptxWriter.createNew()
        let picture = PPTXSwift.Picture(id: 2, name: "extreme.png", position: position, size: size,
                                        imageRelationshipId: "rId2", mediaFileName: "extreme.png")
        pres.slides[0].elements = [.picture(picture)]
        pres.images = [MediaFile(id: "extreme.png", fileName: "extreme.png", data: try fourByThreePNGData())]
        server.initializeSession(docId: docId, presentation: pres, sourcePath: nil, autosave: false)
    }

    static let extremeGeometries: [(label: String, position: Position, size: Size)] = [
        ("x near Int.max", Position(x: Int.max - 1, y: 0), Size(width: 3600000, height: 1800000)),
        ("y near Int.max", Position(x: 0, y: Int.max - 1), Size(width: 3600000, height: 1800000)),
        ("x near Int.min", Position(x: Int.min + 1, y: 0), Size(width: 3600000, height: 1800000)),
        ("x one beyond ST_Coordinate", Position(x: PPTXMetric.maxCoordinateEmu + 1, y: 0), Size(width: 3600000, height: 1800000)),
        ("width near Int.max", Position(x: 0, y: 0), Size(width: Int.max - 1, height: 1800000)),
        ("height near Int.max, anchored on height", Position(x: 0, y: 0), Size(width: 3600000, height: Int.max - 1)),
    ]

    func testFitOnExtremeExistingGeometryFailsWithoutTouchingTheDocument() throws {
        for (index, c) in Self.extremeGeometries.enumerated() {
            let id = "extreme-\(index)"
            try installExtremePicture(docId: id, position: c.position, size: c.size)
            let before = try snapshot(id)
            for anchor in ["width", "height"] {
                var args = fitArgs(2, anchor)
                args["doc_id"] = .string(id)
                XCTAssertThrowsError(try call("fit_picture_to_native_aspect", args), "\(c.label) / \(anchor)")
                XCTAssertEqual(try snapshot(id), before, "\(c.label) / \(anchor): document changed")
                XCTAssertEqual(server.dirtyState[id], false, "\(c.label) / \(anchor): marked dirty")
            }
        }
    }

    func testFitAtTheCoordinateLimitSucceedsWithAWarningInsteadOfTrapping() throws {
        let edge = Position(x: PPTXMetric.maxCoordinateEmu - 3600000, y: 0)
        try installExtremePicture(docId: "edge", position: edge, size: Size(width: 3600000, height: 1800000))
        var args = fitArgs(2, "width")
        args["doc_id"] = .string("edge")
        let response = try json(call("fit_picture_to_native_aspect", args))
        let bounds = try XCTUnwrap(response["warnings"] as? [[String: Any]]).compactMap { $0["bound"] as? String }
        XCTAssertEqual(bounds, ["right"])
        XCTAssertEqual(server.dirtyState["edge"], true)
    }

    func testFitAfterInsertImageWithExtremeOffsetDoesNotTrap() throws {
        // Since #5, insert_image itself rejects an offset outside ST_Coordinate,
        // so an extreme picture can no longer be created this way; fit on one
        // that already exists (e.g. read from a file) is covered by
        // testFitOnExtremeExistingGeometryFailsWithoutTouchingTheDocument.
        let before = try snapshot()
        XCTAssertThrowsError(try call("insert_image", [
            "doc_id": .string(docId), "slide_index": .int(0),
            "base64": .string(fourByThreePNG()), "file_name": .string("far.png"),
            "x": .int(Int.max), "y": .int(0), "width": .int(3600000), "height": .int(1800000),
        ])) { error in
            XCTAssertTrue(error.localizedDescription.contains("x"), "\(error.localizedDescription)")
        }
        XCTAssertEqual(try snapshot(), before)
        XCTAssertThrowsError(try call("fit_picture_to_native_aspect", fitArgs(2, "width")))
        XCTAssertEqual(try snapshot(), before)
    }

    // MARK: - Review round 2, MEDIUM 2: new ids never collide with group children

    private func installGroupedSession(docId: String, groupChildren: [SlideElement]) {
        var pres = PptxWriter.createNew()
        pres.slides[0].elements = [
            .shape(Shape(id: 2, name: "Title", size: Size(width: 914400, height: 914400))),
            .group(GroupShape(id: 10, name: "Group", elements: groupChildren)),
        ]
        server.initializeSession(docId: docId, presentation: pres, sourcePath: nil, autosave: false)
    }

    func testPlacePictureAllocatesAnIdAboveGroupChildren() throws {
        installGroupedSession(docId: "grp", groupChildren: [
            .picture(PPTXSwift.Picture(id: 11, name: "child", size: Size(width: 3600000, height: 1800000))),
        ])
        var args = pictureArgs(base64: try fourByThreePNG(), 2.0, 3.0, 10.0)
        args["doc_id"] = .string("grp")
        let placed = try json(call("place_picture_at", args))
        XCTAssertEqual(placed["shape_id"] as? Int, 12)

        // id 11 still names the group child, so it keeps taking the rejection path…
        let slide = try XCTUnwrap(server.openPresentations["grp"]).slides[0]
        XCTAssertEqual(slide.locateElement(id: 11), .groupChild(groupId: 10))
        var moveChild = geometryArgs(11, 5.0, 5.0, 10.0, 7.5)
        moveChild["doc_id"] = .string("grp")
        XCTAssertThrowsError(try call("set_placeholder_geometry", moveChild)) { error in
            XCTAssertTrue(error.localizedDescription.contains("群組"), "\(error.localizedDescription)")
        }
        // …and the new picture is addressable under its own id.
        var moveNew = geometryArgs(12, 5.0, 5.0, 10.0, 7.5)
        moveNew["doc_id"] = .string("grp")
        XCTAssertNoThrow(try call("set_placeholder_geometry", moveNew))
    }

    func testIdAllocationLooksThroughNestedGroups() throws {
        installGroupedSession(docId: "nested", groupChildren: [
            .shape(Shape(id: 11, name: "child")),
            .group(GroupShape(id: 20, name: "Inner", elements: [.shape(Shape(id: 30, name: "grandchild"))])),
        ])
        let inserted = try call("insert_image", [
            "doc_id": .string("nested"), "slide_index": .int(0),
            "base64": .string(fourByThreePNG()), "file_name": .string("n.png"),
            "x": .int(0), "y": .int(0), "width": .int(3600000), "height": .int(2700000),
        ])
        XCTAssertEqual(inserted, "已插入圖片: n.png (id=31)")
    }

    func testIdAllocationOverflowInsideAGroupIsAnErrorNotATrap() throws {
        installGroupedSession(docId: "maxid", groupChildren: [.shape(Shape(id: Int.max, name: "child"))])
        let before = try snapshot("maxid")
        var args = pictureArgs(base64: try fourByThreePNG(), 2.0, 3.0, 10.0)
        args["doc_id"] = .string("maxid")
        XCTAssertThrowsError(try call("place_picture_at", args))
        XCTAssertEqual(try snapshot("maxid"), before)
    }

    // MARK: - Review round 2, MEDIUM 3: fit requires positive existing extents

    func testFitRejectsZeroExistingExtentsWithoutTouchingTheDocument() throws {
        let cases: [(label: String, size: Size, anchor: String)] = [
            ("zero width, anchor height", Size(width: 0, height: 1800000), "height"),
            ("zero height, anchor width", Size(width: 3600000, height: 0), "width"),
            ("zero width, anchor width", Size(width: 0, height: 1800000), "width"),
            ("zero height, anchor height", Size(width: 3600000, height: 0), "height"),
        ]
        for (index, c) in cases.enumerated() {
            let id = "zero-\(index)"
            try installExtremePicture(docId: id, position: Position(x: 720000, y: 1080000), size: c.size)
            let before = try snapshot(id)
            var args = fitArgs(2, c.anchor)
            args["doc_id"] = .string(id)
            XCTAssertThrowsError(try call("fit_picture_to_native_aspect", args), c.label)
            XCTAssertEqual(try snapshot(id), before, c.label)
            XCTAssertEqual(server.dirtyState[id], false, c.label)
        }
    }

    // MARK: - Review MEDIUM 3: parameter types are validated, never coerced

    func testNumericParametersRejectStringsAndBooleans() throws {
        let shapeId = try insertTextShape()
        let before = try snapshot()
        for key in ["x_cm", "y_cm", "width_cm", "height_cm"] {
            for bad: Value in [.string("10"), .bool(true), .array([.int(1)])] {
                var args = geometryArgs(shapeId, 2.0, 3.0, 10.0, 7.5)
                args[key] = bad
                XCTAssertThrowsError(try call("set_placeholder_geometry", args), "\(key)=\(bad)") { error in
                    XCTAssertTrue(error.localizedDescription.contains(key), "\(error.localizedDescription)")
                }
            }
        }
        for key in ["slide_index", "shape_id"] {
            for bad: Value in [.string("0"), .bool(false), .double(0.5), .double(.nan), .double(1e300)] {
                var args = geometryArgs(shapeId, 2.0, 3.0, 10.0, 7.5)
                args[key] = bad
                XCTAssertThrowsError(try call("set_placeholder_geometry", args), "\(key)=\(bad)") { error in
                    XCTAssertTrue(error.localizedDescription.contains(key), "\(error.localizedDescription)")
                }
            }
        }
        XCTAssertEqual(try snapshot(), before)
    }

    func testIntegralDoublesAreAcceptedForIntegerParameters() throws {
        let shapeId = try insertTextShape()
        var args = geometryArgs(shapeId, 2.0, 3.0, 10.0, 7.5)
        args["shape_id"] = .double(Double(shapeId))
        args["slide_index"] = .double(0)
        XCTAssertNoThrow(try call("set_placeholder_geometry", args))
    }

    func testNonFiniteAndHugeCentimetersAreRejectedWithoutMutation() throws {
        let shapeId = try insertTextShape()
        _ = try call("set_placeholder_geometry", geometryArgs(shapeId, 2.0, 3.0, 10.0, 7.5))
        let before = try snapshot()
        for bad in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, 1e300, -1e300] {
            for key in ["x_cm", "y_cm", "width_cm", "height_cm"] {
                var args = geometryArgs(shapeId, 2.0, 3.0, 10.0, 7.5)
                args[key] = .double(bad)
                XCTAssertThrowsError(try call("set_placeholder_geometry", args), "\(key)=\(bad)")
            }
            for key in ["x_cm", "y_cm", "width_cm", "height_cm"] {
                var args = pictureArgs(base64: try fourByThreePNG(), 2.0, 3.0, 10.0)
                args[key] = .double(bad)
                XCTAssertThrowsError(try call("place_picture_at", args), "\(key)=\(bad)")
            }
        }
        XCTAssertEqual(try snapshot(), before)
    }

    func testImageSourcesAreValidatedByTypeAndExactlyOneIsRequired() throws {
        let png = try fourByThreePNG()
        let before = try snapshot()
        let badCases: [(label: String, path: Value?, base64: Value?)] = [
            ("wrong-typed path next to valid base64", .int(5), .string(png)),
            ("wrong-typed base64 next to valid path", .string("/tmp/x.png"), .bool(true)),
            ("wrong-typed path alone", .array([.string("/tmp/x.png")]), nil),
            ("wrong-typed base64 alone", nil, .int(1)),
            ("both present", .string("/tmp/x.png"), .string(png)),
            ("neither present", nil, nil),
            ("both null", .null, .null),
        ]
        for c in badCases {
            var args = pictureArgs(base64: nil, 2.0, 3.0, 10.0)
            if let path = c.path { args["image_path"] = path }
            if let base64 = c.base64 { args["image_base64"] = base64 }
            XCTAssertThrowsError(try call("place_picture_at", args), c.label) { error in
                XCTAssertTrue(error.localizedDescription.contains("image_"), "\(c.label): \(error.localizedDescription)")
            }
            XCTAssertEqual(try snapshot(), before, c.label)
        }
    }

    func testExplicitNullImageSourceCountsAsAbsent() throws {
        var args = pictureArgs(base64: try fourByThreePNG(), 2.0, 3.0, 10.0)
        args["image_path"] = .null
        args["height_cm"] = .null
        let response = try json(call("place_picture_at", args))
        XCTAssertEqual(response["height_source"] as? String, "native_aspect")
    }

    func testFailuresLeaveTheWholeSessionAndDirtyFlagUnchanged() throws {
        // A clean session (not dirty) must stay clean through every rejected call.
        var pres = PptxWriter.createNew()
        pres.slides[0].elements = [.shape(Shape(id: 2, name: "Title", size: Size(width: 914400, height: 914400)))]
        server.initializeSession(docId: "clean", presentation: pres, sourcePath: nil, autosave: false)
        let before = try snapshot("clean")
        XCTAssertEqual(server.dirtyState["clean"], false)

        var bad = geometryArgs(2, 2.0, 3.0, 0.0, 7.5)
        bad["doc_id"] = .string("clean")
        XCTAssertThrowsError(try call("set_placeholder_geometry", bad))
        var pic = pictureArgs(base64: "@@@not-base64@@@", 2.0, 3.0, 10.0)
        pic["doc_id"] = .string("clean")
        XCTAssertThrowsError(try call("place_picture_at", pic))
        var fit = fitArgs(2, "width")
        fit["doc_id"] = .string("clean")
        XCTAssertThrowsError(try call("fit_picture_to_native_aspect", fit))

        XCTAssertEqual(try snapshot("clean"), before)
        XCTAssertEqual(server.dirtyState["clean"], false)
    }

    // MARK: - Helpers

    private func call(_ name: String, _ args: [String: Value]) throws -> String {
        try server.executeToolTask(name: name, args: args)
    }

    /// Parses a tool response as a JSON object and keeps the raw text under `_raw`.
    private func json(_ text: String) throws -> [String: Any] {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                                   "not JSON: \(text)")
        object["_raw"] = text
        return object
    }

    /// Full observable state of a session: the whole model tree (reflection
    /// dump), every media part's bytes, and the dirty flag.
    private func snapshot(_ id: String? = nil) throws -> String {
        let id = id ?? docId
        let pres = try XCTUnwrap(server.openPresentations[id])
        var out = ""
        dump(pres, to: &out)
        for image in pres.images {
            out += "\nmedia \(image.id) \(image.fileName) \(image.data.base64EncodedString())"
        }
        out += "\ndirty=\(String(describing: server.dirtyState[id]))"
        return out
    }

    private func presentation() throws -> Presentation {
        try XCTUnwrap(server.openPresentations[docId])
    }

    private func insertTextShape() throws -> Int {
        let text = try call("insert_text_shape", [
            "doc_id": .string(docId), "slide_index": .int(0), "text": .string("Title"),
            "x": .int(0), "y": .int(0), "width": .int(914400), "height": .int(914400),
        ])
        return try XCTUnwrap(Int(text.split(separator: "=").last ?? ""), text)
    }

    private func placeDistortedPicture() throws -> Int {
        let placed = try json(call("place_picture_at", pictureArgs(base64: fourByThreePNG(), 2.0, 3.0, 10.0)))
        let pictureId = try XCTUnwrap(placed["shape_id"] as? Int)
        _ = try call("set_placeholder_geometry", geometryArgs(pictureId, 2.0, 3.0, 10.0, 5.0))
        let distorted = try storedPicture(pictureId)
        XCTAssertEqual(distorted.size.width, 3600000)
        XCTAssertEqual(distorted.size.height, 1800000)
        return pictureId
    }

    private func storedShape(_ id: Int) throws -> Shape {
        try XCTUnwrap(presentation().slides[0].shapes.first { $0.id == id })
    }

    private func storedPicture(_ id: Int) throws -> PPTXSwift.Picture {
        try XCTUnwrap(presentation().slides[0].pictures.first { $0.id == id })
    }

    private func geometryArgs(_ shapeId: Int, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [String: Value] {
        ["doc_id": .string(docId), "slide_index": .int(0), "shape_id": .int(shapeId),
         "x_cm": .double(x), "y_cm": .double(y), "width_cm": .double(w), "height_cm": .double(h)]
    }

    private func pictureArgs(base64: String?, _ x: Double, _ y: Double, _ w: Double) -> [String: Value] {
        var args: [String: Value] = ["doc_id": .string(docId), "slide_index": .int(0),
                                     "x_cm": .double(x), "y_cm": .double(y), "width_cm": .double(w)]
        if let base64 { args["image_base64"] = .string(base64) }
        return args
    }

    private func fitArgs(_ shapeId: Int, _ anchor: String) -> [String: Value] {
        ["doc_id": .string(docId), "slide_index": .int(0), "shape_id": .int(shapeId), "anchor": .string(anchor)]
    }

    private func assertGeometry(
        _ response: [String: Any],
        cm: (String, String, String, String),
        emu: (Int, Int, Int, Int),
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let geometry = try XCTUnwrap(response["geometry"] as? [String: Any], file: file, line: line)
        let emuDict = try XCTUnwrap(geometry["emu"] as? [String: Any], file: file, line: line)
        XCTAssertEqual(emuDict["x"] as? Int, emu.0, file: file, line: line)
        XCTAssertEqual(emuDict["y"] as? Int, emu.1, file: file, line: line)
        XCTAssertEqual(emuDict["width"] as? Int, emu.2, file: file, line: line)
        XCTAssertEqual(emuDict["height"] as? Int, emu.3, file: file, line: line)
        // cm is 2-decimal: check the raw JSON text, since a parser drops trailing zeros.
        let raw = try XCTUnwrap(response["_raw"] as? String, file: file, line: line)
        let expected = "\"cm\":{\"x\":\(cm.0),\"y\":\(cm.1),\"width\":\(cm.2),\"height\":\(cm.3)}"
        XCTAssertTrue(raw.contains(expected), "expected \(expected) in \(raw)", file: file, line: line)
    }

    private func requiredParams(_ tool: Tool) -> [String] {
        guard case .object(let schema) = tool.inputSchema,
              case .array(let required)? = schema["required"] else { return [] }
        return required.compactMap { if case .string(let s) = $0 { return s } else { return nil } }.sorted()
    }

    private func propertyNames(_ tool: Tool) -> [String] {
        guard case .object(let schema) = tool.inputSchema,
              case .object(let props)? = schema["properties"] else { return [] }
        return Array(props.keys)
    }

    private func fourByThreePNG() throws -> String {
        try fourByThreePNGData().base64EncodedString()
    }

    /// 1600 x 1200 PNG drawn with CoreGraphics (no fixture file).
    private func fourByThreePNGData() throws -> Data {
        let (width, height) = (1600, 1200)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.9, green: 0.5, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}

import Foundation
import ImageIO
import MCP
import PPTXSwift
import UniformTypeIdentifiers

/// PowerPoint MCP Server
class PPTXMCPServer {
    /// Single source of truth for the server's self-reported version.
    /// MUST equal the release tag (scripts/release.sh enforces this — #1,
    /// aligned with che-pdf-mcp#3 convention). Bump when releasing.
    static let serverVersion = "0.4.0"

    private let server: Server
    private let transport: StdioTransport

    /// 目前開啟的簡報 (doc_id -> Presentation)
    private(set) var openPresentations: [String: Presentation] = [:]
    private var originalPaths: [String: String] = [:]
    private(set) var dirtyState: [String: Bool] = [:]
    private var autosaveState: [String: Bool] = [:]
    /// Autosave failure recorded by `markDirty` during the current tool call;
    /// `handleToolCall` appends it to the result so the caller learns of it.
    private var autosaveFailure: String?

    // MARK: - Server Instructions

    private static let serverInstructions = """
    # che-pptx-mcp — PowerPoint MCP Server

    Swift-native OOXML server for .pptx manipulation. 40 tools.

    ## Two Modes of Operation

    | Mode | Parameter | Use When | Tools |
    |------|-----------|----------|-------|
    | **Direct Mode** | `source_path` | Quick read-only access | ~15 tools |
    | **Session Mode** | `doc_id` | Full read/write with open→edit→save lifecycle | All tools |

    ### Direct Mode (source_path)
    Pass `source_path` with the .pptx file path. No need to call `open_presentation` first.

    ### Session Mode (doc_id)
    Call `open_presentation` first, then use `doc_id` for subsequent operations.

    ## Direct Mode Tools (source_path supported)
    `get_presentation_info`, `get_slide_count`, `get_text`, `get_slide_text`,
    `get_slide_shapes`, `get_shape_text`, `get_slide_notes`, `list_images`,
    `get_tables`, `get_table_data`, `search_text`, `export_markdown`,
    `get_theme`, `get_slide_master`, `get_slide_layouts`
    """

    init() async {
        self.server = Server(
            name: "che-pptx-mcp",
            version: Self.serverVersion,
            instructions: Self.serverInstructions,
            capabilities: .init(tools: .init())
        )
        self.transport = StdioTransport()
        await registerToolHandlers()
    }

    func run() async throws {
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    // MARK: - Session Management

    func initializeSession(docId: String, presentation: Presentation, sourcePath: String?, autosave: Bool) {
        openPresentations[docId] = presentation
        originalPaths[docId] = sourcePath
        dirtyState[docId] = false
        autosaveState[docId] = autosave
    }

    private func removeSession(docId: String) {
        openPresentations.removeValue(forKey: docId)
        originalPaths.removeValue(forKey: docId)
        dirtyState.removeValue(forKey: docId)
        autosaveState.removeValue(forKey: docId)
    }

    /// Marks the session modified and, with autosave on, writes it back.
    /// The dirty flag is cleared only when that write succeeds: a failed
    /// autosave keeps the session dirty — so `close_presentation` still
    /// refuses to drop it — and is reported through `autosaveFailure`.
    private func markDirty(_ docId: String) {
        dirtyState[docId] = true
        if autosaveState[docId] == true, let path = originalPaths[docId], let pres = openPresentations[docId] {
            do {
                try PptxWriter.write(pres, to: URL(fileURLWithPath: path))
                dirtyState[docId] = false
            } catch {
                autosaveFailure = "自動存檔失敗（\(path)）：\(error.localizedDescription)。變更仍在記憶體中，請以 save_presentation 另存或重試"
            }
        }
    }

    // MARK: - Document Resolution

    private func resolvePresentation(args: [String: Value]) throws -> (Presentation, String?) {
        if let sourcePath = args["source_path"]?.stringValue {
            guard FileManager.default.fileExists(atPath: sourcePath) else {
                throw PPTXError.fileNotFound(sourcePath)
            }
            let presentation = try PptxReader.read(from: URL(fileURLWithPath: sourcePath))
            return (presentation, nil)
        } else if let docId = args["doc_id"]?.stringValue {
            guard let pres = openPresentations[docId] else {
                throw PPTXError.invalidParameter("doc_id", "找不到已開啟的簡報: \(docId)")
            }
            return (pres, docId)
        } else {
            throw PPTXError.invalidParameter("source_path/doc_id", "需要 source_path 或 doc_id")
        }
    }

    private func requireSession(args: [String: Value]) throws -> (String, Presentation) {
        guard let docId = args["doc_id"]?.stringValue else {
            throw PPTXError.invalidParameter("doc_id", "此操作需要 doc_id（Session Mode）")
        }
        guard let pres = openPresentations[docId] else {
            throw PPTXError.invalidParameter("doc_id", "找不到已開啟的簡報: \(docId)")
        }
        return (docId, pres)
    }

    // MARK: - Tool Registration

    private func registerToolHandlers() async {
        let tools = allTools

        await server.withMethodHandler(ListTools.self) { [tools] _ in
            ListTools.Result(tools: tools)
        }

        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self else {
                return CallTool.Result(content: [.text("Server unavailable")], isError: true)
            }
            return try await self.handleToolCall(params)
        }
    }

    func handleToolCall(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let name = params.name
        let args = params.arguments ?? [:]

        autosaveFailure = nil
        do {
            let result = try executeToolTask(name: name, args: args)
            // An autosave failure travels as its own content item: some tools
            // (the geometry tools) promise that their text is one JSON object.
            var content: [Tool.Content] = [.text(result)]
            if let failure = autosaveFailure {
                content.append(.text("警告：\(failure)"))
                autosaveFailure = nil
            }
            return CallTool.Result(content: content)
        } catch {
            return CallTool.Result(content: [.text("Error: \(error.localizedDescription)")], isError: true)
        }
    }

    // MARK: - Tool Dispatch

    func executeToolTask(name: String, args: [String: Value]) throws -> String {
        switch name {
        // Session management
        case "create_presentation":    return try createPresentation(args: args)
        case "open_presentation":      return try openPresentation(args: args)
        case "save_presentation":      return try savePresentation(args: args)
        case "close_presentation":     return try closePresentation(args: args)
        case "list_open_presentations": return listOpenPresentations()

        // Presentation info (direct mode)
        case "get_presentation_info":  return try getPresentationInfo(args: args)
        case "get_slide_count":        return try getSlideCount(args: args)
        case "get_text":               return try getText(args: args)

        // Slide content (direct mode)
        case "get_slide_text":         return try getSlideText(args: args)
        case "get_slide_shapes":       return try getSlideShapes(args: args)
        case "get_shape_text":         return try getShapeText(args: args)
        case "get_slide_notes":        return try getSlideNotes(args: args)

        // Image tools
        case "list_images":            return try listImages(args: args)
        case "export_image":           return try exportImage(args: args)
        case "insert_image":           return try insertImage(args: args)
        case "delete_image":           return try deleteImage(args: args)

        // Table tools
        case "get_tables":             return try getTables(args: args)
        case "get_table_data":         return try getTableData(args: args)
        case "insert_table":           return try insertTable(args: args)
        case "update_cell":            return try updateCell(args: args)

        // Slide management
        case "add_slide":              return try addSlide(args: args)
        case "delete_slide":           return try deleteSlide(args: args)
        case "reorder_slides":         return try reorderSlides(args: args)
        case "duplicate_slide":        return try duplicateSlide(args: args)

        // Shape editing
        case "insert_text_shape":      return try insertTextShape(args: args)
        case "update_shape_text":      return try updateShapeText(args: args)
        case "delete_shape":           return try deleteShape(args: args)
        case "set_shape_position":     return try setShapePosition(args: args)
        case "set_shape_size":         return try setShapeSize(args: args)
        case "set_shape_fill":         return try setShapeFill(args: args)

        // Geometry (cm)
        case "set_placeholder_geometry":     return try setPlaceholderGeometry(args: args)
        case "place_picture_at":             return try placePictureAt(args: args)
        case "fit_picture_to_native_aspect": return try fitPictureToNativeAspect(args: args)

        // Notes & transition
        case "add_notes":              return try addNotes(args: args)
        case "set_transition":         return try setTransition(args: args)

        // Search & export (direct mode)
        case "search_text":            return try searchText(args: args)
        case "export_markdown":        return try exportMarkdown(args: args)

        // Theme (direct mode)
        case "get_theme":              return try getTheme(args: args)
        case "get_slide_master":       return try getSlideMaster(args: args)
        case "get_slide_layouts":      return try getSlideLayouts(args: args)

        default:
            throw PPTXError.invalidParameter("tool", "Unknown tool: \(name)")
        }
    }

    // MARK: - Tools Definition

    var allTools: [Tool] {
        [
            // --- Session Management ---
            tool("create_presentation", "建立新的空白 PowerPoint 簡報",
                 required: ["doc_id"],
                 props: ["doc_id": prop(.string, "簡報識別碼"),
                         "autosave": prop(.boolean, "每次編輯後自動存檔")]),
            tool("open_presentation", "開啟現有的 .pptx 檔案",
                 required: ["path", "doc_id"],
                 props: ["path": prop(.string, "檔案路徑"),
                         "doc_id": prop(.string, "簡報識別碼"),
                         "autosave": prop(.boolean, "自動存檔")]),
            tool("save_presentation", "儲存簡報到檔案",
                 required: ["doc_id"],
                 props: ["doc_id": prop(.string, "簡報識別碼"),
                         "path": prop(.string, "輸出路徑（可選，預設為原始路徑）")]),
            tool("close_presentation", "關閉簡報並釋放記憶體",
                 required: ["doc_id"],
                 props: ["doc_id": prop(.string, "簡報識別碼")]),
            tool("list_open_presentations", "列出所有已開啟的簡報",
                 required: [], props: [:]),

            // --- Presentation Info (direct mode) ---
            tool("get_presentation_info", "取得簡報資訊（投影片數、尺寸、屬性）",
                 required: [], props: docOrSourceProps()),
            tool("get_slide_count", "取得投影片數量",
                 required: [], props: docOrSourceProps()),
            tool("get_text", "取得整份簡報的純文字",
                 required: [], props: docOrSourceProps()),

            // --- Slide Content (direct mode) ---
            tool("get_slide_text", "取得指定投影片的文字",
                 required: ["slide_index"],
                 props: docOrSourceProps(["slide_index": prop(.integer, "投影片索引（從 0 開始）")])),
            tool("get_slide_shapes", "列出投影片上所有形狀",
                 required: ["slide_index"],
                 props: docOrSourceProps(["slide_index": prop(.integer, "投影片索引")])),
            tool("get_shape_text", "取得指定形狀的文字",
                 required: ["slide_index", "shape_id"],
                 props: docOrSourceProps(["slide_index": prop(.integer, "投影片索引"),
                                          "shape_id": prop(.integer, "形狀 ID")])),
            tool("get_slide_notes", "取得投影片備忘稿",
                 required: ["slide_index"],
                 props: docOrSourceProps(["slide_index": prop(.integer, "投影片索引")])),

            // --- Image Tools ---
            tool("list_images", "列出簡報中所有圖片",
                 required: [], props: docOrSourceProps()),
            tool("export_image", "匯出圖片為 base64",
                 required: ["image_id"],
                 props: docOrSourceProps(["image_id": prop(.string, "圖片檔名")])),
            tool("insert_image", "插入圖片到指定投影片",
                 required: ["doc_id", "slide_index", "base64", "file_name"],
                 props: ["doc_id": prop(.string, "簡報識別碼"),
                         "slide_index": prop(.integer, "投影片索引"),
                         "base64": prop(.string, "Base64 圖片資料"),
                         "file_name": prop(.string, "檔名（與既有 media 同名時自動改名）"),
                         "x": prop(.integer, "X 位置 (EMU，預設 0)"), "y": prop(.integer, "Y 位置 (EMU，預設 0)"),
                         "width": prop(.integer, "寬度 (EMU，預設 3048000)"), "height": prop(.integer, "高度 (EMU，預設 2286000)")]),
            tool("delete_image", "刪除圖片",
                 required: ["doc_id", "slide_index", "shape_id"],
                 props: ["doc_id": prop(.string, "簡報識別碼"),
                         "slide_index": prop(.integer, "投影片索引"),
                         "shape_id": prop(.integer, "圖片形狀 ID")]),

            // --- Table Tools ---
            tool("get_tables", "列出投影片上所有表格",
                 required: ["slide_index"],
                 props: docOrSourceProps(["slide_index": prop(.integer, "投影片索引")])),
            tool("get_table_data", "取得表格內容（2D 陣列）",
                 required: ["slide_index", "shape_id"],
                 props: docOrSourceProps(["slide_index": prop(.integer, "投影片索引"),
                                          "shape_id": prop(.integer, "表格形狀 ID")])),
            tool("insert_table", "插入表格到投影片",
                 required: ["doc_id", "slide_index", "columns", "rows"],
                 props: ["doc_id": prop(.string, "簡報識別碼"),
                         "slide_index": prop(.integer, "投影片索引"),
                         "columns": prop(.integer, "欄數"),
                         "rows": prop(.integer, "列數"),
                         "x": prop(.integer, "X 位置 (EMU)"), "y": prop(.integer, "Y 位置 (EMU)"),
                         "width": prop(.integer, "寬度 (EMU)"), "height": prop(.integer, "高度 (EMU)")]),
            tool("update_cell", "更新表格儲存格文字",
                 required: ["doc_id", "slide_index", "shape_id", "row", "col", "text"],
                 props: ["doc_id": prop(.string, "簡報識別碼"),
                         "slide_index": prop(.integer, "投影片索引"),
                         "shape_id": prop(.integer, "表格形狀 ID"),
                         "row": prop(.integer, "列索引"), "col": prop(.integer, "欄索引"),
                         "text": prop(.string, "新文字")]),

            // --- Slide Management ---
            tool("add_slide", "新增投影片",
                 required: ["doc_id"],
                 props: ["doc_id": prop(.string, "簡報識別碼"),
                         "at_index": prop(.integer, "插入位置（可選，預設為末尾）")]),
            tool("delete_slide", "刪除投影片",
                 required: ["doc_id", "slide_index"],
                 props: ["doc_id": prop(.string, "簡報識別碼"),
                         "slide_index": prop(.integer, "投影片索引")]),
            tool("reorder_slides", "重新排列投影片",
                 required: ["doc_id", "from_index", "to_index"],
                 props: ["doc_id": prop(.string, "簡報識別碼"),
                         "from_index": prop(.integer, "來源索引"),
                         "to_index": prop(.integer, "目標索引")]),
            tool("duplicate_slide", "複製投影片",
                 required: ["doc_id", "slide_index"],
                 props: ["doc_id": prop(.string, "簡報識別碼"),
                         "slide_index": prop(.integer, "投影片索引")]),

            // --- Shape Editing ---
            tool("insert_text_shape", "插入文字框",
                 required: ["doc_id", "slide_index", "text"],
                 props: ["doc_id": prop(.string, "簡報識別碼"),
                         "slide_index": prop(.integer, "投影片索引"),
                         "text": prop(.string, "文字內容"),
                         "x": prop(.integer, "X (EMU，預設 457200)"), "y": prop(.integer, "Y (EMU，預設 1600200)"),
                         "width": prop(.integer, "寬度 (EMU，預設 8229600)"), "height": prop(.integer, "高度 (EMU，預設 1143000)")]),
            tool("update_shape_text", "更新形狀文字",
                 required: ["doc_id", "slide_index", "shape_id", "text"],
                 props: ["doc_id": prop(.string, "簡報識別碼"),
                         "slide_index": prop(.integer, "投影片索引"),
                         "shape_id": prop(.integer, "形狀 ID"),
                         "text": prop(.string, "新文字")]),
            tool("delete_shape", "刪除形狀",
                 required: ["doc_id", "slide_index", "shape_id"],
                 props: ["doc_id": prop(.string, "簡報識別碼"),
                         "slide_index": prop(.integer, "投影片索引"),
                         "shape_id": prop(.integer, "形狀 ID")]),
            tool("set_shape_position", "設定形狀位置",
                 required: ["doc_id", "slide_index", "shape_id", "x", "y"],
                 props: ["doc_id": prop(.string, "簡報識別碼"),
                         "slide_index": prop(.integer, "投影片索引"),
                         "shape_id": prop(.integer, "形狀 ID"),
                         "x": prop(.integer, "X (EMU)"), "y": prop(.integer, "Y (EMU)")]),
            tool("set_shape_size", "設定形狀大小",
                 required: ["doc_id", "slide_index", "shape_id", "width", "height"],
                 props: ["doc_id": prop(.string, "簡報識別碼"),
                         "slide_index": prop(.integer, "投影片索引"),
                         "shape_id": prop(.integer, "形狀 ID"),
                         "width": prop(.integer, "寬度 (EMU)"), "height": prop(.integer, "高度 (EMU)")]),
            tool("set_shape_fill", "設定形狀填色",
                 required: ["doc_id", "slide_index", "shape_id", "color"],
                 props: ["doc_id": prop(.string, "簡報識別碼"),
                         "slide_index": prop(.integer, "投影片索引"),
                         "shape_id": prop(.integer, "形狀 ID"),
                         "color": prop(.string, "Hex RGB 色碼（e.g. FF0000）")]),

            // --- Geometry (cm) ---
            tool("set_placeholder_geometry",
                 "以公分設定任一頂層元素的位置與大小 — any shape (placeholder or otherwise), picture or table frame; "
                 + "群組內元素不支援。超出投影片範圍仍會套用，回應附 warnings 指出越界的邊；寬高必須 > 0。"
                 + "回應為 JSON，含 cm（小數兩位）與 EMU 幾何",
                 required: ["doc_id", "slide_index", "shape_id", "x_cm", "y_cm", "width_cm", "height_cm"],
                 props: ["doc_id": prop(.string, "簡報識別碼"),
                         "slide_index": prop(.integer, "投影片索引"),
                         "shape_id": prop(.integer, "形狀 ID"),
                         "x_cm": prop(.number, "左緣 X（公分）"), "y_cm": prop(.number, "上緣 Y（公分）"),
                         "width_cm": prop(.number, "寬度（公分，> 0）"), "height_cm": prop(.number, "高度（公分，> 0）")]),
            tool("place_picture_at",
                 "插入圖片並以公分定位（一次完成，回應含新 shape_id）。image_path 與 image_base64 擇一；"
                 + "省略 height_cm 時依圖片原生像素比例推導高度（無法解碼的格式如 EMF/WMF 須給 height_cm）。"
                 + "回應為 JSON，含 cm（小數兩位）與 EMU 幾何",
                 required: ["doc_id", "slide_index", "x_cm", "y_cm", "width_cm"],
                 props: ["doc_id": prop(.string, "簡報識別碼"),
                         "slide_index": prop(.integer, "投影片索引"),
                         "image_path": prop(.string, "圖片檔路徑（與 image_base64 擇一）"),
                         "image_base64": prop(.string, "Base64 圖片資料（與 image_path 擇一）"),
                         "x_cm": prop(.number, "左緣 X（公分）"), "y_cm": prop(.number, "上緣 Y（公分）"),
                         "width_cm": prop(.number, "寬度（公分，> 0）"),
                         "height_cm": prop(.number, "高度（公分，> 0；可選，省略則依原生比例推導）")]),
            tool("fit_picture_to_native_aspect",
                 "依圖片原生像素比例重算圖片的非錨定邊：anchor=width 保留寬度重算高度，anchor=height 反之；"
                 + "位置不變。非圖片或群組內元素會回錯誤。回應為 JSON，含 cm（小數兩位）與 EMU 幾何",
                 required: ["doc_id", "slide_index", "shape_id", "anchor"],
                 props: ["doc_id": prop(.string, "簡報識別碼"),
                         "slide_index": prop(.integer, "投影片索引"),
                         "shape_id": prop(.integer, "圖片形狀 ID"),
                         "anchor": prop(.string, "保留的邊：width 或 height")]),

            // --- Notes & Transition ---
            tool("add_notes", "新增或更新備忘稿",
                 required: ["doc_id", "slide_index", "text"],
                 props: ["doc_id": prop(.string, "簡報識別碼"),
                         "slide_index": prop(.integer, "投影片索引"),
                         "text": prop(.string, "備忘稿文字")]),
            tool("set_transition", "設定投影片轉場",
                 required: ["doc_id", "slide_index", "type"],
                 props: ["doc_id": prop(.string, "簡報識別碼"),
                         "slide_index": prop(.integer, "投影片索引"),
                         "type": prop(.string, "轉場類型（fade/push/wipe/split/dissolve）"),
                         "speed": prop(.string, "速度（slow/med/fast）")]),

            // --- Search & Export (direct mode) ---
            tool("search_text", "搜尋文字",
                 required: ["query"],
                 props: docOrSourceProps(["query": prop(.string, "搜尋關鍵字")])),
            tool("export_markdown", "匯出為 Markdown",
                 required: [], props: docOrSourceProps()),

            // --- Theme (direct mode) ---
            tool("get_theme", "取得主題資訊（色彩配置、字型配置）",
                 required: [], props: docOrSourceProps()),
            tool("get_slide_master", "取得投影片母片資訊",
                 required: [], props: docOrSourceProps()),
            tool("get_slide_layouts", "列出所有版面配置",
                 required: [], props: docOrSourceProps()),
        ]
    }

    // MARK: - Tool Schema Helpers

    private func prop(_ type: PropType, _ description: String) -> [String: Value] {
        ["type": .string(type.rawValue), "description": .string(description)]
    }

    private enum PropType: String { case string, integer, boolean, number }

    private func docOrSourceProps(_ extra: [String: [String: Value]] = [:]) -> [String: [String: Value]] {
        var props: [String: [String: Value]] = [
            "doc_id": prop(.string, "簡報識別碼（Session Mode）"),
            "source_path": prop(.string, "檔案路徑（Direct Mode，唯讀）"),
        ]
        for (k, v) in extra { props[k] = v }
        return props
    }

    private func tool(_ name: String, _ description: String, required: [String], props: [String: [String: Value]]) -> Tool {
        var schemaProps: [String: Value] = [:]
        for (key, val) in props {
            var propDict: [String: Value] = [:]
            for (k, v) in val { propDict[k] = v }
            schemaProps[key] = .object(propDict)
        }

        return Tool(
            name: name,
            description: description,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(schemaProps),
                "required": .array(required.map { .string($0) })
            ])
        )
    }

    // MARK: - Helper

    private func findShape(in slide: Slide, id: Int) -> (Int, Shape)? {
        for (i, el) in slide.elements.enumerated() {
            if case .shape(let s) = el, s.id == id { return (i, s) }
        }
        return nil
    }

    private func findElement(in slide: Slide, id: Int) -> Int? {
        for (i, el) in slide.elements.enumerated() {
            switch el {
            case .shape(let s) where s.id == id: return i
            case .picture(let p) where p.id == id: return i
            case .graphicFrame(let f) where f.id == id: return i
            case .group(let g) where g.id == id: return i
            default: continue
            }
        }
        return nil
    }

    // MARK: - Session Management Tools

    /// #8：重用 `doc_id` 不得蓋掉還沒存檔的 session（那也會繞過 close_presentation 的 dirty 保護）。
    /// 乾淨的 session 維持可替換。
    private func refuseReplacingUnsavedSession(_ docId: String) throws {
        guard dirtyState[docId] == true else { return }
        throw PPTXError.invalidParameter(
            "doc_id", "doc_id「\(docId)」已有尚未存檔的修改；請先 save_presentation 或 close_presentation，或改用另一個 doc_id"
        )
    }

    private func createPresentation(args: [String: Value]) throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw PPTXError.invalidParameter("doc_id", "需要 doc_id")
        }
        try refuseReplacingUnsavedSession(docId)
        let autosave = try optionalBool(args, "autosave") ?? false
        let presentation = PptxWriter.createNew()
        initializeSession(docId: docId, presentation: presentation, sourcePath: nil, autosave: autosave)
        return "已建立新簡報: \(docId)（1 張空白投影片）"
    }

    private func openPresentation(args: [String: Value]) throws -> String {
        guard let path = args["path"]?.stringValue else {
            throw PPTXError.invalidParameter("path", "需要 path")
        }
        guard let docId = args["doc_id"]?.stringValue else {
            throw PPTXError.invalidParameter("doc_id", "需要 doc_id")
        }
        try refuseReplacingUnsavedSession(docId)
        let autosave = try optionalBool(args, "autosave") ?? false

        let presentation = try PptxReader.read(from: URL(fileURLWithPath: path))
        initializeSession(docId: docId, presentation: presentation, sourcePath: path, autosave: autosave)
        let opened = "已開啟簡報: \(docId)（\(presentation.slideCount) 張投影片）"
        guard let notice = Self.unsupportedMediaNotice(presentation) else { return opened }
        return opened + "\n" + notice
    }

    /// pptx-swift 0.4.0 起，含音訊、影片或換場音效的簡報一律拒絕寫出
    /// （PsychQuant/pptx-swift#5）。開檔當下就說清楚，不讓呼叫端編輯到存檔才發現。
    static func unsupportedMediaNotice(_ presentation: Presentation) -> String? {
        let slides = presentation.slides.indices
            .filter { presentation.slides[$0].containsUnsupportedMedia }
            .map { "第 \($0 + 1) 張" }
        guard !slides.isEmpty else { return nil }
        return "注意：\(slides.joined(separator: "、"))投影片含音訊、影片或換場音效。這些內容無法保留，因此這份簡報可以讀取與檢視，但無法存檔（save_presentation 與 autosave 都會失敗）。"
    }

    private func savePresentation(args: [String: Value]) throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw PPTXError.invalidParameter("doc_id", "需要 doc_id")
        }
        guard let presentation = openPresentations[docId] else {
            throw PPTXError.invalidParameter("doc_id", "找不到: \(docId)")
        }

        let path: String
        if let p = args["path"]?.stringValue, !p.isEmpty {
            path = p
        } else if let p = originalPaths[docId] {
            path = p
        } else {
            throw PPTXError.invalidParameter("path", "需要指定儲存路徑")
        }

        try PptxWriter.write(presentation, to: URL(fileURLWithPath: path))
        originalPaths[docId] = path
        dirtyState[docId] = false
        return "已儲存: \(path)"
    }

    private func closePresentation(args: [String: Value]) throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw PPTXError.invalidParameter("doc_id", "需要 doc_id")
        }
        guard openPresentations[docId] != nil else {
            throw PPTXError.invalidParameter("doc_id", "找不到: \(docId)")
        }
        if dirtyState[docId] == true {
            throw PPTXError.writeError("簡報有未儲存的變更，請先呼叫 save_presentation")
        }
        removeSession(docId: docId)
        return "已關閉: \(docId)"
    }

    private func listOpenPresentations() -> String {
        if openPresentations.isEmpty { return "目前沒有開啟的簡報" }
        var lines: [String] = []
        for (docId, pres) in openPresentations {
            let path = originalPaths[docId] ?? "(new)"
            let dirty = dirtyState[docId] == true ? " [modified]" : ""
            lines.append("- \(docId): \(pres.slideCount) slides, \(path)\(dirty)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Presentation Info

    private func getPresentationInfo(args: [String: Value]) throws -> String {
        let (pres, _) = try resolvePresentation(args: args)
        let info = pres.getInfo()
        return """
        Slide count: \(info.slideCount)
        Size: \(info.width)×\(info.height) EMU (\(String(format: "%.1f", Double(info.width)/914400))×\(String(format: "%.1f", Double(info.height)/914400)) inches)
        Title: \(info.title ?? "(none)")
        Author: \(info.author ?? "(none)")
        Images: \(pres.images.count)
        """
    }

    private func getSlideCount(args: [String: Value]) throws -> String {
        let (pres, _) = try resolvePresentation(args: args)
        return "\(pres.slideCount)"
    }

    private func getText(args: [String: Value]) throws -> String {
        let (pres, _) = try resolvePresentation(args: args)
        return pres.getText()
    }

    // MARK: - Slide Content

    private func getSlideText(args: [String: Value]) throws -> String {
        let (pres, _) = try resolvePresentation(args: args)
        let idx = try validSlideIndex(args, in: pres)
        return pres.slides[idx].getText()
    }

    private func getSlideShapes(args: [String: Value]) throws -> String {
        let (pres, _) = try resolvePresentation(args: args)
        let idx = try validSlideIndex(args, in: pres)

        var lines: [String] = []
        for element in pres.slides[idx].elements {
            switch element {
            case .shape(let s):
                let phStr = s.placeholder.map { " [placeholder:\($0.rawValue)]" } ?? ""
                let text = s.textBody?.getText().prefix(50) ?? ""
                lines.append("Shape id=\(s.id) name=\"\(s.name)\"\(phStr) pos=(\(s.position.x),\(s.position.y)) size=(\(s.size.width)×\(s.size.height)) \(cmSummary(s.position, s.size)) text=\"\(text)\"")
            case .picture(let p):
                lines.append("Picture id=\(p.id) name=\"\(p.name)\" embed=\(p.imageRelationshipId) pos=(\(p.position.x),\(p.position.y)) size=(\(p.size.width)×\(p.size.height)) \(cmSummary(p.position, p.size))")
            case .graphicFrame(let f):
                let tableInfo = f.table.map { "table \($0.columnCount)×\($0.rowCount)" } ?? "graphic"
                lines.append("GraphicFrame id=\(f.id) name=\"\(f.name)\" \(tableInfo)")
            case .group(let g):
                lines.append("Group id=\(g.id) name=\"\(g.name)\" elements=\(g.elements.count)")
            }
        }
        return lines.isEmpty ? "(empty slide)" : lines.joined(separator: "\n")
    }

    private func getShapeText(args: [String: Value]) throws -> String {
        let (pres, _) = try resolvePresentation(args: args)
        let idx = try validSlideIndex(args, in: pres)
        let shapeId = try requiredShapeId(args)
        guard let (_, shape) = findShape(in: pres.slides[idx], id: shapeId) else {
            throw PPTXError.invalidParameter("shape_id", "找不到形狀 id=\(shapeId)")
        }
        return shape.textBody?.getText() ?? "(no text)"
    }

    private func getSlideNotes(args: [String: Value]) throws -> String {
        let (pres, _) = try resolvePresentation(args: args)
        let idx = try validSlideIndex(args, in: pres)
        return pres.slides[idx].notes ?? "(no notes)"
    }

    // MARK: - Image Tools

    private func listImages(args: [String: Value]) throws -> String {
        let (pres, _) = try resolvePresentation(args: args)
        if pres.images.isEmpty { return "No images" }
        return pres.images.map { "- \($0.fileName) (\($0.data.count) bytes)" }.joined(separator: "\n")
    }

    private func exportImage(args: [String: Value]) throws -> String {
        let (pres, _) = try resolvePresentation(args: args)
        guard let imageId = args["image_id"]?.stringValue else {
            throw PPTXError.invalidParameter("image_id", "需要 image_id")
        }
        guard let image = pres.images.first(where: { $0.id == imageId || $0.fileName == imageId }) else {
            throw PPTXError.invalidParameter("image_id", "找不到圖片: \(imageId)")
        }
        return "{\"fileName\":\"\(image.fileName)\",\"base64\":\"\(image.data.base64EncodedString())\"}"
    }

    private func insertImage(args: [String: Value]) throws -> String {
        let (docId, pres) = try requireSession(args: args)
        let idx = try validSlideIndex(args, in: pres)
        let x = try coordinateEmu(args, "x", default: 0)
        let y = try coordinateEmu(args, "y", default: 0)
        let w = try extentEmu(args, "width", default: 3048000)
        let h = try extentEmu(args, "height", default: 2286000)
        guard let base64 = args["base64"]?.stringValue,
              let requestedName = args["file_name"]?.stringValue,
              let data = Data(base64Encoded: base64) else {
            throw PPTXError.invalidParameter("base64", "Invalid base64 data")
        }
        // Same rule as place_picture_at: pictures find their media by file
        // name, so a reused name would point the new picture — and, on save,
        // the old one — at the wrong bytes.
        let fileName = uniqueMediaFileName(requestedName, in: pres)

        let nextId = try nextElementId(in: openPresentations[docId]!.slides[idx])
        appendPicture(docId: docId, slideIndex: idx, id: nextId, data: data, fileName: fileName,
                      position: Position(x: x, y: y), size: Size(width: w, height: h))
        return "已插入圖片: \(fileName) (id=\(nextId))"
    }

    /// One more than the largest element id anywhere in the slide's shape
    /// tree — group children included, so a new element can never share an id
    /// with (and shadow) an element inside a group — and at least 2. Throws
    /// when the largest id has already reached `maxDrawingElementId`
    /// (`UInt32.max`), which also rules out `Int` overflow.
    ///
    /// The single id allocator for every tool that adds an element
    /// (`insert_image`, `place_picture_at`, `insert_text_shape`,
    /// `insert_table` — #6).
    private func nextElementId(in slide: Slide) throws -> Int {
        let maxId = max(maxElementId(in: slide.elements) ?? 1, 1)
        guard maxId < Self.maxDrawingElementId else {
            throw PPTXError.invalidParameter(
                "shape_id",
                "投影片上已有 id=\(maxId) 的元素，已達 DrawingML 元素 id 上限 \(Self.maxDrawingElementId)，無法再配置新 id"
            )
        }
        return maxId + 1
    }

    /// `p:cNvPr/@id` is `ST_DrawingElementId`, an `xsd:unsignedInt`: an id
    /// above this would make the saved file invalid (review round 1, HIGH 1).
    static let maxDrawingElementId = Int(UInt32.max)

    private func maxElementId(in elements: [SlideElement]) -> Int? {
        elements.compactMap { element -> Int? in
            switch element {
            case .shape(let s): return s.id
            case .picture(let p): return p.id
            case .graphicFrame(let f): return f.id
            case .group(let g): return max(g.id, maxElementId(in: g.elements) ?? g.id)
            }
        }.max()
    }

    /// Shared picture-insertion path (insert_image, place_picture_at): appends
    /// the picture element and its media part, linking the two by file name.
    private func appendPicture(docId: String, slideIndex idx: Int, id: Int, data: Data, fileName: String,
                               position: Position, size: Size) {
        let picture = Picture(id: id, name: fileName, position: position, size: size,
                              imageRelationshipId: "rId\(id)", mediaFileName: fileName)
        openPresentations[docId]?.slides[idx].elements.append(.picture(picture))
        openPresentations[docId]?.images.append(MediaFile(id: fileName, fileName: fileName, data: data))
        markDirty(docId)
    }

    private func deleteImage(args: [String: Value]) throws -> String {
        let (docId, pres) = try requireSession(args: args)
        let idx = try validSlideIndex(args, in: pres)
        let shapeId = try requiredShapeId(args)
        // Pictures only: findElement also matches shapes, tables and groups,
        // and deleting one of those through an image tool loses content.
        guard let elIdx = findElement(in: pres.slides[idx], id: shapeId) else {
            throw PPTXError.invalidParameter("shape_id", "找不到 id=\(shapeId)")
        }
        guard case .picture = pres.slides[idx].elements[elIdx] else {
            throw PPTXError.invalidParameter("shape_id", "id=\(shapeId) 不是圖片；delete_image 只刪除圖片，其他元素請用 delete_shape")
        }
        openPresentations[docId]?.slides[idx].elements.remove(at: elIdx)
        markDirty(docId)
        return "已刪除圖片 id=\(shapeId)"
    }

    // MARK: - Table Tools

    private func getTables(args: [String: Value]) throws -> String {
        let (pres, _) = try resolvePresentation(args: args)
        let idx = try validSlideIndex(args, in: pres)

        let tables = pres.slides[idx].tables
        if tables.isEmpty { return "No tables on this slide" }
        return tables.map { f in
            "GraphicFrame id=\(f.id) table \(f.table!.columnCount)×\(f.table!.rowCount)"
        }.joined(separator: "\n")
    }

    private func getTableData(args: [String: Value]) throws -> String {
        let (pres, _) = try resolvePresentation(args: args)
        let idx = try validSlideIndex(args, in: pres)
        let shapeId = try requiredShapeId(args)

        guard let frame = pres.slides[idx].elements.compactMap({ el -> GraphicFrame? in
            if case .graphicFrame(let f) = el, f.id == shapeId { return f }
            return nil
        }).first, let table = frame.table else {
            throw PPTXError.invalidParameter("shape_id", "找不到表格 id=\(shapeId)")
        }

        var lines: [String] = ["Columns: \(table.columnCount), Rows: \(table.rowCount)"]
        for (ri, row) in table.rows.enumerated() {
            let cells = row.cells.map { $0.getText() }
            lines.append("Row \(ri): \(cells.joined(separator: " | "))")
        }
        return lines.joined(separator: "\n")
    }

    private func insertTable(args: [String: Value]) throws -> String {
        let (docId, pres) = try requireSession(args: args)
        let idx = try validSlideIndex(args, in: pres)
        let cols = try requiredInt(args, "columns", in: Self.tableDimensionRange)
        let rows = try requiredInt(args, "rows", in: Self.tableDimensionRange)

        let x = try coordinateEmu(args, "x", default: 457200)
        let y = try coordinateEmu(args, "y", default: 1600200)
        let w = try extentEmu(args, "width", default: 8229600)
        let h = try extentEmu(args, "height", default: 3657600)

        let colWidth = w / cols
        let rowHeight = h / rows

        let nextId = try nextElementId(in: openPresentations[docId]!.slides[idx])

        let table = DrawingTable(
            columns: (0..<cols).map { _ in TableColumn(width: colWidth) },
            rows: (0..<rows).map { _ in
                TableRow(height: rowHeight, cells: (0..<cols).map { _ in TableCell(text: "") })
            }
        )
        let frame = GraphicFrame(id: nextId, name: "Table \(nextId)",
                                  position: Position(x: x, y: y),
                                  size: Size(width: w, height: h), table: table)
        openPresentations[docId]?.slides[idx].elements.append(.graphicFrame(frame))
        markDirty(docId)
        return "已插入 \(cols)×\(rows) 表格 (id=\(nextId))"
    }

    private func updateCell(args: [String: Value]) throws -> String {
        let (docId, pres) = try requireSession(args: args)
        let idx = try validSlideIndex(args, in: pres)
        let shapeId = try requiredShapeId(args)
        let row = try requiredInt(args, "row")
        let col = try requiredInt(args, "col")
        guard let text = args["text"]?.stringValue else {
            throw PPTXError.invalidParameter("text", "需要 text")
        }

        guard let elIdx = findElement(in: openPresentations[docId]!.slides[idx], id: shapeId),
              case .graphicFrame(var frame) = openPresentations[docId]!.slides[idx].elements[elIdx] else {
            throw PPTXError.invalidParameter("shape_id", "找不到表格 id=\(shapeId)")
        }

        // The indices are checked here, against this table, so the error names
        // the parameter; a frame with no table (a chart, SmartArt, …) is not
        // a silent no-op.
        guard var table = frame.table else {
            throw PPTXError.invalidParameter("shape_id", "id=\(shapeId) 不是表格")
        }
        guard row >= 0, row < table.rows.count else {
            throw PPTXError.invalidParameter("row", "必須介於 0 與 \(table.rows.count - 1) 之間（收到 \(row)）")
        }
        guard col >= 0, col < table.rows[row].cells.count else {
            throw PPTXError.invalidParameter("col", "必須介於 0 與 \(table.rows[row].cells.count - 1) 之間（收到 \(col)）")
        }
        try table.updateCell(row: row, col: col, text: text)
        frame.table = table
        openPresentations[docId]?.slides[idx].elements[elIdx] = .graphicFrame(frame)
        markDirty(docId)
        return "已更新儲存格 (\(row),\(col))"
    }

    // MARK: - Slide Management

    private func addSlide(args: [String: Value]) throws -> String {
        let (docId, pres) = try requireSession(args: args)
        let slide = Slide()
        if let atIndex = try optionalInt(args, "at_index", in: 0...pres.slides.count) {
            openPresentations[docId]?.slides.insert(slide, at: atIndex)
        } else {
            openPresentations[docId]?.slides.append(slide)
        }
        markDirty(docId)
        let count = openPresentations[docId]?.slides.count ?? 0
        return "已新增投影片（共 \(count) 張）"
    }

    private func deleteSlide(args: [String: Value]) throws -> String {
        let (docId, pres) = try requireSession(args: args)
        let idx = try validSlideIndex(args, in: pres)
        try openPresentations[docId]?.deleteSlide(at: idx)
        markDirty(docId)
        return "已刪除投影片 \(idx)"
    }

    private func reorderSlides(args: [String: Value]) throws -> String {
        let (docId, pres) = try requireSession(args: args)
        let from = try requiredIndex(args, "from_index", count: pres.slides.count)
        let to = try requiredIndex(args, "to_index", count: pres.slides.count)
        try openPresentations[docId]?.reorderSlide(from: from, to: to)
        markDirty(docId)
        return "已將投影片從位置 \(from) 移到 \(to)"
    }

    private func duplicateSlide(args: [String: Value]) throws -> String {
        let (docId, pres) = try requireSession(args: args)
        let idx = try validSlideIndex(args, in: pres)
        let newIdx = try openPresentations[docId]!.duplicateSlide(at: idx)
        markDirty(docId)
        return "已複製投影片 \(idx) → \(newIdx)"
    }

    // MARK: - Shape Editing

    private func insertTextShape(args: [String: Value]) throws -> String {
        let (docId, pres) = try requireSession(args: args)
        let idx = try validSlideIndex(args, in: pres)
        guard let text = args["text"]?.stringValue else {
            throw PPTXError.invalidParameter("text", "需要 text")
        }

        let x = try coordinateEmu(args, "x", default: 457200)
        let y = try coordinateEmu(args, "y", default: 1600200)
        let w = try extentEmu(args, "width", default: 8229600)
        let h = try extentEmu(args, "height", default: 1143000)

        let nextId = try nextElementId(in: openPresentations[docId]!.slides[idx])

        let shape = Shape(
            id: nextId, name: "TextBox \(nextId)",
            geometry: .rect,
            position: Position(x: x, y: y),
            size: Size(width: w, height: h),
            textBody: TextBody(paragraphs: [TextParagraph(text: text)])
        )
        openPresentations[docId]?.slides[idx].elements.append(.shape(shape))
        markDirty(docId)
        return "已插入文字框 id=\(nextId)"
    }

    private func updateShapeText(args: [String: Value]) throws -> String {
        let (docId, pres) = try requireSession(args: args)
        let idx = try validSlideIndex(args, in: pres)
        let shapeId = try requiredShapeId(args)
        guard let text = args["text"]?.stringValue else {
            throw PPTXError.invalidParameter("text", "需要 text")
        }

        guard let (elIdx, foundShape) = findShape(in: openPresentations[docId]!.slides[idx], id: shapeId) else {
            throw PPTXError.invalidParameter("shape_id", "找不到 id=\(shapeId)")
        }
        var shape = foundShape
        shape.textBody = TextBody(paragraphs: [TextParagraph(text: text)])
        openPresentations[docId]?.slides[idx].elements[elIdx] = .shape(shape)
        markDirty(docId)
        return "已更新形狀 id=\(shapeId) 的文字"
    }

    private func deleteShape(args: [String: Value]) throws -> String {
        let (docId, pres) = try requireSession(args: args)
        let idx = try validSlideIndex(args, in: pres)
        let shapeId = try requiredShapeId(args)
        guard let elIdx = findElement(in: openPresentations[docId]!.slides[idx], id: shapeId) else {
            throw PPTXError.invalidParameter("shape_id", "找不到 id=\(shapeId)")
        }
        openPresentations[docId]?.slides[idx].elements.remove(at: elIdx)
        markDirty(docId)
        return "已刪除形狀 id=\(shapeId)"
    }

    private func setShapePosition(args: [String: Value]) throws -> String {
        let (docId, pres) = try requireSession(args: args)
        let idx = try validSlideIndex(args, in: pres)
        let shapeId = try requiredShapeId(args)
        let x = try requiredInt(args, "x", in: PPTXMetric.coordinateRangeEmu)
        let y = try requiredInt(args, "y", in: PPTXMetric.coordinateRangeEmu)
        guard let (elIdx, foundShape) = findShape(in: openPresentations[docId]!.slides[idx], id: shapeId) else {
            throw PPTXError.invalidParameter("shape_id", "找不到 id=\(shapeId)")
        }
        var shape = foundShape
        shape.position = Position(x: x, y: y)
        openPresentations[docId]?.slides[idx].elements[elIdx] = .shape(shape)
        markDirty(docId)
        return "已設定位置 (\(x), \(y))"
    }

    private func setShapeSize(args: [String: Value]) throws -> String {
        let (docId, pres) = try requireSession(args: args)
        let idx = try validSlideIndex(args, in: pres)
        let shapeId = try requiredShapeId(args)
        let w = try requiredInt(args, "width", in: Self.extentRangeEmu)
        let h = try requiredInt(args, "height", in: Self.extentRangeEmu)
        guard let (elIdx, foundShape) = findShape(in: openPresentations[docId]!.slides[idx], id: shapeId) else {
            throw PPTXError.invalidParameter("shape_id", "找不到 id=\(shapeId)")
        }
        var shape = foundShape
        shape.size = Size(width: w, height: h)
        openPresentations[docId]?.slides[idx].elements[elIdx] = .shape(shape)
        markDirty(docId)
        return "已設定大小 (\(w)×\(h))"
    }

    private func setShapeFill(args: [String: Value]) throws -> String {
        let (docId, pres) = try requireSession(args: args)
        let idx = try validSlideIndex(args, in: pres)
        let shapeId = try requiredShapeId(args)
        guard let color = args["color"]?.stringValue else {
            throw PPTXError.invalidParameter("color", "需要 color")
        }
        guard let (elIdx, foundShape) = findShape(in: openPresentations[docId]!.slides[idx], id: shapeId) else {
            throw PPTXError.invalidParameter("shape_id", "找不到 id=\(shapeId)")
        }
        var shape = foundShape
        shape.fill = .solid(color: color)
        openPresentations[docId]?.slides[idx].elements[elIdx] = .shape(shape)
        markDirty(docId)
        return "已設定填色 #\(color)"
    }

    // MARK: - Geometry (cm)
    //
    // PsychQuant/macdoc#90 (Spectra change `pptx-geometry-tools`): lengths are
    // centimeters (Double) at the tool boundary and EMU internally; conversion,
    // validation, group rejection and aspect fitting live in PPTXSwift's
    // Geometry module. Responses are JSON carrying cm (2-decimal) + EMU.
    //
    // Each handler computes and validates everything that can fail — parameter
    // types, geometry, derived sizes, the response itself — before it writes
    // to the session and marks it dirty, so a rejected call leaves the
    // document byte-for-byte as it was.

    private func setPlaceholderGeometry(args: [String: Value]) throws -> String {
        let (docId, pres) = try requireSession(args: args)
        let idx = try validSlideIndex(args, in: pres)
        let shapeId = try requiredShapeId(args)
        let x = try requiredCm(args, "x_cm")
        let y = try requiredCm(args, "y_cm")
        let w = try requiredCm(args, "width_cm")
        let h = try requiredCm(args, "height_cm")

        var slide = pres.slides[idx]
        try slide.setGeometry(ofElementId: shapeId, xCm: x, yCm: y, widthCm: w, heightCm: h)
        guard let (position, size) = topLevelGeometry(of: shapeId, in: slide) else {
            throw PPTXError.invalidParameter("shape_id", "找不到形狀 id=\(shapeId)")
        }
        let response = geometryResponse(
            [("shape_id", "\(shapeId)"), ("slide_index", "\(idx)")],
            position: position, size: size, slideSize: pres.slideSize
        )

        openPresentations[docId]?.slides[idx] = slide
        markDirty(docId)
        return response
    }

    private func placePictureAt(args: [String: Value]) throws -> String {
        let (docId, pres) = try requireSession(args: args)
        let idx = try validSlideIndex(args, in: pres)
        let x = try requiredCm(args, "x_cm")
        let y = try requiredCm(args, "y_cm")
        let w = try requiredCm(args, "width_cm")
        let explicitHeight = try optionalCm(args, "height_cm")
        // Validate the rectangle before touching the image or the document;
        // a derived height is stood in by 1 cm until it is known.
        let validated = try PPTXMetric.geometry(xCm: x, yCm: y, widthCm: w, heightCm: explicitHeight ?? 1)
        let source = try pictureSource(args)

        var size = validated.size
        var nativePixels: (width: Int, height: Int)?
        if explicitHeight == nil {
            let pixels: (width: Int, height: Int)
            do {
                pixels = try NativeAspect.pixelDimensions(of: source.data)
            } catch {
                throw PPTXError.invalidParameter(
                    "height_cm",
                    "無法從圖片讀出原生像素比例，請明確提供 height_cm（\(error.localizedDescription)）"
                )
            }
            size = try NativeAspect.fittedSize(keeping: .width, of: validated.size,
                                               pixelWidth: pixels.width, pixelHeight: pixels.height)
            nativePixels = pixels
        }

        let fileName = uniqueMediaFileName(source.fileName, in: pres)
        let shapeId = try nextElementId(in: pres.slides[idx])

        var fields: [(String, String)] = [
            ("shape_id", "\(shapeId)"),
            ("slide_index", "\(idx)"),
            ("media_file", jsonString(fileName)),
            ("height_source", jsonString(explicitHeight == nil ? "native_aspect" : "explicit")),
        ]
        if let nativePixels {
            fields.append(("native_pixels", "{\"width\":\(nativePixels.width),\"height\":\(nativePixels.height)}"))
        }
        let response = geometryResponse(fields, position: validated.position, size: size, slideSize: pres.slideSize)

        appendPicture(docId: docId, slideIndex: idx, id: shapeId, data: source.data, fileName: fileName,
                      position: validated.position, size: size)
        return response
    }

    private func fitPictureToNativeAspect(args: [String: Value]) throws -> String {
        let (docId, pres) = try requireSession(args: args)
        let idx = try validSlideIndex(args, in: pres)
        let shapeId = try requiredShapeId(args)
        guard let anchorName = try optionalString(args, "anchor"),
              let anchor = AspectAnchor(rawValue: anchorName) else {
            throw PPTXError.invalidParameter("anchor", "必須是 width 或 height")
        }

        let slide = pres.slides[idx]
        let elementIndex: Int
        switch slide.locateElement(id: shapeId) {
        case .notFound:
            throw PPTXError.invalidParameter("shape_id", "找不到形狀 id=\(shapeId)")
        case .groupChild:
            throw PPTXError.groupGeometryUnsupported(shapeId: shapeId)
        case .topLevel(let index):
            elementIndex = index
        }
        guard case .picture(let picture) = slide.elements[elementIndex] else {
            if case .group = slide.elements[elementIndex] {
                throw PPTXError.groupGeometryUnsupported(shapeId: shapeId)
            }
            throw PPTXError.invalidParameter(
                "shape_id", "形狀 id=\(shapeId) 不是圖片；fit_picture_to_native_aspect 只適用於圖片"
            )
        }
        guard let media = pres.mediaFile(for: picture) else {
            throw PPTXError.invalidParameter(
                "shape_id", "圖片 id=\(shapeId) 找不到嵌入的 media（r:embed=\(picture.imageRelationshipId)）"
            )
        }

        // The existing transform must already be valid and non-degenerate:
        // fit keeps the offset and one side, and reports both. A zero extent
        // is rejected on either side, anchored or not — a picture with no
        // width or height has no aspect to fit to.
        let range = PPTXMetric.coordinateRangeEmu
        let extents = 1...PPTXMetric.maxCoordinateEmu
        guard range.contains(picture.position.x), range.contains(picture.position.y),
              extents.contains(picture.size.width), extents.contains(picture.size.height) else {
            throw PPTXError.invalidParameter(
                "shape_id",
                "圖片 id=\(shapeId) 目前的位置超出 OOXML 座標範圍或大小不為正（pos=(\(picture.position.x),\(picture.position.y)) "
                    + "size=(\(picture.size.width)×\(picture.size.height))），請先以 set_placeholder_geometry 重設"
            )
        }

        let pixels: (width: Int, height: Int)
        do {
            pixels = try NativeAspect.pixelDimensions(of: media.data)
        } catch PPTXError.undecodableImage(let detail) {
            throw PPTXError.undecodableImage("media '\(media.fileName)'：\(detail)")
        }
        // pptx-swift#2：比例以 srcRect 裁切後的可見區域為準。
        let fitted = try NativeAspect.fittedSize(keeping: anchor, of: picture.size,
                                                 pixelWidth: pixels.width, pixelHeight: pixels.height,
                                                 crop: picture.sourceRect)
        let response = geometryResponse(
            [("shape_id", "\(shapeId)"),
             ("slide_index", "\(idx)"),
             ("anchor", jsonString(anchor.rawValue)),
             ("native_pixels", "{\"width\":\(pixels.width),\"height\":\(pixels.height)}")],
            position: picture.position, size: fitted, slideSize: pres.slideSize
        )

        var fittedPicture = picture
        fittedPicture.size = fitted
        openPresentations[docId]?.slides[idx].elements[elementIndex] = .picture(fittedPicture)
        markDirty(docId)
        return response
    }

    // MARK: Geometry helpers

    // Parameter parsing for the geometry tools is strict: a value is taken
    // only from the JSON type the schema declares, never coerced from another
    // (a string "10" is not a number). An absent key and an explicit JSON
    // null both mean "not given".

    private func validSlideIndex(_ args: [String: Value], in pres: Presentation) throws -> Int {
        try requiredIndex(args, "slide_index", count: pres.slides.count)
    }

    private func requiredShapeId(_ args: [String: Value]) throws -> Int {
        try requiredInt(args, "shape_id")
    }

    // MARK: Integer parameters (#5)
    //
    // Every integer parameter of every tool goes through `optionalInt`: a
    // JSON integer, or a double that is finite, integral and inside `Int`
    // (`Int(exactly:)` — NaN, ±Infinity, 0.5 and 2^63 all fail it). Strings,
    // booleans and other JSON types are rejected, never coerced. A value that
    // fails any check is a `PPTXError.invalidParameter` naming the key, which
    // `handleToolCall` returns as an `isError` result — no conversion here can
    // trap. There is deliberately no `Value.intValue`-style shortcut.

    /// Upper bound on `insert_table` columns and rows — a resource guard
    /// against allocating an unbounded table, not a PowerPoint limit.
    static let maxTableDimension = 1000
    static let tableDimensionRange = 1...maxTableDimension

    /// `ST_PositiveCoordinate`: widths and heights in EMU.
    static let extentRangeEmu = 0...PPTXMetric.maxCoordinateEmu

    /// The value under `key`, or nil when it is absent or JSON null.
    private func optionalInt(_ args: [String: Value], _ key: String) throws -> Int? {
        switch args[key] {
        case nil, .null?:
            return nil
        case .int(let value)?:
            return value
        case .double(let value)?:
            guard let exact = Int(exactly: value) else {
                throw PPTXError.invalidParameter(key, "必須是整數（收到 \(value)）")
            }
            return exact
        case let other?:
            throw PPTXError.invalidParameter(key, "必須是整數，不接受 \(jsonTypeName(other))")
        }
    }

    private func optionalInt(_ args: [String: Value], _ key: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let value = try optionalInt(args, key) else { return nil }
        guard range.contains(value) else {
            throw PPTXError.invalidParameter(
                key, "必須介於 \(range.lowerBound) 與 \(range.upperBound) 之間（收到 \(value)）"
            )
        }
        return value
    }

    /// A JSON integer, or a finite integral double that fits `Int`.
    private func requiredInt(_ args: [String: Value], _ key: String) throws -> Int {
        guard let value = try optionalInt(args, key) else {
            throw PPTXError.invalidParameter(key, "需要 \(key)")
        }
        return value
    }

    private func requiredInt(_ args: [String: Value], _ key: String, in range: ClosedRange<Int>) throws -> Int {
        guard let value = try optionalInt(args, key, in: range) else {
            throw PPTXError.invalidParameter(key, "需要 \(key)")
        }
        return value
    }

    /// A required index into a collection of `count` items (`0 ..< count`).
    /// Checked without forming a range, so an empty collection is an error
    /// rather than an invalid `ClosedRange`.
    private func requiredIndex(_ args: [String: Value], _ key: String, count: Int) throws -> Int {
        let value = try requiredInt(args, key)
        guard value >= 0, value < count else {
            throw PPTXError.invalidParameter(
                key, count == 0 ? "簡報沒有投影片（收到 \(value)）" : "必須介於 0 與 \(count - 1) 之間（收到 \(value)）"
            )
        }
        return value
    }

    // MARK: Boolean parameters (#10)
    //
    // Every boolean tool parameter goes through `optionalBool`: only the
    // JSON literals `true`/`false` are accepted, mirroring the integer rule
    // from #5. Strings ("true", "false", "1", ...), numbers and other JSON
    // types are rejected, never coerced — the old `Value.boolValue` used to
    // accept the string "true" (and, as an unintended side effect, coerce
    // every OTHER string, including "false", to `false` instead of
    // rejecting it). A value that fails is a `PPTXError.invalidParameter`
    // naming the key, which `handleToolCall` returns as an `isError` result.

    /// The value under `key`, or nil when it is absent or JSON null.
    ///
    /// Null is deliberately treated the same as "absent" here, exactly like
    /// `optionalInt` above — this is what "與整數相同的嚴格 JSON 型別規則"
    /// (#10) means in practice: an *optional* parameter's contract is "a
    /// present value must be the right JSON type or it's an error", not
    /// "null is also an error". `IntegerParameterTests`'s own
    /// `Missing or null integers follow the schema's required list` test
    /// pins this for integers; `BooleanParameterTests` pins the same rule
    /// for booleans. Only a *required* parameter's null/absence is an error
    /// (see `requiredInt`) — there is deliberately no `requiredBool`
    /// sibling: every boolean parameter in the current tool schemas
    /// (`autosave` on `create_presentation` / `open_presentation`) is
    /// optional with a `false` default, and an untested helper with no call
    /// site is dead code — add `requiredBool` alongside its own test when a
    /// tool needs one.
    private func optionalBool(_ args: [String: Value], _ key: String) throws -> Bool? {
        switch args[key] {
        case nil, .null?:
            return nil
        case .bool(let value)?:
            return value
        case let other?:
            throw PPTXError.invalidParameter(key, "必須是布林值 true/false，不接受 \(jsonTypeName(other))")
        }
    }

    /// An optional EMU position (`ST_Coordinate`), `fallback` when absent.
    private func coordinateEmu(_ args: [String: Value], _ key: String, default fallback: Int) throws -> Int {
        try optionalInt(args, key, in: PPTXMetric.coordinateRangeEmu) ?? fallback
    }

    /// An optional EMU width or height (`ST_PositiveCoordinate`), `fallback` when absent.
    private func extentEmu(_ args: [String: Value], _ key: String, default fallback: Int) throws -> Int {
        try optionalInt(args, key, in: Self.extentRangeEmu) ?? fallback
    }

    private func requiredCm(_ args: [String: Value], _ key: String) throws -> Double {
        guard let value = try optionalCm(args, key) else {
            throw PPTXError.invalidParameter(key, "需要 \(key)（公分）")
        }
        return value
    }

    /// A JSON number (integer or double). Finiteness and range are checked by
    /// PPTXSwift's geometry validation.
    private func optionalCm(_ args: [String: Value], _ key: String) throws -> Double? {
        switch args[key] {
        case nil, .null?:
            return nil
        case .int(let value)?:
            return Double(value)
        case .double(let value)?:
            return value
        case let other?:
            throw PPTXError.invalidParameter(key, "必須是數值（公分），不接受 \(jsonTypeName(other))")
        }
    }

    private func optionalString(_ args: [String: Value], _ key: String) throws -> String? {
        switch args[key] {
        case nil, .null?:
            return nil
        case .string(let value)?:
            return value
        case let other?:
            throw PPTXError.invalidParameter(key, "必須是字串，不接受 \(jsonTypeName(other))")
        }
    }

    private func jsonTypeName(_ value: Value) -> String {
        switch value {
        case .null: return "null"
        case .bool: return "布林值"
        case .int, .double: return "數值"
        case .string: return "字串"
        case .data: return "二進位資料"
        case .array: return "陣列"
        case .object: return "物件"
        }
    }

    /// Exactly one of `image_path` / `image_base64` (each must be a string
    /// when given), with a media file name for it.
    private func pictureSource(_ args: [String: Value]) throws -> (data: Data, fileName: String) {
        let path = try optionalString(args, "image_path")
        let base64 = try optionalString(args, "image_base64")
        switch (path, base64) {
        case (let path?, nil):
            guard FileManager.default.fileExists(atPath: path) else { throw PPTXError.fileNotFound(path) }
            let url = URL(fileURLWithPath: path)
            return (try Data(contentsOf: url), url.lastPathComponent)
        case (nil, let base64?):
            guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), !data.isEmpty else {
                throw PPTXError.invalidParameter("image_base64", "無效的 base64 圖片資料")
            }
            return (data, "image.\(imageFileExtension(of: data))")
        case (nil, nil):
            throw PPTXError.invalidParameter("image_path/image_base64", "需要 image_path 或 image_base64（擇一）")
        case (.some, .some):
            throw PPTXError.invalidParameter("image_path/image_base64", "image_path 與 image_base64 只能擇一")
        }
    }

    private func imageFileExtension(of data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              let ext = UTType(type)?.preferredFilenameExtension else { return "bin" }
        return ext
    }

    /// Media parts are matched to pictures by file name, so a new picture must
    /// never reuse an existing name (it would also overwrite ppt/media/ on save).
    private func uniqueMediaFileName(_ preferred: String, in pres: Presentation) -> String {
        let existing = Set(pres.images.map(\.fileName))
        guard existing.contains(preferred) else { return preferred }
        let base = (preferred as NSString).deletingPathExtension
        let ext = (preferred as NSString).pathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            if !existing.contains(candidate) { return candidate }
            n += 1
        }
    }

    private func topLevelGeometry(of id: Int, in slide: Slide) -> (Position, Size)? {
        guard case .topLevel(let index) = slide.locateElement(id: id) else { return nil }
        switch slide.elements[index] {
        case .shape(let s): return (s.position, s.size)
        case .picture(let p): return (p.position, p.size)
        case .graphicFrame(let f): return (f.position, f.size)
        case .group: return nil
        }
    }

    /// `pos_cm=(x,y) size_cm=(w×h)` for listings, 2-decimal centimeters.
    private func cmSummary(_ position: Position, _ size: Size) -> String {
        String(format: "pos_cm=(%.2f,%.2f) size_cm=(%.2f×%.2f)",
               position.xCm, position.yCm, size.widthCm, size.heightCm)
    }

    /// JSON object: the given fields, then `geometry` (cm + EMU), then
    /// `warnings` only when the rectangle leaves the slide.
    private func geometryResponse(_ fields: [(String, String)], position: Position, size: Size,
                                  slideSize: SlideSize) -> String {
        var parts = fields.map { "\"\($0.0)\":\($0.1)" }
        let cm = String(format: "{\"x\":%.2f,\"y\":%.2f,\"width\":%.2f,\"height\":%.2f}",
                        position.xCm, position.yCm, size.widthCm, size.heightCm)
        let emu = "{\"x\":\(position.x),\"y\":\(position.y),\"width\":\(size.width),\"height\":\(size.height)}"
        parts.append("\"geometry\":{\"cm\":\(cm),\"emu\":\(emu)}")

        let warnings = slideBoundWarnings(position, size, slideSize: slideSize)
        if !warnings.isEmpty {
            let items = warnings.map { "{\"bound\":\(jsonString($0.bound)),\"message\":\(jsonString($0.message))}" }
            parts.append("\"warnings\":[\(items.joined(separator: ","))]")
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    /// Off-slide placement is legal (PowerPoint allows bleed), so it warns
    /// rather than fails; each exceeded edge is named.
    private func slideBoundWarnings(_ position: Position, _ size: Size,
                                    slideSize: SlideSize) -> [(bound: String, message: String)] {
        var warnings: [(bound: String, message: String)] = []
        if position.x < 0 {
            warnings.append(("left", String(format: "超出投影片左緣：x = %.2f cm < 0", position.xCm)))
        }
        if position.y < 0 {
            warnings.append(("top", String(format: "超出投影片上緣：y = %.2f cm < 0", position.yCm)))
        }
        // Compared in Double: exact within the OOXML range and cannot overflow
        // whatever the stored values are.
        if Double(position.x) + Double(size.width) > Double(slideSize.width) {
            warnings.append(("right", String(format: "超出投影片右緣：x + width = %.2f cm > 投影片寬度 %.2f cm",
                                             position.xCm + size.widthCm, slideSize.widthCm)))
        }
        if Double(position.y) + Double(size.height) > Double(slideSize.height) {
            warnings.append(("bottom", String(format: "超出投影片下緣：y + height = %.2f cm > 投影片高度 %.2f cm",
                                              position.yCm + size.heightCm, slideSize.heightCm)))
        }
        return warnings
    }

    private func jsonString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: - Notes & Transition

    private func addNotes(args: [String: Value]) throws -> String {
        let (docId, pres) = try requireSession(args: args)
        let idx = try validSlideIndex(args, in: pres)
        guard let text = args["text"]?.stringValue else {
            throw PPTXError.invalidParameter("text", "需要 text")
        }
        openPresentations[docId]?.slides[idx].notes = text
        markDirty(docId)
        return "已設定備忘稿"
    }

    private func setTransition(args: [String: Value]) throws -> String {
        let (docId, pres) = try requireSession(args: args)
        let idx = try validSlideIndex(args, in: pres)
        guard let typeStr = args["type"]?.stringValue else {
            throw PPTXError.invalidParameter("type", "需要 type")
        }
        let speed = TransitionSpeed(rawValue: args["speed"]?.stringValue ?? "med") ?? .medium
        let type = TransitionType(rawValue: typeStr) ?? .unknown
        openPresentations[docId]?.slides[idx].transition = SlideTransition(type: type, speed: speed)
        markDirty(docId)
        return "已設定轉場: \(typeStr)"
    }

    // MARK: - Search & Export

    private func searchText(args: [String: Value]) throws -> String {
        let (pres, _) = try resolvePresentation(args: args)
        guard let query = args["query"]?.stringValue else {
            throw PPTXError.invalidParameter("query", "需要 query")
        }
        let lowerQuery = query.lowercased()

        var results: [String] = []
        for (si, slide) in pres.slides.enumerated() {
            for element in slide.elements {
                if case .shape(let shape) = element {
                    let text = shape.textBody?.getText() ?? ""
                    if text.lowercased().contains(lowerQuery) {
                        let context = text.prefix(100)
                        results.append("Slide \(si), Shape id=\(shape.id) \"\(shape.name)\": \"\(context)\"")
                    }
                }
            }
        }
        return results.isEmpty ? "No matches found" : results.joined(separator: "\n")
    }

    private func exportMarkdown(args: [String: Value]) throws -> String {
        let (pres, _) = try resolvePresentation(args: args)

        var md = ""
        for (si, slide) in pres.slides.enumerated() {
            if si > 0 { md += "\n---\n\n" }

            // Title placeholder → heading
            for element in slide.elements {
                if case .shape(let shape) = element {
                    let text = shape.textBody?.getText() ?? ""
                    guard !text.isEmpty else { continue }

                    if shape.placeholder == .title || shape.placeholder == .centerTitle {
                        md += "# \(text)\n\n"
                    } else if shape.placeholder == .subtitle {
                        md += "## \(text)\n\n"
                    } else {
                        md += "\(text)\n\n"
                    }
                }
            }

            // Tables
            for frame in slide.tables {
                if let table = frame.table {
                    for (ri, row) in table.rows.enumerated() {
                        let cells = row.cells.map { $0.getText() }
                        md += "| \(cells.joined(separator: " | ")) |\n"
                        if ri == 0 {
                            md += "| \(cells.map { _ in "---" }.joined(separator: " | ")) |\n"
                        }
                    }
                    md += "\n"
                }
            }

            // Notes
            if let notes = slide.notes, !notes.isEmpty {
                md += "> **Notes:** \(notes)\n\n"
            }
        }
        return md
    }

    // MARK: - Theme

    private func getTheme(args: [String: Value]) throws -> String {
        let (pres, _) = try resolvePresentation(args: args)
        guard let theme = pres.theme else { return "No theme" }

        var lines = ["Theme: \(theme.name)", "", "Color Scheme: \(theme.colorScheme.name)"]
        for (name, hex) in theme.colorScheme.allColors {
            lines.append("  \(name): #\(hex)")
        }
        lines.append("")
        lines.append("Font Scheme: \(theme.fontScheme.name)")
        lines.append("  Major (headings): \(theme.fontScheme.majorFont)")
        lines.append("  Minor (body): \(theme.fontScheme.minorFont)")
        return lines.joined(separator: "\n")
    }

    private func getSlideMaster(args: [String: Value]) throws -> String {
        let (pres, _) = try resolvePresentation(args: args)
        if pres.slideMasters.isEmpty { return "No slide masters" }
        return pres.slideMasters.map { master in
            let phs = master.placeholders.map { "\($0.type.rawValue)" }.joined(separator: ", ")
            return "Master id=\(master.id) placeholders=[\(phs)]"
        }.joined(separator: "\n")
    }

    private func getSlideLayouts(args: [String: Value]) throws -> String {
        let (pres, _) = try resolvePresentation(args: args)
        if pres.slideLayouts.isEmpty { return "No slide layouts" }
        return pres.slideLayouts.map { layout in
            let phs = layout.placeholders.map { "\($0.type.rawValue)" }.joined(separator: ", ")
            return "Layout id=\(layout.id) name=\"\(layout.name)\" type=\(layout.type ?? "n/a") placeholders=[\(phs)]"
        }.joined(separator: "\n")
    }
}

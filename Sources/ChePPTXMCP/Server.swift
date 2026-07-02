import Foundation
import MCP
import PPTXSwift

/// PowerPoint MCP Server
class PPTXMCPServer {
    /// Single source of truth for the server's self-reported version.
    /// MUST equal the release tag (scripts/release.sh enforces this — #1,
    /// aligned with che-pdf-mcp#3 convention). Bump when releasing.
    static let serverVersion = "0.1.0"

    private let server: Server
    private let transport: StdioTransport

    /// 目前開啟的簡報 (doc_id -> Presentation)
    private var openPresentations: [String: Presentation] = [:]
    private var originalPaths: [String: String] = [:]
    private var dirtyState: [String: Bool] = [:]
    private var autosaveState: [String: Bool] = [:]

    // MARK: - Server Instructions

    private static let serverInstructions = """
    # che-pptx-mcp — PowerPoint MCP Server

    Swift-native OOXML server for .pptx manipulation. ~45 tools.

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

    private func initializeSession(docId: String, presentation: Presentation, sourcePath: String?, autosave: Bool) {
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

    private func markDirty(_ docId: String) {
        dirtyState[docId] = true
        if autosaveState[docId] == true, let path = originalPaths[docId] {
            try? PptxWriter.write(openPresentations[docId]!, to: URL(fileURLWithPath: path))
            dirtyState[docId] = false
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

    private func handleToolCall(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        let name = params.name
        let args = params.arguments ?? [:]

        do {
            let result = try executeToolTask(name: name, args: args)
            return CallTool.Result(content: [.text(result)])
        } catch {
            return CallTool.Result(content: [.text("Error: \(error.localizedDescription)")], isError: true)
        }
    }

    // MARK: - Tool Dispatch

    private func executeToolTask(name: String, args: [String: Value]) throws -> String {
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

    private var allTools: [Tool] {
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
                 required: ["doc_id", "slide_index", "base64", "file_name", "x", "y", "width", "height"],
                 props: ["doc_id": prop(.string, "簡報識別碼"),
                         "slide_index": prop(.integer, "投影片索引"),
                         "base64": prop(.string, "Base64 圖片資料"),
                         "file_name": prop(.string, "檔名"),
                         "x": prop(.integer, "X 位置 (EMU)"), "y": prop(.integer, "Y 位置 (EMU)"),
                         "width": prop(.integer, "寬度 (EMU)"), "height": prop(.integer, "高度 (EMU)")]),
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
                 required: ["doc_id", "slide_index", "text", "x", "y", "width", "height"],
                 props: ["doc_id": prop(.string, "簡報識別碼"),
                         "slide_index": prop(.integer, "投影片索引"),
                         "text": prop(.string, "文字內容"),
                         "x": prop(.integer, "X (EMU)"), "y": prop(.integer, "Y (EMU)"),
                         "width": prop(.integer, "寬度 (EMU)"), "height": prop(.integer, "高度 (EMU)")]),
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

    private func slideIndex(_ args: [String: Value]) throws -> Int {
        guard let idx = args["slide_index"]?.intValue else {
            throw PPTXError.invalidParameter("slide_index", "需要 slide_index")
        }
        return idx
    }

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

    private func createPresentation(args: [String: Value]) throws -> String {
        guard let docId = args["doc_id"]?.stringValue else {
            throw PPTXError.invalidParameter("doc_id", "需要 doc_id")
        }
        let autosave = args["autosave"]?.boolValue ?? false
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
        let autosave = args["autosave"]?.boolValue ?? false

        let presentation = try PptxReader.read(from: URL(fileURLWithPath: path))
        initializeSession(docId: docId, presentation: presentation, sourcePath: path, autosave: autosave)
        return "已開啟簡報: \(docId)（\(presentation.slideCount) 張投影片）"
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
        let idx = try slideIndex(args)
        guard idx >= 0 && idx < pres.slides.count else {
            throw PPTXError.invalidIndex(idx)
        }
        return pres.slides[idx].getText()
    }

    private func getSlideShapes(args: [String: Value]) throws -> String {
        let (pres, _) = try resolvePresentation(args: args)
        let idx = try slideIndex(args)
        guard idx >= 0 && idx < pres.slides.count else {
            throw PPTXError.invalidIndex(idx)
        }

        var lines: [String] = []
        for element in pres.slides[idx].elements {
            switch element {
            case .shape(let s):
                let phStr = s.placeholder.map { " [placeholder:\($0.rawValue)]" } ?? ""
                let text = s.textBody?.getText().prefix(50) ?? ""
                lines.append("Shape id=\(s.id) name=\"\(s.name)\"\(phStr) pos=(\(s.position.x),\(s.position.y)) size=(\(s.size.width)×\(s.size.height)) text=\"\(text)\"")
            case .picture(let p):
                lines.append("Picture id=\(p.id) name=\"\(p.name)\" embed=\(p.imageRelationshipId) size=(\(p.size.width)×\(p.size.height))")
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
        let idx = try slideIndex(args)
        guard idx >= 0 && idx < pres.slides.count else {
            throw PPTXError.invalidIndex(idx)
        }
        guard let shapeId = args["shape_id"]?.intValue else {
            throw PPTXError.invalidParameter("shape_id", "需要 shape_id")
        }
        guard let (_, shape) = findShape(in: pres.slides[idx], id: shapeId) else {
            throw PPTXError.invalidParameter("shape_id", "找不到形狀 id=\(shapeId)")
        }
        return shape.textBody?.getText() ?? "(no text)"
    }

    private func getSlideNotes(args: [String: Value]) throws -> String {
        let (pres, _) = try resolvePresentation(args: args)
        let idx = try slideIndex(args)
        guard idx >= 0 && idx < pres.slides.count else {
            throw PPTXError.invalidIndex(idx)
        }
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
        let (docId, _) = try requireSession(args: args)
        let idx = try slideIndex(args)
        guard idx >= 0 && idx < (openPresentations[docId]?.slides.count ?? 0) else {
            throw PPTXError.invalidIndex(idx)
        }
        guard let base64 = args["base64"]?.stringValue,
              let fileName = args["file_name"]?.stringValue,
              let data = Data(base64Encoded: base64) else {
            throw PPTXError.invalidParameter("base64", "Invalid base64 data")
        }

        let x = args["x"]?.intValue ?? 0
        let y = args["y"]?.intValue ?? 0
        let w = args["width"]?.intValue ?? 3048000
        let h = args["height"]?.intValue ?? 2286000

        let nextId = (openPresentations[docId]?.slides[idx].elements.compactMap { el -> Int? in
            switch el {
            case .shape(let s): return s.id
            case .picture(let p): return p.id
            case .graphicFrame(let f): return f.id
            case .group(let g): return g.id
            }
        }.max() ?? 1) + 1

        let rId = "rId\(nextId)"
        let picture = Picture(id: nextId, name: fileName, position: Position(x: x, y: y),
                              size: Size(width: w, height: h), imageRelationshipId: rId)
        openPresentations[docId]?.slides[idx].elements.append(.picture(picture))
        openPresentations[docId]?.images.append(MediaFile(id: fileName, fileName: fileName, data: data))
        markDirty(docId)
        return "已插入圖片: \(fileName) (id=\(nextId))"
    }

    private func deleteImage(args: [String: Value]) throws -> String {
        let (docId, _) = try requireSession(args: args)
        let idx = try slideIndex(args)
        guard let shapeId = args["shape_id"]?.intValue else {
            throw PPTXError.invalidParameter("shape_id", "需要 shape_id")
        }
        guard let elIdx = findElement(in: openPresentations[docId]!.slides[idx], id: shapeId) else {
            throw PPTXError.invalidParameter("shape_id", "找不到 id=\(shapeId)")
        }
        openPresentations[docId]?.slides[idx].elements.remove(at: elIdx)
        markDirty(docId)
        return "已刪除圖片 id=\(shapeId)"
    }

    // MARK: - Table Tools

    private func getTables(args: [String: Value]) throws -> String {
        let (pres, _) = try resolvePresentation(args: args)
        let idx = try slideIndex(args)
        guard idx >= 0 && idx < pres.slides.count else { throw PPTXError.invalidIndex(idx) }

        let tables = pres.slides[idx].tables
        if tables.isEmpty { return "No tables on this slide" }
        return tables.map { f in
            "GraphicFrame id=\(f.id) table \(f.table!.columnCount)×\(f.table!.rowCount)"
        }.joined(separator: "\n")
    }

    private func getTableData(args: [String: Value]) throws -> String {
        let (pres, _) = try resolvePresentation(args: args)
        let idx = try slideIndex(args)
        guard idx >= 0 && idx < pres.slides.count else { throw PPTXError.invalidIndex(idx) }
        guard let shapeId = args["shape_id"]?.intValue else {
            throw PPTXError.invalidParameter("shape_id", "需要 shape_id")
        }

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
        let (docId, _) = try requireSession(args: args)
        let idx = try slideIndex(args)
        guard idx >= 0 && idx < (openPresentations[docId]?.slides.count ?? 0) else {
            throw PPTXError.invalidIndex(idx)
        }
        guard let cols = args["columns"]?.intValue, let rows = args["rows"]?.intValue else {
            throw PPTXError.invalidParameter("columns/rows", "需要 columns 和 rows")
        }

        let x = args["x"]?.intValue ?? 457200
        let y = args["y"]?.intValue ?? 1600200
        let w = args["width"]?.intValue ?? 8229600
        let h = args["height"]?.intValue ?? 3657600

        let colWidth = w / cols
        let rowHeight = h / rows

        let nextId = (openPresentations[docId]?.slides[idx].elements.compactMap { el -> Int? in
            switch el {
            case .shape(let s): return s.id
            case .picture(let p): return p.id
            case .graphicFrame(let f): return f.id
            case .group(let g): return g.id
            }
        }.max() ?? 1) + 1

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
        let (docId, _) = try requireSession(args: args)
        let idx = try slideIndex(args)
        guard let shapeId = args["shape_id"]?.intValue,
              let row = args["row"]?.intValue,
              let col = args["col"]?.intValue,
              let text = args["text"]?.stringValue else {
            throw PPTXError.invalidParameter("", "需要 shape_id, row, col, text")
        }

        guard let elIdx = findElement(in: openPresentations[docId]!.slides[idx], id: shapeId),
              case .graphicFrame(var frame) = openPresentations[docId]!.slides[idx].elements[elIdx] else {
            throw PPTXError.invalidParameter("shape_id", "找不到表格 id=\(shapeId)")
        }

        try frame.table?.updateCell(row: row, col: col, text: text)
        openPresentations[docId]?.slides[idx].elements[elIdx] = .graphicFrame(frame)
        markDirty(docId)
        return "已更新儲存格 (\(row),\(col))"
    }

    // MARK: - Slide Management

    private func addSlide(args: [String: Value]) throws -> String {
        let (docId, _) = try requireSession(args: args)
        let slide = Slide()
        if let atIndex = args["at_index"]?.intValue {
            openPresentations[docId]?.slides.insert(slide, at: min(atIndex, openPresentations[docId]!.slides.count))
        } else {
            openPresentations[docId]?.slides.append(slide)
        }
        markDirty(docId)
        let count = openPresentations[docId]?.slides.count ?? 0
        return "已新增投影片（共 \(count) 張）"
    }

    private func deleteSlide(args: [String: Value]) throws -> String {
        let (docId, _) = try requireSession(args: args)
        let idx = try slideIndex(args)
        try openPresentations[docId]?.deleteSlide(at: idx)
        markDirty(docId)
        return "已刪除投影片 \(idx)"
    }

    private func reorderSlides(args: [String: Value]) throws -> String {
        let (docId, _) = try requireSession(args: args)
        guard let from = args["from_index"]?.intValue, let to = args["to_index"]?.intValue else {
            throw PPTXError.invalidParameter("from_index/to_index", "需要 from_index 和 to_index")
        }
        try openPresentations[docId]?.reorderSlide(from: from, to: to)
        markDirty(docId)
        return "已將投影片從位置 \(from) 移到 \(to)"
    }

    private func duplicateSlide(args: [String: Value]) throws -> String {
        let (docId, _) = try requireSession(args: args)
        let idx = try slideIndex(args)
        let newIdx = try openPresentations[docId]!.duplicateSlide(at: idx)
        markDirty(docId)
        return "已複製投影片 \(idx) → \(newIdx)"
    }

    // MARK: - Shape Editing

    private func insertTextShape(args: [String: Value]) throws -> String {
        let (docId, _) = try requireSession(args: args)
        let idx = try slideIndex(args)
        guard let text = args["text"]?.stringValue else {
            throw PPTXError.invalidParameter("text", "需要 text")
        }

        let x = args["x"]?.intValue ?? 457200
        let y = args["y"]?.intValue ?? 1600200
        let w = args["width"]?.intValue ?? 8229600
        let h = args["height"]?.intValue ?? 1143000

        let nextId = (openPresentations[docId]?.slides[idx].elements.compactMap { el -> Int? in
            switch el {
            case .shape(let s): return s.id
            case .picture(let p): return p.id
            case .graphicFrame(let f): return f.id
            case .group(let g): return g.id
            }
        }.max() ?? 1) + 1

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
        let (docId, _) = try requireSession(args: args)
        let idx = try slideIndex(args)
        guard let shapeId = args["shape_id"]?.intValue,
              let text = args["text"]?.stringValue else {
            throw PPTXError.invalidParameter("", "需要 shape_id 和 text")
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
        let (docId, _) = try requireSession(args: args)
        let idx = try slideIndex(args)
        guard let shapeId = args["shape_id"]?.intValue else {
            throw PPTXError.invalidParameter("shape_id", "需要 shape_id")
        }
        guard let elIdx = findElement(in: openPresentations[docId]!.slides[idx], id: shapeId) else {
            throw PPTXError.invalidParameter("shape_id", "找不到 id=\(shapeId)")
        }
        openPresentations[docId]?.slides[idx].elements.remove(at: elIdx)
        markDirty(docId)
        return "已刪除形狀 id=\(shapeId)"
    }

    private func setShapePosition(args: [String: Value]) throws -> String {
        let (docId, _) = try requireSession(args: args)
        let idx = try slideIndex(args)
        guard let shapeId = args["shape_id"]?.intValue,
              let x = args["x"]?.intValue,
              let y = args["y"]?.intValue else {
            throw PPTXError.invalidParameter("", "需要 shape_id, x, y")
        }
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
        let (docId, _) = try requireSession(args: args)
        let idx = try slideIndex(args)
        guard let shapeId = args["shape_id"]?.intValue,
              let w = args["width"]?.intValue,
              let h = args["height"]?.intValue else {
            throw PPTXError.invalidParameter("", "需要 shape_id, width, height")
        }
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
        let (docId, _) = try requireSession(args: args)
        let idx = try slideIndex(args)
        guard let shapeId = args["shape_id"]?.intValue,
              let color = args["color"]?.stringValue else {
            throw PPTXError.invalidParameter("", "需要 shape_id 和 color")
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

    // MARK: - Notes & Transition

    private func addNotes(args: [String: Value]) throws -> String {
        let (docId, _) = try requireSession(args: args)
        let idx = try slideIndex(args)
        guard let text = args["text"]?.stringValue else {
            throw PPTXError.invalidParameter("text", "需要 text")
        }
        openPresentations[docId]?.slides[idx].notes = text
        markDirty(docId)
        return "已設定備忘稿"
    }

    private func setTransition(args: [String: Value]) throws -> String {
        let (docId, _) = try requireSession(args: args)
        let idx = try slideIndex(args)
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

// MARK: - Value Extensions

extension Value {
    var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(v)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let v): return v
        case .string(let s): return s == "true" || s == "1"
        default: return nil
        }
    }
}

# che-pptx-mcp

PowerPoint (.pptx) MCP server — Swift-native PresentationML 解析與生成，40 tools，無需安裝 PowerPoint。

## 功能類別

| 類別 | 例 |
|------|----|
| Presentation 生命週期 | `create_presentation` / `open` / `close` / `autosave` |
| Slides | `add_slide` / `delete_slide` / `duplicate_slide` / layouts / master |
| 內容讀寫 | `get_slide_text` / `get_shape_text` / tables / notes / theme |
| 匯出 | `export_markdown` / `export_image` |
| 幾何（公分） | `set_placeholder_geometry` / `place_picture_at` / `fit_picture_to_native_aspect` |

### 幾何工具（公分）

長度參數一律是公分（number），內部換算為 EMU（1 cm = 360,000 EMU）。回應為 JSON，同時列出 cm（小數兩位）與 EMU 幾何；超出投影片範圍仍會套用，並以 `warnings` 指出越界的邊。

| Tool | 說明 |
|------|------|
| `set_placeholder_geometry` | 以 `x_cm` / `y_cm` / `width_cm` / `height_cm` 設定任一頂層元素（佔位符或一般形狀、圖片、表格框）的位置與大小；群組內元素不支援 |
| `place_picture_at` | 插入圖片（`image_path` 或 `image_base64`）並以 `x_cm` / `y_cm` / `width_cm` 定位；省略 `height_cm` 時依原生像素比例推導 |
| `fit_picture_to_native_aspect` | 依圖片原生像素比例重算非錨定邊（`anchor` = `width` 或 `height`），位置不變 |

### 整數參數

所有工具的整數參數（`slide_index`、`shape_id`、EMU 單位的 `x` / `y` / `width` / `height`、`columns` / `rows` 等）採同一套驗證：只接受 JSON 數值，且必須是能精確轉成整數的有限值（`3` 與 `3.0` 可以；`"3"`、`true`、`0.5`、`1e300` 不行）；再檢查該參數自己的範圍（投影片索引須在簡報內、EMU 位置須在 OOXML `ST_Coordinate` 範圍、寬高不得為負、表格欄列數為 1–1000）。不合格時回傳 `isError` 的參數錯誤並指出參數名稱，文件不會被修改。

完整清單以 MCP `tools/list` 為準（server instructions 內含兩種模式說明：Direct `source_path` / Session `doc_id`）。

## 安裝（推薦：Claude Code plugin）

```bash
claude plugin marketplace add PsychQuant/macdoc
claude plugin install che-pptx-mcp@macdoc
```

Wrapper 會自動從本 repo 的 [GitHub Releases](https://github.com/PsychQuant/che-pptx-mcp/releases) 下載 binary，安裝前與每次啟動皆驗證 sha256 與 Developer ID 簽章鏈（Team `6W377FS7BS`）。

## Build from source

```bash
swift build -c release   # binary at .build/release/ChePPTXMCP
```

## Release 流程（maintainer）

```bash
scripts/release.sh <version>
```

Pipeline：版本同步 gate（source 常數 = release 版本）→ universal build → Developer ID codesign → pre-upload 簽章 gate → notarize（必須 Accepted）→ sha256 → `gh release create`。詳見 script header（PsychQuant/macdoc#119）。

## License

Private repository. All rights reserved.

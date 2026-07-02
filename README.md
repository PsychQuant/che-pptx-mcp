# che-pptx-mcp

PowerPoint (.pptx) MCP server — Swift-native PresentationML 解析與生成，約 45 tools，無需安裝 PowerPoint。

## 功能類別

| 類別 | 例 |
|------|----|
| Presentation 生命週期 | `create_presentation` / `open` / `close` / `autosave` |
| Slides | `add_slide` / `delete_slide` / `duplicate_slide` / layouts / master |
| 內容讀寫 | `get_slide_text` / `get_shape_text` / tables / notes / theme |
| 匯出 | `export_markdown` / `export_image` |

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

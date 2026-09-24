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
scripts/release.sh <version>   # 例：scripts/release.sh 0.3.0（不加 v）
```

發布前先把 `Sources/ChePPTXMCP/Server.swift` 的 `serverVersion` 改成要發布的版本、更新 CHANGELOG 並 commit；script 從**目前 HEAD** 發布。步驟與 `scripts/release.sh` 的輸出一一對應：

| 步驟 | 內容 |
|------|------|
| `[0/7]` pre-flight | notary profile（keychain `che-mcps-notary`）可用；工作樹完全乾淨（含 untracked 檔）；記下 `SOURCE_HEAD`；本機 tag、remote tag、GitHub release 都還不存在。接著以 `git worktree add --detach` 在暫存目錄建立 `SOURCE_HEAD` 的**隔離 worktree**，之後的建置都在那裡進行，主工作樹在建置期間的修改與舊的 `.build` 狀態都不會混入 |
| `[0.5/7]` 版本同步 gate | 隔離 worktree 裡的 `serverVersion` 必須等於 `<version>` |
| `[1/7]` universal build | 在隔離 worktree 建置 arm64 + x86_64；binary 位置以 `swift build --show-bin-path` 查詢，不寫死路徑。建置後的 **drift gate**：隔離 worktree 的 HEAD 仍須是 `SOURCE_HEAD` 且沒有任何變更，否則在簽章前以 `exit 3` 中止 |
| `[2/7]` codesign | Developer ID、hardened runtime、timestamp |
| `[3/7]` 上傳前簽章 gate | 以與 marketplace wrapper 相同的 requirement（Team `6W377FS7BS`）驗證，並確認是 universal binary |
| `[4/7]` notarize | 必須 `Accepted` |
| `[5/7]` sha256 | 產生 `ChePPTXMCP.sha256` |
| `[6/7]` 最終 gate | 對實際要上傳的檔案再驗一次簽章與 sha256（TOCTOU 防護） |
| `[7/7]` gh release | `gh release create --target SOURCE_HEAD`：tag 建在被建置的那個 commit 上，而不是發布當下的 HEAD |

結束碼：`2` 參數錯誤、`3` pre-flight 或 drift gate 失敗、`4` 找不到 binary、`5` 簽章 gate 失敗、`6` notarization 未通過。任一 gate 失敗都發生在上傳之前。

`scripts/tests/` 的 harness 以假的 `swift`／`codesign`／`xcrun`／`gh` 模擬整條 pipeline（drift 必須在簽章前中止、tag 釘在 `SOURCE_HEAD`、binary 路徑來自 `--show-bin-path`），CI（`.github/workflows/ci.yml`）在每次 push 到 main 與每個 PR 執行它們與 shellcheck；CI 不簽章、不公證、不發布。詳見 script header（PsychQuant/macdoc#119、PR #3）。

## License

Private repository. All rights reserved.

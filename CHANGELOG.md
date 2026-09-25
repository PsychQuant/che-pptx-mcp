# Changelog

All notable changes to che-pptx-mcp will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `open_presentation` 開啟含「pptx-swift 無法安全保存」內容的簡報時，回應會逐一列出是哪張投影片的哪個元素、為什麼（PsychQuant/pptx-swift#12、#15），並說明改掉或刪除它們之後就能存檔。依 pptx-swift 0.6.0 的 `Presentation.writeBlockers` 判斷，涵蓋：形狀或群組的原樣填色／效果／`extLst` 引用了 relationship（例如圖片填色的形狀）、圖表／SmartArt／OLE 物件、引用 relationship 的未建模元素（墨跡等）。這類簡報在 0.6.0 之前存檔會靜默刪掉圖表，或讓圖片填色的形狀顯示成另一張圖；現在 `save_presentation` 會拒絕並指名元素。

### Fixed

- `set_shape_fill` 對讀進來的漸層、圖片填色形狀生效（PsychQuant/pptx-swift#12）。之前回報「已設定填色」，存檔後仍是原本的填色；根因在 pptx-swift（原樣填色的優先序高於 typed 填色），pptx-swift 0.6.0 把兩者合成單一值後修正，這裡補上端到端測試。對圖片填色的形狀呼叫 `set_shape_fill` 也會解除上一條的存檔限制。
- `delete_shape` 刪掉被連接線黏著的形狀時，一併解除連接線指向它的端點（比照 PowerPoint），回應會說明解除了幾個端點；新元素的 id 配置也避開仍被連接線 `stCxn`／`endCxn` 引用的 id（PsychQuant/pptx-swift#9）。之前刪掉 id 最大的被黏形狀後再插入新元素，新元素會拿到同一個 id，連接線就靜默改黏到它身上。
- 升級 pptx-swift 0.5.0（PsychQuant/pptx-swift#7）：旋轉或翻轉過的形狀、圖片、表格框與群組（`a:xfrm` 的 `rot`／`flipH`／`flipV`）存檔後保留，不再默默回到原狀。幾何工具（`set_placeholder_geometry`、`fit_picture_to_native_aspect`）只改位置與大小，不會清掉旋轉。

### Changed

- 升級 pptx-swift 至 0.6.0（PsychQuant/pptx-swift#9、#10）：`SlideElement` 新增 `.connector`（連接線／箭頭，`p:cxnSp`）與 `.raw`（`mc:AlternateContent`、`p:contentPart` 等未建模子元素的原始 XML passthrough）兩個 case。這是一次 breaking change——伺服器內每一處對 `SlideElement`做 exhaustive switch（沒有 `default:`）的既有程式碼都需要更新才能編譯，已全部更新：
  - `get_slide_shapes`：新增連接線（含起訖連接點 `stCxn`／`endCxn`）與未建模元素（顯示 `localName` 與所有 `cNvPr/@id`）各自的一行摘要，不再是「新元素類型出現就編譯失敗」或「悄悄從清單消失」。
  - `nextElementId`（新元素 id 配置，#6 的教訓）：改用 pptx-swift 新增的 `Slide.allElementIds`（遞迴涵蓋群組子孫與 `.raw` 元素內所有 id），取代原本手寫、逐 case 列舉的 `maxElementId(in:)`——手寫版本在 pptx-swift 新增 case 時會安靜漏看該 case 底下的 id，讓新插入的元素有機會撞號、蓋掉既有的連接線或未建模元素（che-pptx-mcp#10，#6 教訓的重演）；改用 pptx-swift 自己維護的 API 後，這類遺漏由上游負責保持窮舉，不必依賴下游每次都記得手動加 case。
  - `set_placeholder_geometry` 內部的 `topLevelGeometry`：連接線現在回傳其位置與大小（沿用 `Connector.position`／`size`，與形狀、圖片、表格框同一套 `a:xfrm`）；未建模元素沒有型別化幾何可回傳，回傳 `nil`（與既有的群組行為一致，不是新的限制——`Slide.setGeometry` 對 `.raw` 本來就會丟 `PPTXError.rawElementGeometryUnsupported`）。
  - `findElement`（`delete_shape`／`update_cell` 等工具共用的 id 查找）：新增比對連接線與未建模元素（後者比對其所有 id，不只第一個）。之前這兩類元素對 `findElement`完全不可見——`delete_shape` 傳入一個真實存在的連接線 id 只會得到「找不到」，讓使用者誤以為該元素不存在；現在能正確找到並刪除。

## [0.4.0] - 2026-09-24

### Added

- `open_presentation` 開啟含音訊、影片或換場音效的簡報時，回應會列出是哪幾張投影片，並說明這份簡報可以讀取但無法存檔（PsychQuant/pptx-swift#5）。之前要等到 autosave 或 `save_presentation` 失敗才會發現。
- CI 新增 `swift-test` job（#10）：在 `macos-latest` 上跑 `swift build` + `swift test`。先前 `.github/workflows/ci.yml` 只在 ubuntu-latest 跑 shellcheck 與 `scripts/tests/*.sh`（#4），`swift test` 從未在任何機器上跑過。2026-09 的 `macos-latest` 解析到 macOS 26（arm64，預設 Xcode 26.6），能建置本套件 `swift-tools-version: 5.9` 的 manifest；repo 公開，macOS runner 分鐘數不計費。
- CI 新增 `actionlint` job（#10）：在 ubuntu-latest 靜態檢查 workflow 檔案本身。下載固定版本（v1.7.12）的官方 release 二進位並用官方 checksums 檔驗證 sha256，不用 `curl | bash` 抓可變的 `main` 分支腳本。

### Changed

- 布林參數改用與 #5 整數參數相同的嚴格 JSON 型別規則（#10）：只接受 JSON 的 `true`／`false`，其餘一律回參數錯誤，命名該參數。缺少或明確的 JSON `null` 視同未提供、套用預設值 `false`（與 `optionalInt` 對整數參數的規則一致，不是本次新增的例外）。移除舊的 `Value.boolValue`——它會把字串 `"true"`／`"1"` 轉成 `true`，但因為 `.string(let s)` 這個 case 本身不會落到 `default: return nil`，**任何其他字串（包含字面上的 `"false"`）都被默默轉成 `false`**，不是回錯誤。受影響參數：`create_presentation`／`open_presentation` 的 `autosave`（目前僅有的兩個布林參數，已用逐一比對 schema 的測試鎖定「沒有漏掉任何布林參數」）。

### Fixed

- 升級 pptx-swift 0.4.0（PsychQuant/pptx-swift#5）：含群組（`p:grpSp`）的簡報存檔後，群組與其中的形狀、圖片、文字不再默默消失；外部連結圖片（`r:link`）會保留。

### Changed

- 升級 pptx-swift 0.4.0 帶來的行為變更：簡報含音訊、影片或換場音效時，`save_presentation` 與 autosave 會回錯誤（「投影片 N 含音訊、影片或換場音效…拒絕存檔」），不再存出播放能力已遺失的檔案。

## [0.3.0] - 2026-09-24

### Added

- CI workflow `.github/workflows/ci.yml`（#4）：每次 push 到 main 與每個 PR，在 ubuntu-latest 上跑 shellcheck 與 `scripts/tests/*.sh`（以 glob 收集，新增的 harness 不必改 workflow）。不簽章、不公證、不發布、不讀 secrets。
- `scripts/tests/ci-and-release-docs.sh`（#4）：檢查 workflow 的觸發條件、glob 與 shellcheck 步驟、沒有簽章／發布步驟，並檢查 README 的 Release 段落涵蓋 `scripts/release.sh` 的每個 `[n/7]` 步驟。

### Changed

- README 的「Release 流程」改寫為與 `scripts/release.sh` 一致（#4）：逐步列出 pre-flight、`SOURCE_HEAD` 與 `git worktree` 隔離建置、版本同步 gate、建置後的 drift gate（簽章前 `exit 3`）、兩道簽章 gate、notarize、`--target SOURCE_HEAD`，以及結束碼與 CI 的角色。
- 整數參數與 v0.2.0 幾何工具採同一套嚴格型別規則（#5）：只接受 JSON 數值（整數，或恰為整數的 double）。先前舊工具會把字串 `"3"` 轉成 3、把 `0.5` 截成 0；現在兩者都回傳參數錯誤。
- EMU 參數檢查 OOXML 範圍（#5）：`insert_image`、`insert_text_shape`、`insert_table`、`set_shape_position` 的 `x`／`y` 必須在 `ST_Coordinate` 範圍內，`width`／`height`（含 `set_shape_size`）必須介於 0 與 `ST_PositiveCoordinate` 上限之間。先前越界值會被寫進檔案，PowerPoint 開啟時需要修復。
- `add_slide` 的 `at_index` 大於投影片數時回傳錯誤，不再默默改成加在最後（#5）。
- `slide_index` 越界時的錯誤改為指名 `slide_index` 的參數錯誤（原為不帶參數名的「索引超出範圍」），與其他整數參數一致（#5）。
- `insert_image`、`insert_text_shape` 的 schema 不再把 `x`／`y`／`width`／`height` 列為必填，描述中註明預設值：實作一直是省略時套用預設值，schema 卻宣告必填，依 schema 驗證的 client 會拒絕 server 其實接受的呼叫（#5）。
- `update_shape_text`、`set_shape_position`、`set_shape_size`、`set_shape_fill`、`update_cell` 缺少參數時，錯誤訊息改為指出缺少的是哪一個參數（#5）。

### Fixed

- 整數參數遇到 NaN、±Infinity 或超出 `Int` 範圍的數值時，server 不再 crash（#5）。原本的 `Value.intValue` 以 `Int(Double)` 轉換，遇到這些值直接 trap（`0.5` 這類有限小數則被默默截成 0）；它已刪除，所有工具的整數參數改走同一個 `optionalInt`／`requiredInt`（`Int(exactly:)`），無效時回傳指名參數的 `isError` 結果，文件與 dirty 狀態不變。
- 同一類的其他 crash 一併移除（#5）：多數 session 工具未檢查 `slide_index` 是否在簡報內（陣列越界 trap），現在一律檢查；`insert_table` 的 `columns`／`rows` 為 0 或負數時會除以零或建立無效 range，現在限定 1–1000；`add_slide` 的負 `at_index` 會 trap，現在限定 0 到投影片數。
- `update_cell` 的 `row`／`col` 與 `reorder_slides` 的 `from_index`／`to_index` 改在 server 端依實際表格與投影片數檢查，錯誤訊息指出參數名稱（#5）；`update_cell` 指向沒有表格的 graphic frame 時回傳錯誤，不再回報成功卻什麼都沒改（並把文件標成已修改）。
- `insert_image` 的 `file_name` 與既有 media 同名時改用不重複的名稱（與 `place_picture_at` 相同），不再讓兩張圖片連到同一份 media、存檔時覆寫先前的圖片（跨模型審查發現的既有問題，PsychQuant/macdoc#90）。
- autosave 寫檔失敗時不再清除 dirty 狀態（跨模型審查發現的既有問題，PsychQuant/macdoc#90）：先前寫入錯誤被 `try?` 吞掉、dirty 仍被清成 false，之後 `close_presentation` 會放行並丟掉唯一持有修改的 session。現在 dirty 保持 true，工具結果多一個獨立的 content 項目帶「自動存檔失敗」警告（第一個項目維持原樣，幾何工具的 JSON 回應仍可解析）。
- `delete_image` 只刪除圖片（同上，PsychQuant/macdoc#90）：先前會刪掉任何 id 相符的元素，包括文字框、表格與整個群組，並回報「已刪除圖片」。
- `insert_text_shape`、`insert_table` 的新元素 id 改由與 `insert_image`／`place_picture_at` 相同的配置函式產生（#6）：取整棵 shape tree（含巢狀群組子元素）的最大 id 加一（至少為 2）；最大 id 已達 DrawingML `ST_DrawingElementId` 上限（`unsignedInt`，4,294,967,295）時回傳錯誤，因此不會寫出無效的 id，也不會 `Int` 溢位 trap。先前只看頂層元素，群組內已有 id=11 時新元素也會拿到 11，產生重複 id，並讓原本應被拒絕的群組子元素位址改指向新元素。
- pptx-swift 下限提高到 **0.3.0**：存出的檔案帶有圖片 relationship、media part 與 content type（PsychQuant/pptx-swift#1），原生比例考慮 EXIF 方向（PsychQuant/pptx-swift#2）。
- `fit_picture_to_native_aspect` 以 `srcRect` 裁切後的可見區域計算比例（PsychQuant/pptx-swift#2）；裁切過的圖片不再變形，裁切本身不變。
- `create_presentation`／`open_presentation` 遇到已有未存檔修改的 `doc_id` 時回傳錯誤、原 session 不變（#8）；先前會直接蓋掉，未存檔的修改消失，也繞過了 `close_presentation` 的保護。乾淨的 session 仍可替換。

## [0.2.0] - 2026-09-24

### Added

- 三個公分單位的幾何工具（37 → 40 tools，PsychQuant/macdoc#90）：`set_placeholder_geometry`、`place_picture_at`、`fit_picture_to_native_aspect`；回應為 JSON（cm 小數兩位 + EMU），越出投影片範圍時附 `warnings`。需 pptx-swift 0.2.0 的 Geometry 模組。參數型別嚴格驗證（數值欄位不接受字串、`image_path`／`image_base64` 必須是字串且恰給其一；JSON null 視同未給），所有驗證在寫入文件前完成，失敗時文件與 dirty 狀態不變。
- `get_slide_shapes` 的 Shape／Picture 列附加 `pos_cm` / `size_cm`，Picture 列補上原本缺少的 `pos=(x,y)`（既有欄位不變）。
- README / CHANGELOG / `Package.resolved` 鎖版 / `serverVersion` 常數 + release.sh 版本同步 gate（repo baseline，#1；release pipeline 本體來自 PsychQuant/macdoc#119）。

## [0.1.0] - 2026-07-02

### Added

- 首次 signed + notarized release（PsychQuant/macdoc#112 marketplace 上架）：PresentationML 解析與生成 MCP server（~45 tools）。

# Changelog

All notable changes to che-pptx-mcp will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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

# Changelog

All notable changes to che-pptx-mcp will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

- `insert_text_shape`、`insert_table` 的新元素 id 改由與 `insert_image`／`place_picture_at` 相同的配置函式產生（#6）：取整棵 shape tree（含巢狀群組子元素）的最大 id 加一，溢位時回傳錯誤而不是 trap。先前只看頂層元素，群組內已有 id=11 時新元素也會拿到 11，產生重複 id，並讓原本應被拒絕的群組子元素位址改指向新元素。

## [0.2.0] - 2026-09-24

### Added

- 三個公分單位的幾何工具（37 → 40 tools，PsychQuant/macdoc#90）：`set_placeholder_geometry`、`place_picture_at`、`fit_picture_to_native_aspect`；回應為 JSON（cm 小數兩位 + EMU），越出投影片範圍時附 `warnings`。需 pptx-swift 0.2.0 的 Geometry 模組。參數型別嚴格驗證（數值欄位不接受字串、`image_path`／`image_base64` 必須是字串且恰給其一；JSON null 視同未給），所有驗證在寫入文件前完成，失敗時文件與 dirty 狀態不變。
- `get_slide_shapes` 的 Shape／Picture 列附加 `pos_cm` / `size_cm`，Picture 列補上原本缺少的 `pos=(x,y)`（既有欄位不變）。
- README / CHANGELOG / `Package.resolved` 鎖版 / `serverVersion` 常數 + release.sh 版本同步 gate（repo baseline，#1；release pipeline 本體來自 PsychQuant/macdoc#119）。

## [0.1.0] - 2026-07-02

### Added

- 首次 signed + notarized release（PsychQuant/macdoc#112 marketplace 上架）：PresentationML 解析與生成 MCP server（~45 tools）。

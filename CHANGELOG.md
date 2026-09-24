# Changelog

All notable changes to che-pptx-mcp will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- 三個公分單位的幾何工具（37 → 40 tools，PsychQuant/macdoc#90）：`set_placeholder_geometry`、`place_picture_at`、`fit_picture_to_native_aspect`；回應為 JSON（cm 小數兩位 + EMU），越出投影片範圍時附 `warnings`。需 pptx-swift 0.2.0 的 Geometry 模組。參數型別嚴格驗證（數值欄位不接受字串、`image_path`／`image_base64` 必須是字串且恰給其一；JSON null 視同未給），所有驗證在寫入文件前完成，失敗時文件與 dirty 狀態不變。
- `get_slide_shapes` 的 Shape／Picture 列附加 `pos_cm` / `size_cm`，Picture 列補上原本缺少的 `pos=(x,y)`（既有欄位不變）。
- README / CHANGELOG / `Package.resolved` 鎖版 / `serverVersion` 常數 + release.sh 版本同步 gate（repo baseline，#1；release pipeline 本體來自 PsychQuant/macdoc#119）。

## [0.1.0] - 2026-07-02

### Added

- 首次 signed + notarized release（PsychQuant/macdoc#112 marketplace 上架）：PresentationML 解析與生成 MCP server（~45 tools）。

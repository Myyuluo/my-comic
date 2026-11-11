# 05: 删除 PDF 导入、阅读统计、浏览器扩展与 OCR 残留

**What to build:** 移除 Q9 明确删除的剩余非漫画能力：PDF 导入、阅读统计、浏览器扩展，以及端上 OCR/无入口渲染胶水；保留漫画图片导入、Local source 与 `.mokuro` 数据路径（如仍被 Local source 使用）。

**Blocked by:** 04

**Status:** ready-for-agent

- [ ] 删除 PDF 导入路径、导入对话框中的 PDF 选项、`pdfrx` 依赖与相关测试；确认图片/CBZ/ZIP/文件夹导入仍正常。
- [ ] 删除 Reading statistics 的写入、聚合、查看入口和测试；保留 History 与 Reading progress，二者语义不变。
- [ ] 删除浏览器扩展目录、manifest、options、语言字典、测试与所有引用；确认旧 Onboarding 已不依赖它。
- [ ] 删除端上 OCR/AI 推理与已无入口的 `.ocr-box` 渲染胶水；如果 Local source 的 `.mokuro` overlay 仍需要文本框渲染，保留最小数据路径，不保留 OCR 推理。
- [ ] 删除仅被这些功能使用的依赖、资源和测试 fixture。
- [ ] 验证：`flutter analyze`、相关 `flutter test`、`flutter build windows --debug` 通过；漫画图片导入、阅读器、Local source 与 `.mokuro`（如保留）可用。

**Notes:** 参考 [spec](../spec.md) 与 [ADR 0024](../../../docs/adr/0024-windows-only-independent-identity.md)。不要删除 Local source 或 Download library 的图片/章节容器能力。

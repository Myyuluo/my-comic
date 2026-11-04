---
status: accepted
---

# 只保留漫画域，删除非漫画模块并使用全新数据库 schema

Fushi 是语言学习套件，而 my-comic 只做漫画。我们决定保留书架/分类、Mihon 扩展源、搜索/详情、阅读器、下载、历史/进度、更新计划、追踪和本地源，删除 EPUB/小说、视频/Aniyomi、有声书、词典/查词、Anki/SRS、galgame、AI/OCR、BT/发现、云同步/Interconnect、Fushi Server，以及阅读器内嵌的查词/Anki/统计入口；数据库使用全新 schema，不迁移 Fushi 旧数据。

**Consequences**

- 删除按“先 UI、再原生库、最后 DB 表”的顺序分阶段进行，每步构建验证。
- 阅读器会少掉查词/Anki/统计入口，这是有意的取舍。
- 不兼容 `.fushi.zip` 或旧 Fushi 数据库。

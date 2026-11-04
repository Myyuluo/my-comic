---
status: accepted
---

# UI 必须与 Fushi v3.0.0 使用同一套设计和审美

用户明确要求 my-comic 的 UI 与 Fushi v3.0.0 使用同一套设计和审美。可以隐藏或移除非漫画入口，但不得替换、重写、简化 Fushi 的原版 shell、组件、主题或布局；任何 UI 改动必须先获得用户明确许可，并以 Fushi v3.0.0 的截图/组件为对照。

ticket 11 用简化版 `home_shell.dart` 替换原版 `home_page.dart`，违反了此约束；恢复工作由 ticket 16 跟踪。

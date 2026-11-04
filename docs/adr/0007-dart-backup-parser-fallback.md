---
status: accepted
---

# 备份导入 v1 使用 Dart 解析器，sidecar 迁移延后

ADR-0005 计划在 JVM sidecar 中复用 Mihon backup model；当前构建环境无法完成 sidecar 构建（缺 Temurin 21/Maven，PowerShell 受限，下载超时）。v1 改为在 Dart 中实现 gzip + protobuf 解析器，保持 Import/Merge/Report 边界不变；sidecar 可用后把 parser 依赖替换为 sidecar 客户端，现有 fixture 可复用于 Sidecar HTTP seam。

# 11: 文档、README 与仓库元数据

**What to build:** 收口文档与仓库元数据：删除三类上游归档，重写两份 README，更新 UPSTREAM/GLOSSARY/ADR 与 CI/Issue/FUNDING 元数据，保留许可证与来源署名。

**Blocked by:** 10

**Status:** ready-for-agent

- [ ] 删除 `docs/bugs/`、`docs/readme/`、`docs/agent/` 三类纯上游归档。
- [ ] 重写 `README.md`（英文）与 `README.zh-CN.md`（中文）：MyComic 定位、Windows 安装、漫画功能、Mihon 兼容、GPL-3.0、基于 Fushi v3.0.0。
- [ ] 删除或重写应用子目录下的旧 README；不再指向 fushi.moe、上游仓库、Discord、TestFlight 或上游下载页。
- [ ] 更新 `UPSTREAM.md`：保留上游快照/commit/许可证信息，确认 `docs/agent` 删除后的表述正确，链接 ADR 0024。
- [ ] 更新 CI/FUNDING/Issue 模板/Release 标题，移除上游仓库与服务端/R2 工作流；只保留 Windows 发布线。
- [ ] 保留 ADR、`GLOSSARY.md`、fork 自己的 specs/plans/reviews；未在删除名单内的历史文档默认保留。
- [ ] 确认 LICENSE 与第三方 NOTICE/许可完整；README/About 的“基于 Fushi v3.0.0”署名存在。
- [ ] 验证：README 两份可读且一致；活动文档中没有指向 fushi.moe/上游的链接；Fushi 引用扫描器只剩 allowlist。

**Notes:** 参考 [spec](../spec.md) 与 [ADR 0024](../../../docs/adr/0024-windows-only-independent-identity.md)。历史文档（如 `fushi/docs/reviews`、旧五平台 spec）默认保留，不纳入本 ticket 的删除范围。

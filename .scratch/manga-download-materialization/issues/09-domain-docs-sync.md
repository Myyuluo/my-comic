# 09: 领域文档同步

**What to build:** 实现完成后，`GLOSSARY.md` 与 ADR 0012 / 0019 / 新增的章节顺序 ADR 与用户可见行为一致。

**Blocked by:** 01、02、03、04、05、06、07、08

**Status:** ready-for-agent

- [ ] 更新 `GLOSSARY.md` 的 Download library、Cache、Clear database、下载状态、Source not installed 等条目；History 保持现状。
- [ ] 修订 ADR 0012：惰性物化、封面缓存、同名共享目录、清库后自动重连。
- [ ] 修订 ADR 0019：来源未安装时不建目录、不请求封面、只读本地文件。
- [ ] 新增 ADR：章节阅读顺序以 `sourceOrder` 为准，记录 Mihon 参考、显示顺序与阅读顺序解耦、已有作品重导策略。
- [ ] `GLOSSARY.md` 不包含表名、文件路径等易过时实现细节；文档与实现及测试一致；实现与 spec 有偏差时先更新 spec。
- [ ] 文档核对完成；本次无代码变更。

# 09: 领域文档更新：GLOSSARY 与 ADR

**What to build:** 更新 GLOSSARY 与相关 ADR，使 `local` 目录、`source (LANG)` 与封面写入策略与最终实现一致。

**Blocked by:** 02（本地源根目录更名 `local`）、03（下载源目录命名）、04（本地图源封面）

**Status:** resolved

- [x] GLOSSARY 的 Local source root 路径改为 `local`，注明旧 `localcomic` 不再使用
- [x] GLOSSARY 补充本地图源封面约定：缺失时生成可见 `cover.jpg`，不写隐藏元数据、不覆盖用户封面
- [x] ADR 0011 补修订说明：Content root 子目录为 `downloads` / `autobackup` / `local`
- [x] ADR 0012 补修订说明：新下载源目录为 `source (LANG)`，已有目录不重命名，`pages.json` 保持裸源名
- [x] ADR 0013 补修订说明：`local` 目录、扫描允许补写缺失 `cover.jpg`、仍不写隐藏 ID/不复制页文件
- [x] 文档与实现、spec 保持一致；不把实现细节写进 GLOSSARY

## Answer

Implemented in `cee8722f` + `9455607f`, merged as `7d35b622`; code review 后又补了 ADR 0013 批量加入、ADR 0014 独立页、ADR 0012 `local` 说明。GLOSSARY 与 ADR 0011/0012/0013/0014 均与实现一致。

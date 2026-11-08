# 03: 下载源目录命名为 `source (LANG)`

**What to build:** 新下载的源目录命名为 `源显示名 (LANG)`，例如 `六漫画 (ZH)`、`六漫画 (ZH-HANS)`。只影响新下载；已有源目录不重命名。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 新下载的源目录为 `源显示名 (LANG)`，括号前一个空格
- [x] 语言取 Source 的 language 原值转大写，保留子标签（`zh-Hans` → `ZH-HANS`）
- [x] 空、`all`、`multi` 视为无语言，只写源名、不写括号
- [x] 同名同语言的源仍使用现有短哈希后缀避免冲突
- [x] 源目录名的 Windows 净化、长度预算与截断规则沿用现有实现
- [x] 已有源目录不被重命名；同一源的新下载复用已有目录（目录名不是身份）
- [x] `pages.json.source.name` 保持裸源名，不写语言
- [x] 没有语言能力的运行时（互联等）不写后缀
- [x] 下载库命名、在线库路径与下载服务测试覆盖上述规则

## Answer

Implemented in `f007f287`, merged as `a2fa4c60`. 新源目录为 `六漫画 (ZH)` / `(ZH-HANS)`；空/`all`/`multi` 无后缀；同名同语言保留短哈希；已有目录不重命名；`pages.json.source.name` 保持裸名。

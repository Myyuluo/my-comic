# 04: 本地图源封面生成与 `coverPath` 同步

**What to build:** 扫描本地图源时，给没有封面的作品生成 `cover.jpg`：取第一页、缩放到宽 600px、JPEG 质量 85，写入作品根目录；网格先显示占位、封面在后台逐个补齐；已入架作品的 `coverPath` 同步更新，书架与作品页立即可见。

**Blocked by:** 02（本地源根目录更名 `local`）

**Status:** resolved

- [x] 文件夹作品：取自然顺序第一部章节的第一页生成 `cover.jpg`
- [x] CBZ 作品：取第一个压缩包内 `pages.json` 排序的第一页；无 manifest 时按图片名自然排序
- [x] 封面宽 600px（小于 600 不放大）、JPEG 质量 85，通过现有原子封面写入与可解码校验路径写入
- [x] 已有任何 `cover.jpg/jpeg/png` 时绝不覆盖
- [x] 扫描结果先显示，封面后台逐个生成；生成完成一个更新一个卡片
- [x] 第一页损坏/读不出时跳过并保留占位，下次进入重试，不写坏图
- [x] 已登记作品 `coverPath` 为空（典型 CBZ）或指向旧第一页时，生成后更新为 `cover.jpg`
- [x] 不复制/移动页文件，不写隐藏元数据；封面是可删除、可重新生成的可见文件
- [x] 网格、书架、作品页都显示生成后的封面
- [x] 测试覆盖文件夹、CBZ、已有封面不覆盖、坏页跳过、已入架 `coverPath` 更新

## Answer

Implemented in `b110eac2`, merged as `13624977`. 缺失封面从第一页生成 `cover.jpg`（600px、JPEG q85、原子写入、不覆盖、坏页跳过、后台逐个补齐），并同步已入架作品的 `coverPath`；Rebuild 登记/重链的作品也会补封面（code review 后补齐）。

# 03: 检索已下载扫描 downloads 并加入书架

**What to build:** 在「设置 → 存储与下载 → 下载索引」新增「检索已下载」：只扫描当前 Content root 的 `downloads`，把已下载但未加入书架且至少有一个完整章节的漫画加入书架；复用已有记录、复活主动移出书架的作品，并在源未安装时原地登记为本地条目。

**Blocked by:** 02（重建下载索引：只重链书架成员）

**Status:** resolved

- [x] 「下载索引」下新增「检索已下载」动作，桌面平台可见，整行可点，无行尾按钮。
- [x] 只扫描当前 Content root 的 `downloads`，不扫描 `local`、`autobackup` 或旧 Content root。
- [x] 只把至少有一个完整章节容器的作品加入书架；只有半成品、空目录或不可读内容的文件夹跳过并计入报告。
- [x] 已在书架（`membership=true`）的作品跳过，不重复加入或改写。
- [x] 已有 `membership=false` 记录时复用同一条记录并提升为书架成员，保留阅读进度、已读标记、History 与下载映射，不新建重复记录。
- [x] 被主动移出书架（tombstone）的作品在用户显式执行本动作时重新加入书架，并清除该作品的 tombstone。
- [x] 源已安装且下载目录带 `pages.json` 身份时，创建在线 Manga 条目，并把完整章节写入下载索引。
- [x] 源未安装或没有 `pages.json` 时，创建指向该 `downloads` 目录的本地条目并加入书架；报告单列「因来源未安装降级」数量。
- [x] 多个同身份副本无法安全决定归属时跳过并报告歧义，绝不猜测。
- [x] 不移动、不复制、不删除任何文件；文件继续留在 `downloads` 原地。
- [x] 不负责重链已在书架但未关联的作品；该职责仍属于「重建下载索引」。
- [x] 重复运行幂等，不重复加入、不重复提升、不重复复活。
- [x] 确认框、可取消进度框与结果报告完整；报告包含扫描目录、加入在线条目、加入本地条目、提升非书架记录、复活墓碑、跳过不完整、跳过歧义、失败与取消数量。
- [x] 副标题使用：「扫描 downloads 中已下载但未加入书架的漫画并加入书架。」
- [x] 测试覆盖设置动作 seam 与服务 seam：只扫 downloads、完整章节阈值、提升、复活并清墓碑、源未安装降级、歧义跳过、幂等、不移动文件。
- [x] 所有新增文案在全部支持语言中同步，并重新生成访问器。

## Answer

**Merge commit:** `adc79841bf51757b3aa8b3769ce59cb8e4938bb0`（`Merge ticket 03: scan downloads and add to library`，无冲突）

**改动摘要：**
- 新增 `ScanDownloadedMangaService`：只扫描当前 Content root 的 `downloads`，以完整章节容器为阈值筛选作品；已在书架的作品跳过，非书架记录原地提升（保留进度、已读、History 与下载映射），tombstone 显式复活并清除；有 `pages.json` 且源已安装时建立在线条目，源未安装/无 manifest 时降级为指向该目录的本地条目；歧义副本跳过，全程不移动/复制/删除用户文件，重复运行幂等。
- `download_manga_recovery.dart` 增加 tombstone 复活与记录提升支持；`settings_schema_rebuild_index.dart` 接入设置页「检索已下载」动作、确认框、可取消进度框与结果报告。
- 设置页新增「检索已下载」整行动作与副标题；全部 17 个语言文件同步新增文案并重新生成访问器。
- 新增/更新测试：`scan_downloaded_manga_service_test.dart`、`settings_scan_downloaded_test.dart`，以及 recovery、rebuild index、subtitle guard、i18n 排序守卫测试的相应调整。

**测试结果：** 全部通过（`flutter test` 7 个测试文件，71 个测试，0 失败）。

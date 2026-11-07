# 06: Local source folder chapters

**What to build:** 用户把本地漫画文件夹放到 `localcomic/{manga}/{chapter}/`，点击「导入本地漫画」后应用扫描第一层目录为作品、登记章节并原地阅读，不复制文件。支持 `cover.jpg`；manga 目录下直接有图片时当作单章；「移出书架」不删除文件；被主动移出的作品不会因再次扫描自动加回；拖入 CBZ/文件夹时先复制到 `localcomic` 再登记，原文件保留。

**Blocked by:** 01

**Status:** resolved

- [x] 把 `localcomic/{manga}/{chapter}/` 文件夹放入后，点击导入能看到作品与章节并可阅读
- [x] 读取是原地进行，不复制到其他受管目录
- [x] `cover.jpg` 被用作封面；manga 目录直接含图片时作为单章
- [x] 「移出书架」不删文件；删除本地文件是单独且二次确认的动作
- [x] 主动移出的作品不会因普通扫描自动复活（tombstone）
- [x] 拖入 CBZ/文件夹会复制到 `localcomic/{manga}/...` 并登记，原文件保留
- [x] 扫描、阅读、移出、拖入均有自动化测试

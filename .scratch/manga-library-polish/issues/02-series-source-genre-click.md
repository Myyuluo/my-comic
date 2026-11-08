# 02: 作品页源分类点击 → 全局搜索

**What to build:** 作品页展示来源提供的全部源分类（不设数量上限），每个源分类都可点击；点击效果与点击书名/作者一致：以该分类文字为关键词打开「搜索全部来源」并自动检索全部已启用的在线 Source。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 作品页渲染来源提供的全部源分类，不再限制为 8 个。
- [x] 每个源分类可点击，点击效果与点击书名/作者一致：以分类文字为关键词打开「搜索全部来源」并自动搜索全部已启用在线源。
- [x] 没有可用在线源时仍打开搜索页，并显示搜索页自己的空态说明。
- [x] 源分类具有与书名/作者一致的悬停反馈。
- [x] 书名/作者原有的点击行为不变。

## Answer

Implemented in `8da5dd7d`, merged as `ea2a2f23`. `OnlineWorkHeader` 增加 `onGenreTap`；漫画作品页传入 `_openGlobalSearch`，源分类 chip 与书名/作者同一条导航。Code review 后为共享 header 增加 `maxGenres`（漫画不限制、小说仍为 8），并把无运行时/取 manager 失败的路径改为打开空态搜索页（`d28f6ff1`，merged `68e80c69`）。

# 上游 Fushi Claude 配置（仅供参考）

`settings.upstream.json.txt` 是上游 Fushi 仓库 `.claude/settings.json` 的原始内容，仅作参考记录。

- 它包含 `"defaultMode": "bypassPermissions"`。
- **它不是本项目的激活配置，禁止复制到 `.claude/`**（包括 `.claude/settings.json` 和 `.claude/settings.local.json`）。
- 本项目在仓库根目录刻意不放置 `.claude/settings.json`；需要调整本地 agent 权限时，请在本地按 Claude Code 的常规方式自行配置，不要提交。

文件名以 `.json.txt` 结尾，避免被工具当作可直接加载的 Claude 配置。

<div align="center">

<img src="docs/assets/mycomic-logo-horizontal.png" alt="MyComic" width="480">

**Mihon 兼容的 Windows 桌面漫画阅读器。**

[English](README.en.md) | **简体中文**

![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D4)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.47.6-02569B?logo=flutter&logoColor=white)

</div>

## 缘起

该项目的诞生，是因为我用 Mihon 看漫画，结果下载漫画把手机存储空间塞满了，但我又不想将已下载的漫画删除，于是便想着能不能安装个 PC 版本的 Mihon 到电脑上，将备份倒过去，用电脑存储漫画。

但我发现，GitHub 上并没有界面好看、操作又简单的 Mihon 桌面版本，唯一比较相近的便是 Fushi 这个开源项目：该项目能完美支持 Mihon 的插件仓库和功能，但无法读取 Mihon 的备份文件。

经过我多方面的思考和学习，最后我决定，用 AI 做一个能完美支持 Mihon 插件和备份的 PC 桌面版漫画阅读器。

MyComic 是一个独立的 Windows 桌面漫画阅读器，基于 Fushi v3.0.0（GPL-3.0）快照；它与 Fushi、Mihon 项目没有隶属关系，也未获得其背书。

## 功能

- **书架**：把漫画加入书架，用标签整理，搜索与筛选，并从上次的位置继续阅读。
- **作品页与全局搜索**：查看作品详情、章节列表与源分类，并在一个入口搜索所有已启用的在线图源。
- **阅读器**：支持跨页、竖排分页与条漫（Webtoon）阅读模式，按作品保存阅读偏好、阅读进度与历史。
- **在线图源**：通过从扩展仓库安装的 Mihon 扩展浏览、搜索和阅读。
- **下载**：下载章节以供离线阅读，默认保存为 CBZ 压缩包（也支持文件夹），支持暂停、继续、重试与取消。
- **本地图源**：直接原地读取 Content root 中的漫画文件夹与 CBZ 文件，不导入、不复制。
- **历史**：每部作品一条记录，显示最近阅读的章节与封面。
- **备份**：导入与导出 Mihon 兼容的 `.tachibk` 备份。
- **四种界面语言**：English、简体中文、繁體中文、日本語；默认跟随系统语言，不支持时回退英语。
- **新手引导**：三步引导设置界面语言、主题与 Content root，可从设置重新打开。

## Mihon 兼容

MyComic 是 **Mihon 兼容的桌面阅读器**，不是 Mihon 的官方产品，也不是 Mihon 应用的移植：

- 通过随包分发的扩展运行时执行 **Mihon 扩展**，无需安装 Java 或运行独立服务器。
- 导入与导出 **Mihon v0.21.3 `.tachibk` 备份**；备份中的分类会映射为 MyComic 标签。
- 扩展行为以冻结的 Fushi v3.0.0 基线为兼容基准。

## 在 Windows 上安装

1. 从 [GitHub Releases](https://github.com/Myyuluo/my-comic/releases) 下载最新的 `mycomic-<版本>-windows-setup.exe`。
2. 运行安装程序。它安装到 `C:\Program Files\MyComic`（64 位），需要管理员权限（UAC）。
3. 从开始菜单或桌面快捷方式启动 **MyComic**。

系统要求：**Windows 10 或 Windows 11（64 位）**。

> 从旧版 Fushi 构建升级：MyComic 是一次干净切换。安装 MyComic 前请手动卸载旧应用；Program state root 中的用户数据不会迁移。旧 `fushi://` 深链与旧 `fushi-` 更新资产不再兼容，因此需要手动更新或重装一次。Content root（默认 `Documents\MyComic`）中的下载、本地漫画与备份保持原位。如果你安装过更早的按用户安装版本，卸载前请先备份 `%LOCALAPPDATA%\MyComic\userdata`；旧卸载器会删除该目录。

## 从源码构建

前置条件：Windows 10/11（64 位）、[Flutter](https://docs.flutter.dev/get-started/install/windows) **3.47.6**、带 **使用 C++ 的桌面开发** 工作负载的 Visual Studio 2022，以及 Git Bash（依赖补丁脚本需要）。Inno Setup 6 仅在本地编译安装包时需要；CI 会构建正式安装包。

```powershell
# 在仓库根目录：flutter pub get + 应用第三方补丁
.\tool\bootstrap.ps1

# 运行应用
cd my_comic
flutter run -d windows

# 构建 release 可执行文件
flutter build windows --release
# 产物：my_comic\build\windows\x64\runner\Release\MyComic.exe
```

CI 使用的质量门：

```powershell
cd my_comic
dart run slang                 # 重新生成国际化代码
flutter analyze --no-pub
flutter test --no-pub
```

Melos workspace 包位于 `packages/my_comic_*`；vendored 的补丁依赖位于 `third_party/`，由 bootstrap 脚本应用。Windows 安装器定义在 `my_comic/windows/installer/mycomic.iss`。

## 数据与隐私

- **Content root**：默认 `Documents\MyComic`，包含 `downloads`、`autobackup` 与 `local`。卸载应用不会删除它。
- **Program state**：数据库、设置、扩展与缓存随安装目录存放；安装目录对当前用户不可写时（例如 `C:\Program Files`），回退到 `%LOCALAPPDATA%\MyComic\userdata`；卸载应用会删除它们。
- **无遥测**：MyComic 不上报使用统计，也没有账户、云同步、反馈中心或排行榜。只有在你使用在线图源或扩展时才会访问网络；更新检查只查询本仓库的 GitHub Releases。

## 项目结构

```
my_comic/           Flutter 应用（Dart 包名 `my_comic`）
packages/           workspace 包（`my_comic_core`、`my_comic_engine` 等）
native/             原生组件与 Windows 集成
third_party/        依赖的 vendored/补丁源码
ci/                 依赖补丁与 CI 辅助脚本
tool/               bootstrap、审计与开发者脚本
docs/adr/           架构决策记录
```

仓库规则见 [CLAUDE.md](CLAUDE.md)，领域术语见 [GLOSSARY.md](GLOSSARY.md)，Windows-only 与独立身份决策见 [`docs/adr/0024-windows-only-independent-identity.md`](docs/adr/0024-windows-only-independent-identity.md)。上游来源记录见 [UPSTREAM.md](UPSTREAM.md)。

## 许可证

MyComic 基于 **GNU General Public License v3.0** 发布；完整文本见 [LICENSE](LICENSE)。第三方许可证与声明保留在 `third_party/`（含 `LICENSE`、`NOTICE` 与 `PATCHES.md`）以及 [`my_comic/docs/licenses/`](my_comic/docs/licenses/)。

版权 © 2026 Fushi 贡献者；版权 © 2026 MyComic 贡献者。

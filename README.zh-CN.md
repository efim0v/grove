[English](README.md) · [Русский](README.ru.md) · 简体中文

> 本文是[英文 README](README.md) 的译文。英文版可能比译文更新，两者不一致时以英文版为准。

# Grove

**Grove 现在是 [Brow](https://github.com/efim0v/brow) 的一部分。** 从 Brow 0.4.0 起，Grove 的工作区（用 git worktree 在多个仓库上并行运行 Claude Code 会话）直接在 Brow 中运行，名为 Workspaces。

```sh
brew install --cask efim0v/tap/brow
```

或下载 **[Brow.zip](https://github.com/efim0v/brow/releases/latest/download/Brow.zip)** · macOS 26 或更高版本，Apple 芯片 · [安装说明](https://github.com/efim0v/brow/blob/main/README.zh-CN.md#安装)

## 东西都去了哪里

- **Workspaces** 从菜单栏中 Brow 的图标（带两个点的刘海）打开，也可以点击刘海面板上叠放方块的按钮打开：项目、工作区、会话、**Resume as…**、**Migrate to…**、**Share**、提交图和代码统计都在那里。
- **你的项目、账号和设置会自动迁移。** Brow 会在 `~/Library/Application Support/Grove` 中找到 Grove 的 `config.json`，并据此开启 Workspaces。没有任何文件被移动，Grove 捕获过的状态栏也照常工作。
- **命令行工具现在叫 `brow`**，`grove` 保留为它的第二个名字，所以你的脚本无需修改：运行 `brew install efim0v/tap/brow-cli`；如果装过 Grove 的命令行工具，请先运行 `brew uninstall grove-cli`。
- **Grove.app 可以删除了。** 先退出它：它运行期间，Workspaces 会等待并提供 **Quit Grove**，以免两者同时写同一批文件。然后删除它，或运行 `brew uninstall --cask grove`，但不要加 `--zap`：加了它，Brow 现在使用的文件夹也会被移到废纸篓。如果你把 Grove 加入过登录项，请改为在 Brow 中开启 **Launch at login**。

其他变化见[从 Grove 迁移](https://github.com/efim0v/brow/blob/main/README.zh-CN.md#从-grove-迁移)，例如刘海会读取每个账号的限额，而 Grove 从不这样做。网站：[efimov.page/brow/zh-cn](https://efimov.page/brow/zh-cn/)。

Grove 的最后一个版本 [0.2.2](https://github.com/efim0v/grove/releases/tag/0.2.2) 会继续保留，供参考；本仓库中的代码也一样。如果不打算改用 Brow、只想卸载 Grove，请按照[该版本 README 中的卸载步骤](https://github.com/efim0v/grove/blob/0.2.2/README.zh-CN.md#卸载)操作。

## 许可证

[GNU GPL v3](LICENSE)。0.2.0 及更早的版本以 MIT 许可证发布。

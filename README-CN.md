**Language / 语言：** [English](README.md) | [简体中文](README-CN.md)

# Umbriel Sink

Umbriel Sink 是一项关于平铺桌面交互的实验，受到[这场关于桌面体验的讲座](https://www.youtube.com/watch?v=V7AfAcQwLW0)启发。
它尝试验证一种对 Tiling 布局的补充：桌面怎样保存和表达用户刚刚离开的工作上下文，
让它们暂时离开当前工作面，却不从认知空间里彻底消失？

项目将这个问题收束为**短期工作上下文的挂起与恢复**，并以 [Umbriel](README-UMBRIEL.md) 为实验载体，
通过可恢复的 Sink/Pull 深度栈给出一种具体回答。本项目不是 Noctalia 官方版本；
上游说明及常规构建、依赖文档保留在 [README-UMBRIEL.md](README-UMBRIEL.md)。

> **AI 参与声明：** 本 fork 的 Sink/Pull 功能、相关测试与脚本，以及本文档，均有 AI（OpenAI Codex）参与编写和修改。
> 使用前请结合实际设备与工作流自行检查；上游 Umbriel 的原始内容不应归因于本 fork 或 AI。

## Sink 能做什么

- `window-sink` 把当前焦点窗口压入所在 Workspace 的栈；`window-pull` 按后进先出顺序恢复栈顶窗口。
- Sunk 窗口保留原本的平铺/浮动归属、适用的窗口状态与 Workspace 占用，但不再接收普通输入或焦点。
  画面使用整窗投影表达深度，不为了缩小画面而要求客户端 resize。
- 默认显示栈顶两层：深度 0 的缩放/透明度为 `0.93 / 0.82`，深度 1 为 `0.85 / 0.45`；
  更深的窗口仍在逻辑栈中，但默认越过可见边界（Horizon）。
- Pull 后投影返回正常位置，并等待兼容的客户端提交后恢复焦点；显式激活 Sunk 窗口或在 Overview 中选择它，
  可以逐层解除覆盖它的 Sink 状态。
- `visible_depth` 可把可见层数设为 1–4；`levels` 可设置每层缩放、透明度与 Self Blur 强度。
  Self Blur 是可选的实验功能，默认关闭。

![Umbriel Sink 桌面演示截图](docs/media/sink_demonstration.png)

## 快速使用

按下文安装独立会话后，在登录界面选择 **Umbriel Sink**，不影响另行安装的官方 **Umbriel**。
仅编译源码不会自动更新已安装的会话二进制。

在 fork 专用配置 `~/.config/umbriel-sink/config.toml` 中绑定未占用的按键，例如：

```toml
[include]
files = ["../umbriel/config.toml"]

[keybinds]
"Mod+Alt+Down" = "window-sink"
"Mod+Alt+Up" = "window-pull"
```

若已有官方配置，这里的相对 `include` 让独立会话沿用原有主题、快捷键和窗口规则；
没有官方配置时，请删除 `[include]` 并参考[完整示例配置](examples/config.toml)。
新增的 Sink/Pull 绑定只留在 fork 专用文件中，不要写进两种会话共用的键位文件：
上游 Umbriel 不认识这两个动作。
示例键位并非全局安全默认值，请先检查自己的配置是否已占用。仓库的完整示例配置
也包含 Sink/Pull 绑定；按键选择应以自己的配置为准。

也可以从独立会话的终端直接发送动作，不依赖键位：

```sh
~/.local/libexec/umbriel-sink/umbriel-sink msg window-sink
~/.local/libexec/umbriel-sink/umbriel-sink msg window-pull
~/.local/libexec/umbriel-sink/umbriel-sink windows --json
```

`windows --json` 的 `sunk` 与 `sink_depth` 反映逻辑状态；`sink_depth = 0` 是栈顶，
并不代表任意深度都可见。更多动作和 IPC 字段见[动作](docs/user/actions.md)与 [IPC](docs/user/ipc.md) 文档。

## 调整可见层数和外观

以下配置可追加到 fork 专用配置；如果文件中已有 `[appearance.sink]`，请合并到同一个表，而不要重复声明：

```toml
[appearance.sink]
visible_depth = 2
levels = [
  { scale = 0.93, opacity = 0.82, blur_strength = 0.5 },
  { scale = 0.85, opacity = 0.45, blur_strength = 1.0 },
]
self_blur = false
blur_radius = 6
blur_samples = 9
```

`visible_depth = 2` 是推荐的默认值；不写 `visible_depth` 或 `levels` 时也会使用这套内建样式。
提供 `levels` 时，数组至少要有 `visible_depth` 个完整条目；`scale` 限于 0.1–1，
`opacity` 和 `blur_strength` 限于 0–1。
`blur_strength` 仅在 `self_blur = true` 时影响模糊，不会自行打开 Self Blur。三至四层尤其配合模糊
可能增加 GPU 开销；现有性能测量主要覆盖默认两层，不能直接推断扩展层数的成本。
修改后可执行以下命令热重载：

```sh
~/.local/libexec/umbriel-sink/umbriel-sink validate -c ~/.config/umbriel-sink/config.toml
~/.local/libexec/umbriel-sink/umbriel-sink msg config-reload
```

详细默认值与限制见[外观配置](docs/user/appearance.md)。

## 构建与独立会话路径

首次构建可沿用上游 [README-UMBRIEL.md](README-UMBRIEL.md#building) 的依赖说明。
本 fork 的独立会话使用专门的 Release 构建，不运行 `just install` 去覆盖官方 Umbriel：

```sh
meson setup build-sink-release --buildtype=release -Db_lto=true -Dtests=disabled -Dcpp_std=c++23 --prefix="$HOME/.local"
meson compile -C build-sink-release umbriel
```

已有 `build-sink-release/` 时只需第二条命令。安装前请先退出正在运行的 Umbriel Sink 会话；
下列路径是建议的独立安装布局，不会替代官方 Umbriel。

| 仓库文件 | 建议安装位置 / 用途 |
| --- | --- |
| `build-sink-release/umbriel` | `~/.local/libexec/umbriel-sink/umbriel-sink`，独立合成器二进制 |
| [`tools/sink-session/start-umbriel-sink`](tools/sink-session/start-umbriel-sink) | `~/.local/bin/start-umbriel-sink`，登录启动器 |
| [`tools/sink-session/umbriel-sink.service`](tools/sink-session/umbriel-sink.service) | `~/.config/systemd/user/umbriel-sink.service`，用户服务 |
| [`tools/sink-session/umbriel-sink.desktop.in`](tools/sink-session/umbriel-sink.desktop.in) | 登录界面入口模板，安装时生成用户专属的 `Exec` 路径 |
| [`tools/sink-session/install-session-entry.sh`](tools/sink-session/install-session-entry.sh) | 渲染模板，并以管理员权限安装独立会话入口 |
| fork 专用配置 | `~/.config/umbriel-sink/config.toml`，可 `include` 官方配置 |

首次安装时，先准备上文的 fork 专用配置，然后把二进制、启动器和用户服务安装到表中路径：

```sh
install -Dm755 build-sink-release/umbriel "$HOME/.local/libexec/umbriel-sink/umbriel-sink"
install -Dm755 tools/sink-session/start-umbriel-sink "$HOME/.local/bin/start-umbriel-sink"
install -Dm644 tools/sink-session/umbriel-sink.service "$HOME/.config/systemd/user/umbriel-sink.service"
systemctl --user daemon-reload
```

会话入口由模板生成，不在仓库里保存任何人的 home 目录路径。可先预览渲染结果，
确认无误后安装：

```sh
tools/sink-session/install-session-entry.sh --render
tools/sink-session/install-session-entry.sh
```

脚本默认从 `$HOME` 解析 `~/.local/bin/start-umbriel-sink`，运行时才写入系统会话目录；
若启动器位于别处，可把不含空格或特殊符号的绝对路径作为脚本参数。
脚本会调用 `sudo`，不会覆盖官方会话项。
[`tools/sink-session/README.md`](tools/sink-session/README.md) 说明会话隔离与路径细节。
登录入口和 fork 服务不会修改官方
`umbriel.desktop`、`umbriel.service`、`start-umbriel` 或官方配置文件。

## 代码、测试与现状

Sink 栈和投影主要位于 `src/workspace/sink_stack.h`、`src/workspace/sink_presentation.h`、
`src/workspace/workspace.cpp` 与 `src/scene/window_projection.*`；配置解析在 `src/config/`，
Self Blur 渲染在 `umbrielfx/`。专项脚本位于 `tests/harness/checks/155_sink_logic.sh`、
`156_sink_projection.sh`、`158_sink_self_blur.sh`、`159_sink_performance_matrix.sh`；
真实应用试运行脚本为 [`tests/manual/sink_real_apps.sh`](tests/manual/sink_real_apps.sh)。

```sh
just test debug
just check 155_sink_logic 156_sink_projection 158_sink_self_blur
```

GPU harness 需要可用的 DRM render node；只有构建或纯逻辑单测通过，不等于实际 GPU/原生 seat 验收。
核心 Sink/Pull MVP 已完成；Self Blur 和多层可见深度仍处于个人试用与性能调优阶段。
上游许可见 [LICENSE](LICENSE)；此 fork 的变更同样应遵守仓库许可证。

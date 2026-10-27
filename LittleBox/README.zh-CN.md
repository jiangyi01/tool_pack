# LittleBox 📦

[English](README.md) · **简体中文**

刘海屏菜单栏助手。菜单栏保持原样，LittleBox 不会隐藏任何图标。被刘海挡住、或者菜单栏放不下的图标，会出现在 📦 下面的小条里，外观和菜单栏上一模一样。

## 用法

- **鼠标移到 📦 上**：小条落下，里面是当前这块屏幕放不下的图标。
- **鼠标停在小条里的某个图标上**：直接打开它自己的菜单，无需点击。横向滑到另一个图标，菜单会跟着切换，和真正的菜单栏一样。
- 点击、右键点击、⌥点击也照常可用。
- **右键 📦**：打开设置（权限、悬停开关、开机启动）。

如果某个图标点一下就会执行动作（而不是弹出菜单），LittleBox 连续两次悬停都没看到菜单后会记住它，以后悬停不再触发，仍可以点击使用。设置里可以随时重置。Apple 自带的图标（控制中心等）不会被这样记住。

Electron 应用（例如 Claude 桌面版）的菜单栏图标不响应辅助功能操作，所以悬停打不开它们，小条底部会提示「需要点击打开」。点击时，LittleBox 会去点它在其他显示器上可见的那份副本；如果哪块屏幕上都看不到它，就无法打开。

如果某个图标被挡住了，而它的 App 又不支持辅助功能操作，小条底部会提示：按住 ⌘，把它拖到菜单栏右侧的可见区域。

## 适配

- 不写死屏幕尺寸和位置：刘海位置从系统读取，每块显示器分别判断哪些图标被挡住。外接显示器上能放下的图标，在那块屏幕的盒子里不会出现。
- 支持 macOS 14 及以上。通用二进制，Apple 芯片和 Intel 都能运行。
- 界面跟随系统语言：中文系统显示中文，其它显示英文。

## 构建与安装

```bash
./build_app.sh --run          # 构建并安装到 ~/Applications，然后启动
./build_app.sh --zip          # 另外生成 dist/LittleBox.zip，可以拷到别的 Mac
```

使用 ad-hoc 签名。macOS 会把权限绑定到这次构建的签名上，所以每次重新构建后权限都会失效。`build_app.sh` 会顺手清掉 LittleBox 自己的旧授权记录，下次启动时，在设置窗口里点「开启…」重新授权即可。如果开关已经打开却仍不生效，设置窗口会提示你用 − 删掉 LittleBox 再拖回列表。

拷到另一台 Mac 时，先解压 `LittleBox.zip`，把它放进「应用程序」，然后执行：

```bash
xattr -dr com.apple.quarantine /Applications/LittleBox.app
```

首次打开后，在设置窗口里授予权限即可。

## 权限

- **辅助功能**（必需）：用来找到菜单栏图标，并替你打开它们。
- **屏幕录制**（推荐）：让盒子里的图标和菜单栏上一模一样，包括 971、A 57 · B 67 这类文字和数字。没有这个权限时，会显示 App 图标加上图标自带的文字。

## 工作原理

- 通过辅助功能 API 读取每个 App 的 `AXExtrasMenuBar`，再结合 CGWindowList 判断每个图标在哪块屏幕上被系统隐藏。在 macOS 26 上，每块显示器都有一份图标窗口的副本，被刘海挡住的副本会被移出屏幕。
- 打开图标用的是辅助功能动作：菜单用 `AXPress`/`AXShowMenu` 打开，用 `AXCancel` 关闭。整个过程不移动鼠标，被刘海挡住的图标也能打开。只有在 App 不响应辅助功能时，才退回到模拟点击。

## 调试

```bash
open "littlebox://diagnose"   # 写入 ~/Library/Logs/LittleBox/diagnostics.txt
open "littlebox://open"       # 打开小条
open "littlebox://settings"   # 打开设置
.build/release/LittleBox --preview out.png [--dark] [--wide] [--footer]   # 离线渲染小条，用来检查排版
.build/release/LittleBox --selftest                                        # 自检（无需任何权限）
```

每次打开或关闭图标，都会记录在 `~/Library/Logs/LittleBox/events.log` 里（超过 500 KB 自动清空），方便事后排查。

```bash
tail -50 ~/Library/Logs/LittleBox/events.log
```

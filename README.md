# MacDisplay

MacDisplay 是一个独立的 macOS 菜单栏应用。当前优先实现开盖使用外屏时软断开内建屏，并继续以 [BetterDisplay 官方功能对照](https://betterdisplay.pro/guide/licensing/free-and-pro-features/) 中的免费功能作为基础版验收范围。

## 构建和打开

需要 macOS 14 或更新版本，以及 Xcode Command Line Tools（或完整 Xcode）。在项目目录运行：

```sh
./build.sh
open build/MacDisplay.app
```

构建脚本会为当前 Mac 的架构编译并进行本地签名。升级前请通过菜单栏退出旧版本。启动后，左键或右键点击菜单栏的显示器图标即可打开控制面板。面板会读取外屏的 DDC/CI 硬件亮度，松开滑块后应用，并提供内建屏断开或重连。点「显示设置…」打开完整的控制窗口。

如需登录 macOS 后自动打开菜单栏图标，请在「应用」页的「启动」一栏打开「登录时启动 MacDisplay」。如果 macOS 要求批准，可从同一位置打开系统的登录项设置。

控制窗口的「显示」页将硬件亮度和额外调暗放在顶部，下方提供内建屏断开与重连、分辨率和刷新率。硬件滑块松开即应用，同一台外屏的硬件亮度读数在菜单栏与设置页共用。「额外调暗」从 0% 起，表示未额外调暗。点击折叠项所在整行即可展开。「诊断」页显示当前显示器信息并提供 EDID 导出。「应用」页提供登录自启、版本号、开源组件信息和 GitHub 正式版本的手动更新检查。

## 开盖时只用外屏

1. 开盖并连接一台正在显示扩展桌面的实体外屏。
2. 在菜单栏选择「断开 MacBook 内建屏」，或在控制窗口的「显示」页点击同名按钮。
3. 在外屏弹窗中，于 15 秒倒计时结束前点击「保留仅外屏」。点击「恢复内建屏」、关闭弹窗或不作确认，MacDisplay 会尝试重新连接内建屏。

选择「重新连接内建屏」可随时恢复。断开后拔掉最后一台可用外屏、合盖再开盖，或在开盖时退出 MacDisplay，也会尝试恢复。切换仅作用于当前登录会话。此功能使用 macOS 未公开的显示连接接口，当前只向支持的 Apple Silicon MacBook 开放，基础款 Apple M3 暂不提供断开操作。

## 开盖时手动断开外屏

内建屏正在显示扩展桌面时，打开菜单栏，选择与亮度滑块同一台外屏的「断开」按钮。在内建屏上于 15 秒内点击「保持断开」。取消或超时会尝试恢复外屏。之后可以在菜单栏手动重新连接，合盖或退出应用时也会尝试恢复。

## 命令行诊断

```sh
./build/MacDisplay.app/Contents/MacOS/MacDisplay --list-displays
./build/MacDisplay.app/Contents/MacOS/MacDisplay --list-modes 3
./build/MacDisplay.app/Contents/MacOS/MacDisplay --read-ddc 3
./build/MacDisplay.app/Contents/MacOS/MacDisplay --built-in-status
```

将示例中的 `3` 换成实际显示器 ID。DDC/CI 后端使用内置的 [m1ddc](https://github.com/waydabber/m1ddc)，版本和本地修改记录在 `Vendor/m1ddc/REVISION`。它仅随 Apple Silicon 构建打包。硬件控制还取决于显示器、连接线和转接设备。

## 免费功能验收

| 类别 | 当前已有 | 待补齐 |
| --- | --- | --- |
| 显示模式 | 菜单栏入口、每屏分辨率和刷新率、macOS 已提供的 HiDPI 模式、15 秒确认与回退 | 分辨率滑块、额外和 NTSC 刷新率、支持硬件的输出色彩模式、自定义缩放分辨率、原生和默认分辨率覆盖、应用内显示器改名 |
| 布局和屏幕 | 在「诊断」中列出当前显示器 | 可视化排列和屏上引导、缺口隐藏、可调圆角、预设虚拟屏 |
| 硬件亮度和 DDC/CI | Apple Silicon 兼容连接的亮度、对比度、音量、RGB 增益及逐项读值检测 | Intel、特殊 HDMI 与 DisplayLink 兼容性，输入源和自定义名称、DDC 电源、原生 Apple 亮度协议及按连接自动配置 |
| 软件画面 | 独立或同步调整扩展屏的软件亮度，覆盖层范围为 10%–100% | 色表调光、硬件与软件联合调光、调至全黑、软件对比度、截图时隐藏覆盖层 |
| 色彩 | — | ICC 配置与 XDR 预设选择、ICC 微调与保存、电视 Night Shift |
| 音频 | 兼容显示器上的 DDC/CI 音量 | 可用输出的软件音量与静音、增益、低音和高音、音频电平表、软硬件联合音量 |
| 按键和界面 | 原生菜单栏与控制窗口 | 亮度和音量键、基础自定义快捷键及各访问模式、原生和自定义 OSD、亮度 nits、灵动岛与菜单栏反馈、触控布局和手势、可选侧栏、菜单栏右键动作 |
| 电视和音响 | — | HDMI-CEC（含命令行）、LG webOS、Samsung Tizen、Philips Android TV、Yamaha AVR、浮动遥控器 |
| 诊断和集成 | 命令行读取显示器、显示模式和 DDC/CI 值，兼容 Apple Silicon 外屏可在「诊断」导出 EDID | 扩展诊断和环境光读数、内置控制台与日志、操作型 CLI、脚本、URL、HTTP、通知、快捷指令、外部 HUD，以及连接、断开、睡眠和唤醒动作 |
| 特定 MacBook | — | 支持机型上的 Apple 标志亮度和内容联动环境光 |

## 显示器软断开

内建屏和外屏软断开是目前移植的 Pro 功能。显示模式使用 [Quartz Display Services](https://developer.apple.com/documentation/coregraphics/quartz-display-services)。

## 许可证

MacDisplay 自身的代码采用 [MIT 许可证](LICENSE)。内置的 m1ddc 保留其[原始版权与 MIT 许可声明](Vendor/m1ddc/LICENSE)。

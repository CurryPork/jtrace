# 韭迹 JTtrace

一个给上班摸鱼时看盘用的 macOS 原生小工具。

它是用 SwiftUI 做的 DMG 安装版客户端，主打轻量、悬浮、低打扰，适合把自选股挂在桌面边上偷偷瞄一眼。

## 下载客户端

- 最新 DMG 下载：
  [JTtrace-macos.dmg](https://github.com/CurryPork/jtrace/releases/latest/download/JTtrace-macos.dmg)

## 这是什么

JTtrace 是一个 macOS 原生看盘应用，目前主要提供这些能力：

- 自选股列表
- 按股票名称 / 代码模糊搜索
- 默认拉取东财接口行情
- 手动刷新和自动刷新
- 置顶悬浮窗
- 摸鱼模式透明度调节
- 本地保存自选股票代码

## 安装方式

1. 下载上面的 `JTtrace-macos.dmg`
2. 打开 DMG
3. 把 `JTtrace.app` 拖到 `Applications`
4. 从启动台或应用程序目录打开

## 开发说明

项目基于 Xcode 原生 macOS App 工程，核心目录：

- `jtrace/`：应用源码
- `jtrace.xcodeproj/`：Xcode 工程
- `scripts/package_release.sh`：本地构建并打包 DMG 的脚本

## 说明

当前版本主要偏向个人轻量使用场景，先把“好用、顺手、隐蔽”这件事做好，再慢慢补更多看盘能力。

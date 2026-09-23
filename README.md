# 启动台 · LaunchpadBack

> macOS 26 / 27 移除了“启动台”（Launchpad）。这是一个原生 SwiftUI + AppKit 的开源复刻版本，按 macOS 15 启动台 1:1 还原，并可选开启 macOS 26+ 的液态玻璃（Liquid Glass）效果。
>
> macOS 26/27 removed Launchpad. **LaunchpadBack** is an open-source, native SwiftUI + AppKit re-creation that matches the macOS 15 Launchpad 1:1, with an optional Liquid Glass look on macOS 26+.

## 功能 Features

| 操作 | 效果 |
|---|---|
| 点 Dock 图标 / 快捷键（默认 F4） | 打开 / 关闭启动台，程序坞和菜单栏自动隐藏 |
| 单击 App | 打开并退出启动台 |
| 单击空白 / Esc | 关闭 |
| 触控板滑动 / 鼠标滚轮 / 拖动空白处 / 点页点 | 翻页（带回弹） |
| 长按图标 / 按住 ⌥ | 抖动编辑模式；App Store 应用显示删除按钮 |
| 拖动图标 | 重新排序，拖到屏幕边缘自动翻页 |
| 把 App 拖到另一个 App / 文件夹上 | 创建文件夹（按 App Store 分类自动命名）/ 加入文件夹 |
| 文件夹 | 最多 4 行一页，可重命名；只剩 1 个 App 时自动解散 |
| 直接打字 | 搜索，支持中文、拼音全拼和首字母（如 `wx` → 微信） |
| 方向键 / ⌘←→ / 回车 | 键盘选择、翻页、打开 |

- 布局尺寸按 Apple 官方 macOS 15 截图的屏幕比例测量，任意分辨率一致
- 背景为模糊后的当前桌面墙纸（支持 macOS 26 的 `.madesktop` 墙纸）
- Dock 菜单：网格大小（7×5 默认，可选 8×5 / 8×6 / 9×6 …）、快捷键、液态玻璃效果、登录时打开、重新扫描、重置布局
- 布局保存在 `~/Library/Application Support/LaunchpadClassic/layout.json`

## 系统要求 Requirements

- macOS 14 或更高（液态玻璃效果需要 macOS 26+，并用 26+ SDK 编译）
- Xcode 命令行工具：`xcode-select --install`

## 构建 Build

```bash
git clone https://github.com/<you>/LaunchpadBack.git
cd LaunchpadBack
bash build.sh --install     # 编译 → 安装到 /Applications/启动台.app → 启动
bash build.sh --dist        # 生成 build/启动台.zip（Apple 芯片 + Intel 通用二进制）
```

也可以在 Finder 里双击 `build.command`（安装）或 `dist.command`（打包）。
构建脚本直接调用 `swiftc`，不依赖 SwiftPM；`Package.swift` 仅用于在 Xcode 中打开。

## 首次打开 First launch

应用未使用付费开发者证书签名。下载的版本首次打开时：

- 系统设置 › 隐私与安全性 › 点击“仍要打开”；或
- 若提示“已损坏”：`xattr -dr com.apple.quarantine /Applications/启动台.app`

建议在 Dock 中右键图标 › 选项 › 在 Dock 中保留。

## 代码结构 Structure

```
Sources/LaunchpadBack/
  App.swift              入口、Dock 菜单、鼠标/键盘/滚动事件
  WindowController.swift 全屏窗口、显示/隐藏、墙纸模糊
  LaunchpadModel.swift   状态机：分页、拖拽、文件夹、搜索、键盘
  Views.swift            SwiftUI 视图（图标、文件夹、搜索框、页点、液态玻璃）
  GridMetrics.swift      按 macOS 15 实测比例计算的网格尺寸 / 命中测试
  AppScanner.swift       扫描 /Applications、/System/Applications、~/Applications
  LayoutStore.swift      布局持久化与合并
  HotKey.swift           全局快捷键（Carbon）
```

## 声明 Disclaimer

本项目与 Apple 无关。“Launchpad / 启动台”、macOS 为 Apple Inc. 的商标。仓库中的应用图标为原创绘制，不包含任何 Apple 素材。

Not affiliated with Apple. Launchpad and macOS are trademarks of Apple Inc. The bundled icon is original artwork; no Apple assets are included.

## 协议 License

[MIT](LICENSE)

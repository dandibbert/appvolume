# AppVolume

macOS 菜单栏应用：分应用调节音量（0–200%）、静音，并按应用记住设置。需要 macOS 14.2 或更高版本。

- M1 构建在 [`dandibbert/mac-build-hub`](https://github.com/dandibbert/mac-build-hub) 的 `AppVolume macOS build` 工作流里手动触发，填本仓库的完整 commit SHA。用个人证书签名，产物是 DMG 和 ZIP。
- 本地打包：`bash scripts/package.sh`（默认临时签名，产物在 `dist/`）。
- 图标由 `Resources/AppIcon.svg` 渲染成 `Resources/AppIcon.png`，打包时再生成 `.icns`。

实现：用 Core Audio process tap 把目标应用原本的输出静音，再把采到的音频乘以增益写回默认输出设备。
第一次调节音量时需要允许“系统音频录制”权限。

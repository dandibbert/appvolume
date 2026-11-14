# AppVolume

macOS 菜单栏应用：分应用调节音量（0–200%）、静音、定时静音、指定输出设备，并按应用记住设置。需要 macOS 14.2 或更高版本。

音量模型和 Windows 音量合成器一样：总音量按比例作用在所有应用上（实际音量 = 总音量 × 应用音量），总静音优先于各应用的设置，调总音量不会改动各应用自己的音量。超过 100% 的部分经过限幅器，不会削波失真。可以在设置菜单里打开全局快捷键：⌃⌥⌘↑ / ⌃⌥⌘↓ 调总音量，⌃⌥⌘M 全部静音。

- M1 构建在 [`dandibbert/mac-build-hub`](https://github.com/dandibbert/mac-build-hub) 的 `AppVolume macOS build` 工作流里手动触发，填本仓库的完整 commit SHA。用个人证书签名，DMG 和 ZIP 发到本仓库的 [Releases](https://github.com/dandibbert/appvolume/releases)。
- 推送到 `main` 或 `claude/**` 分支时，本仓库的 `Build` 工作流会自动构建一份临时签名的包，供检查用。
- 本地打包：`bash scripts/package.sh`（默认临时签名，产物在 `dist/`）。
- 图标由 `Resources/AppIcon.svg` 渲染成 `Resources/AppIcon.png`，打包时再生成 `.icns`。

实现：用 Core Audio process tap 把目标应用原本的输出静音，再把采到的音频乘以增益写到默认（或该应用指定的）输出设备。重建、撤销 tap 时交叉淡化，不会漏音或突变。
第一次调节音量时需要允许“系统音频录制”权限。

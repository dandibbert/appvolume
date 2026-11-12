import AppKit
import ServiceManagement
import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var manager: AudioManager
    @AppStorage("showOtherApps") private var showOthers = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 0) {
            header
            masterRow
            Divider()
                .padding(.bottom, 6)
            if manager.permission != .authorized {
                PermissionBanner()
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
            if let error = manager.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            content
                .disabled(!manager.isEnabled)
                .opacity(manager.isEnabled ? 1 : 0.4)
            Divider()
            footer
        }
        .frame(width: 340)
        .focusEffectDisabled()   // 面板一打开，第一个按钮会被套上蓝色焦点框
        .onAppear {
            manager.refresh()
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 6) {
            Text("应用音量")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if let device = manager.outputDeviceName {
                Label(device, systemImage: "hifispeaker.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("当前输出设备")
            }
            Toggle("启用", isOn: Binding(
                get: { manager.isEnabled },
                set: { manager.setEnabled($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(manager.isEnabled ? "关闭后所有应用恢复原始音量，设置会保留" : "打开后恢复各应用的音量设置")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - 总音量

    private var masterRow: some View {
        let volume = Binding<Double>(
            get: { Double(manager.masterVolume) },
            set: { manager.setMasterVolume(Float($0)) })
        let percent = Int((manager.masterVolume * 100).rounded())
        let muted = manager.masterMuted

        return HStack(spacing: 8) {
            Button {
                manager.setMasterMuted(!muted)
            } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(muted ? Color.red : Color.secondary)
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(muted ? "取消全部静音" : "全部静音")

            Text("总音量")
                .font(.system(size: 12, weight: .medium))

            VolumeSlider(value: volume, dimmed: muted)
                .help("拖动会覆盖下面每个应用的音量")

            Text(muted ? "静音" : "\(percent)%")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(muted ? Color.red : (manager.masterVolume > 1 ? Color.orange : Color.secondary))
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .disabled(!manager.isEnabled)
        .opacity(manager.isEnabled ? 1 : 0.4)
    }

    // MARK: - 列表

    @ViewBuilder
    private var content: some View {
        let active = manager.activeApps
        let others = manager.otherApps

        if active.isEmpty && others.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    if active.isEmpty {
                        Text("还没有应用在播放声音")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                    }
                    ForEach(active) { AppRow(app: $0) }

                    if !others.isEmpty {
                        Button {
                            showOthers.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .rotationEffect(.degrees(showOthers ? 90 : 0))
                                Text("其他应用")
                                Text("\(others.count)")
                                    .foregroundStyle(.tertiary)
                                Spacer()
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if showOthers {
                            ForEach(others) { AppRow(app: $0) }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .frame(height: min(listHeight(active: active.count, others: others.count), 440))
        }
    }

    private func listHeight(active: Int, others: Int) -> CGFloat {
        let rows = active + (showOthers ? others : 0)
        var height = CGFloat(rows) * (AppRow.height + 2) + 6
        if active == 0 { height += 44 }
        if others > 0 { height += 30 }
        return height
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "speaker.zzz")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("还没有应用在播放声音")
                .font(.system(size: 13, weight: .medium))
            Text("应用开始播放后会出现在这里")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: - 底部

    private var footer: some View {
        HStack {
            Text(manager.isEnabled ? "拖动调节，最高 200%" : "已关闭，所有应用按原始音量播放")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
            Menu {
                Toggle("登录时启动", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }))
                Button("全部还原为 100%") { manager.resetAll() }
                    .disabled(!manager.hasCustomSettings)
                Divider()
                Button("关于 AppVolume") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
                Button("退出 AppVolume") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("设置")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("AppVolume: launch at login failed: %@", String(describing: error))
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// 没有“系统音频录制”权限时的引导卡片。
struct PermissionBanner: View {
    @EnvironmentObject var manager: AudioManager

    var body: some View {
        let denied = manager.permission == .denied
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: denied ? "exclamationmark.lock.fill" : "waveform.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(denied ? Color.orange : Color.accentColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(denied ? "没有系统音频录制权限" : "需要系统音频录制权限")
                        .font(.system(size: 12, weight: .semibold))
                    Text(denied
                         ? "请在“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”中允许 AppVolume，否则音量设置不会生效。"
                         : "AppVolume 通过接管应用的音频输出来调节音量，不会录制或保存任何声音。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                if denied {
                    Button("打开系统设置") { NSWorkspace.shared.open(AudioPermission.settingsURL) }
                } else {
                    Button("授权") { manager.requestPermission() }
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06)))
    }
}

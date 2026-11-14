import SwiftUI

struct AppRow: View {
    static let height: CGFloat = 58
    private static let timedMuteMinutes = [15, 60, 240]

    @EnvironmentObject var manager: AudioManager
    let app: AudioApp
    @State private var isHovered = false

    var body: some View {
        let setting = manager.setting(for: app.id)
        let masterMuted = manager.masterMuted
        let silent = setting.muted || masterMuted
        let volume = Binding<Double>(
            get: { Double(setting.volume) },
            set: { manager.setVolume(Float($0), for: app.id) })
        let percent = Int((setting.volume * 100).rounded())

        HStack(spacing: 10) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 32, height: 32)
            .opacity(silent ? 0.5 : 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if app.isPlaying && !silent {
                        Image(systemName: "waveform")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                            .help("正在播放")
                    }
                    if let error = manager.errors[app.id] {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .help(error)
                    }
                    Spacer(minLength: 4)
                    if let route = manager.routedOutput(for: app.id) {
                        Image(systemName: route.connected ? "hifispeaker.fill" : "hifispeaker.slash")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .help(route.connected
                                  ? "输出到“\(route.name)”"
                                  : "“\(route.name)”没有连接，暂时使用系统输出")
                    }
                    if setting.muted, let until = setting.mutedUntil {
                        Image(systemName: "timer")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                            .help("将在 \(until.formatted(date: .omitted, time: .shortened)) 取消静音")
                    }
                    Button {
                        manager.setVolume(1.0, for: app.id)
                    } label: {
                        Text(setting.muted ? "静音" : "\(percent)%")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(percentColor(setting, masterMuted: masterMuted))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(setting.volume > 1 && !silent
                                               ? Color.orange.opacity(0.15) : Color.clear))
                    }
                    .buttonStyle(.plain)
                    .disabled(setting.volume == 1.0)
                    .help("相对于总音量。点击还原为 100%")
                }

                HStack(spacing: 6) {
                    Button {
                        manager.setMuted(!setting.muted, for: app.id)
                    } label: {
                        Image(systemName: speakerSymbol(setting, masterMuted: masterMuted))
                            .font(.system(size: 12))
                            .foregroundStyle(setting.muted ? Color.red : Color.secondary)
                            .frame(width: 20, height: 20, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(muteHelp(setting, masterMuted: masterMuted))

                    VolumeSlider(value: volume, dimmed: silent)

                    optionsMenu(setting)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.06 : 0)))
        .onHover { isHovered = $0 }
    }

    private func optionsMenu(_ s: AppSetting) -> some View {
        let output = Binding<String?>(
            get: { s.outputUID },
            set: { uid in manager.setOutput(manager.outputDevices.first { $0.uid == uid }, for: app.id) })
        let disconnected: String? = s.outputUID.flatMap { uid -> String? in
            manager.outputDevices.contains(where: { $0.uid == uid }) ? nil : uid
        }

        return Menu {
            Picker("输出到", selection: output) {
                Text("跟随系统输出").tag(String?.none)
                ForEach(manager.outputDevices) { device in
                    Text(device.name).tag(Optional(device.uid))
                }
                if let disconnected {
                    Text("\(s.outputName ?? disconnected)（未连接）").tag(Optional(disconnected))
                }
            }
            .pickerStyle(.inline)

            Section("静音") {
                ForEach(Self.timedMuteMinutes, id: \.self) { minutes in
                    Button(minutes < 60 ? "静音 \(minutes) 分钟" : "静音 \(minutes / 60) 小时") {
                        manager.setMuted(true, for: app.id, duration: TimeInterval(minutes * 60))
                    }
                }
                if s.muted {
                    Button("取消静音") { manager.setMuted(false, for: app.id) }
                }
            }

            Divider()
            Button("还原此应用的设置") { manager.resetSetting(for: app.id) }
                .disabled(s.isDefault)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 12))
                .foregroundStyle(s.outputUID != nil ? Color.accentColor : Color.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("输出设备、定时静音")
    }

    private func percentColor(_ s: AppSetting, masterMuted: Bool) -> Color {
        if s.muted { return .red }
        if masterMuted { return .secondary }
        if s.volume > 1 { return .orange }
        return s.volume == 1 ? .secondary : .primary
    }

    private func speakerSymbol(_ s: AppSetting, masterMuted: Bool) -> String {
        if s.muted || masterMuted { return "speaker.slash.fill" }
        if s.volume == 0 { return "speaker.fill" }
        if s.volume < 0.67 { return "speaker.wave.1.fill" }
        if s.volume < 1.34 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private func muteHelp(_ s: AppSetting, masterMuted: Bool) -> String {
        if s.muted { return "取消静音" }
        if masterMuted { return "已全部静音。点击单独静音此应用" }
        return "静音"
    }
}

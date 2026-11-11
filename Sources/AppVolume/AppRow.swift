import SwiftUI

struct AppRow: View {
    static let height: CGFloat = 58

    @EnvironmentObject var manager: AudioManager
    let app: AudioApp
    @State private var isHovered = false

    var body: some View {
        let setting = manager.setting(for: app.id)
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
            .opacity(setting.muted ? 0.5 : 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if app.isPlaying && !setting.muted {
                        Image(systemName: "waveform")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                            .help("正在播放")
                    }
                    Spacer(minLength: 4)
                    Button {
                        manager.setVolume(1.0, for: app.id)
                    } label: {
                        Text(setting.muted ? "静音" : "\(percent)%")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(percentColor(setting))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(setting.volume > 1 && !setting.muted
                                               ? Color.orange.opacity(0.15) : Color.clear))
                    }
                    .buttonStyle(.plain)
                    .disabled(setting.volume == 1.0)
                    .help("点击还原为 100%")
                }

                HStack(spacing: 6) {
                    Button {
                        manager.setMuted(!setting.muted, for: app.id)
                    } label: {
                        Image(systemName: speakerSymbol(setting))
                            .font(.system(size: 12))
                            .foregroundStyle(setting.muted ? Color.red : Color.secondary)
                            .frame(width: 20, height: 20, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(setting.muted ? "取消静音" : "静音")

                    VolumeSlider(value: volume, dimmed: setting.muted)
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

    private func percentColor(_ s: AppSetting) -> Color {
        if s.muted { return .red }
        if s.volume > 1 { return .orange }
        return s.volume == 1 ? .secondary : .primary
    }

    private func speakerSymbol(_ s: AppSetting) -> String {
        if s.muted { return "speaker.slash.fill" }
        if s.volume == 0 { return "speaker.fill" }
        if s.volume < 0.67 { return "speaker.wave.1.fill" }
        if s.volume < 1.34 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

import AppKit
import SwiftUI

/// 0–200% 的音量滑块。100% 处有刻度并带吸附，超过 100% 的部分用橙色表示增益。
struct VolumeSlider: View {
    @Binding var value: Double      // 0 ... 2
    var dimmed = false

    private let maxValue = 2.0
    private let trackHeight: CGFloat = 6
    private let thumbSize: CGFloat = 16
    private let snapRange = 0.04

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let usable = max(geo.size.width - thumbSize, 1)
            let x = CGFloat(value / maxValue) * usable
            let unityX = usable / 2

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: trackHeight)

                // 0–100%
                Capsule()
                    .fill(dimmed ? Color.secondary.opacity(0.5) : Color.accentColor)
                    .frame(width: min(x, unityX) + thumbSize / 2, height: trackHeight)

                // 100–200%
                if value > 1 {
                    Rectangle()
                        .fill(dimmed ? Color.secondary.opacity(0.5) : Color.orange)
                        .frame(width: x - unityX, height: trackHeight)
                        .offset(x: unityX + thumbSize / 2)
                }

                // 100% 刻度
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: 2, height: 12)
                    .offset(x: unityX + thumbSize / 2 - 1)

                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: isDragging ? 3 : 1.5, y: 1)
                    .frame(width: thumbSize, height: thumbSize)
                    .scaleEffect(isDragging ? 1.1 : 1)
                    .offset(x: x)
                    .animation(.easeOut(duration: 0.12), value: isDragging)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        isDragging = true
                        let raw = Double((g.location.x - thumbSize / 2) / usable) * maxValue
                        var v = min(max(raw, 0), maxValue)
                        if abs(v - 1) < snapRange { v = 1 }
                        if v != value {
                            if v == 1 {
                                NSHapticFeedbackManager.defaultPerformer
                                    .perform(.alignment, performanceTime: .now)
                            }
                            value = v
                        }
                    }
                    .onEnded { _ in isDragging = false }
            )
        }
        .frame(height: 20)
        .opacity(dimmed ? 0.6 : 1)
        .accessibilityElement()
        .accessibilityLabel("音量")
        .accessibilityValue("\(Int((value * 100).rounded()))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(value + 0.05, maxValue)
            case .decrement: value = max(value - 0.05, 0)
            @unknown default: break
            }
        }
    }
}

import SwiftUI
import XboxPadNanoFFI

/// Ergonomic, multi-touch virtual Xbox gamepad overlay adapting cleanly to both iPad & iPhone.
/// Automatically scales buttons/thumbsticks to screen height and clears iPhone Dynamic Island / notch.
struct VirtualGamepadOverlay: View {
    @ObservedObject var gamepadManager: GamepadManager
    let opacity: Double

    var body: some View {
        GeometryReader { geo in
            let shortSide = min(geo.size.width, geo.size.height)
            let scale: CGFloat = min(1.0, max(0.68, shortSide / 560.0))
            let horizPad = max(14, max(geo.safeAreaInsets.leading, geo.safeAreaInsets.trailing) + (XboxPlatform.isPhone ? 10 : 20))
            let topPad = max(geo.safeAreaInsets.top + 10, XboxPlatform.isPhone ? 46 : 78)
            let bottomPad = max(geo.safeAreaInsets.bottom + 6, XboxPlatform.isPhone ? 14 : 22)

            VStack(spacing: 0) {
                // Top shoulder & trigger row
                HStack {
                    VStack(spacing: 7 * scale) {
                        triggerHoldButton("LT", isLeft: true, scale: scale)
                        shoulderHoldButton("LB", keyPath: \.left_shoulder, scale: scale)
                    }
                    Spacer()
                    VStack(spacing: 7 * scale) {
                        triggerHoldButton("RT", isLeft: false, scale: scale)
                        shoulderHoldButton("RB", keyPath: \.right_shoulder, scale: scale)
                    }
                }
                .padding(.horizontal, horizPad)
                .padding(.top, topPad)

                Spacer()

                // Lower ergonomic thumb zone
                HStack(alignment: .bottom, spacing: 12 * scale) {
                    // Left side: Left thumbstick + D-pad
                    VStack(alignment: .leading, spacing: 12 * scale) {
                        VirtualThumbstick(label: "LS", scale: scale) { x, y in
                            gamepadManager.setVirtualLeftStick(x: x, y: y)
                        }

                        HStack(spacing: 5 * scale) {
                            padButton("←", keyPath: \.dpad_left, scale: scale)
                            VStack(spacing: 5 * scale) {
                                padButton("↑", keyPath: \.dpad_up, scale: scale)
                                padButton("↓", keyPath: \.dpad_down, scale: scale)
                            }
                            padButton("→", keyPath: \.dpad_right, scale: scale)
                        }
                    }

                    Spacer()

                    // Center system row: View / Xbox / Menu + LS/RS click
                    VStack(spacing: 8 * scale) {
                        HStack(spacing: 8 * scale) {
                            miniPillButton("L3", keyPath: \.left_thumb, scale: scale)
                            miniPillButton("R3", keyPath: \.right_thumb, scale: scale)
                        }
                        HStack(spacing: 8 * scale) {
                            padButton("View", keyPath: \.view, wide: true, scale: scale)
                            Button {
                                gamepadManager.pulseNexusButton()
                            } label: {
                                Image(systemName: "xbox.logo")
                                    .font(scale < 0.85 ? .subheadline : .headline)
                                    .foregroundStyle(.white)
                                    .frame(width: 50 * scale, height: 42 * scale)
                                    .background(XboxTheme.primaryGradient, in: Capsule())
                                    .overlay(Capsule().stroke(Color.white.opacity(0.32), lineWidth: 1))
                            }
                            .simultaneousGesture(
                                LongPressGesture(minimumDuration: 0.7).onEnded { _ in
                                    gamepadManager.holdNexusButton(durationMs: 1200)
                                }
                            )
                            .buttonStyle(.plain)
                            padButton("Menu", keyPath: \.menu, wide: true, scale: scale)
                        }
                    }
                    .padding(.bottom, 4 * scale)

                    Spacer()

                    // Right side: ABXY + Right thumbstick
                    VStack(alignment: .trailing, spacing: 12 * scale) {
                        HStack(spacing: 5 * scale) {
                            padButton("X", keyPath: \.x, accent: Color(red: 0.24, green: 0.58, blue: 0.98), circular: true, scale: scale)
                            VStack(spacing: 5 * scale) {
                                padButton("Y", keyPath: \.y, accent: Color(red: 0.96, green: 0.74, blue: 0.16), circular: true, scale: scale)
                                padButton("A", keyPath: \.a, accent: XboxTheme.emeraldBright, circular: true, scale: scale)
                            }
                            padButton("B", keyPath: \.b, accent: Color(red: 0.94, green: 0.32, blue: 0.34), circular: true, scale: scale)
                        }

                        VirtualThumbstick(label: "RS", scale: scale) { x, y in
                            gamepadManager.setVirtualRightStick(x: x, y: y)
                        }
                    }
                }
                .padding(.horizontal, horizPad)
                .padding(.bottom, bottomPad)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .opacity(max(0.22, min(1.0, opacity)))
    }

    private func shoulderHoldButton(
        _ title: String,
        keyPath: WritableKeyPath<XboxPadInputFrame, UInt8>,
        scale: CGFloat
    ) -> some View {
        Text(title)
            .font((scale < 0.85 ? Font.caption2 : Font.caption).bold())
            .foregroundStyle(.white)
            .frame(width: 72 * scale, height: 34 * scale)
            .background(Color.black.opacity(0.50), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.36), lineWidth: 1.1))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in gamepadManager.setVirtualButton(keyPath, pressed: true) }
                    .onEnded { _ in gamepadManager.setVirtualButton(keyPath, pressed: false) }
            )
    }

    private func triggerHoldButton(_ title: String, isLeft: Bool, scale: CGFloat) -> some View {
        Text(title)
            .font((scale < 0.85 ? Font.caption2 : Font.caption).bold())
            .foregroundStyle(isLeft ? XboxTheme.emeraldBright : XboxTheme.info)
            .frame(width: 78 * scale, height: 38 * scale)
            .background(Color.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 12 * scale, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                    .stroke((isLeft ? XboxTheme.emeraldBright : XboxTheme.info).opacity(0.52), lineWidth: 1.2)
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if isLeft {
                            gamepadManager.setVirtualLeftTrigger(1.0)
                        } else {
                            gamepadManager.setVirtualRightTrigger(1.0)
                        }
                    }
                    .onEnded { _ in
                        if isLeft {
                            gamepadManager.setVirtualLeftTrigger(0.0)
                        } else {
                            gamepadManager.setVirtualRightTrigger(0.0)
                        }
                    }
            )
    }

    private func miniPillButton(
        _ title: String,
        keyPath: WritableKeyPath<XboxPadInputFrame, UInt8>,
        scale: CGFloat
    ) -> some View {
        Text(title)
            .font(.caption2.bold())
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: 44 * scale, height: 28 * scale)
            .background(Color.black.opacity(0.45), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.28), lineWidth: 1))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in gamepadManager.setVirtualButton(keyPath, pressed: true) }
                    .onEnded { _ in gamepadManager.setVirtualButton(keyPath, pressed: false) }
            )
    }

    private func padButton(
        _ label: String,
        keyPath: WritableKeyPath<XboxPadInputFrame, UInt8>,
        wide: Bool = false,
        accent: Color = .white,
        circular: Bool = false,
        scale: CGFloat
    ) -> some View {
        let size = 48 * scale
        let shape = RoundedRectangle(cornerRadius: circular ? (size / 2) : (13 * scale), style: .continuous)
        return Text(label)
            .font((wide || scale < 0.85 ? Font.caption2 : Font.subheadline).bold())
            .foregroundStyle(accent)
            .frame(width: (wide ? 56 : 48) * scale, height: size)
            .background(Color.black.opacity(0.48), in: shape)
            .overlay(shape.stroke(accent.opacity(0.50), lineWidth: 1.2))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in gamepadManager.setVirtualButton(keyPath, pressed: true) }
                    .onEnded { _ in gamepadManager.setVirtualButton(keyPath, pressed: false) }
            )
    }
}

private struct VirtualThumbstick: View {
    let label: String
    let scale: CGFloat
    let onChange: (Float, Float) -> Void

    @State private var knobOffset: CGSize = .zero
    private var baseRadius: CGFloat { 54 * scale }
    private var knobRadius: CGFloat { 24 * scale }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.42))
                .frame(width: baseRadius * 2, height: baseRadius * 2)
                .overlay(Circle().stroke(Color.white.opacity(0.26), lineWidth: 1.4))

            Circle()
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                .frame(width: baseRadius * 1.15, height: baseRadius * 1.15)

            Circle()
                .fill(Color.white.opacity(0.22))
                .frame(width: knobRadius * 2, height: knobRadius * 2)
                .overlay(Circle().stroke(Color.white.opacity(0.65), lineWidth: 1.5))
                .overlay(
                    Text(label)
                        .font(.caption2.bold())
                        .foregroundStyle(.white.opacity(0.85))
                )
                .offset(knobOffset)
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    let maxTravel = baseRadius - knobRadius * 0.45
                    let dist = hypot(dx, dy)
                    let clampedDist = min(dist, maxTravel)
                    let angle = atan2(dy, dx)
                    let cx = dist > 0.001 ? cos(angle) * clampedDist : 0
                    let cy = dist > 0.001 ? sin(angle) * clampedDist : 0
                    knobOffset = CGSize(width: cx, height: cy)
                    let nx = Float(cx / maxTravel)
                    let ny = Float(-cy / maxTravel)
                    onChange(nx, ny)
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.18, dampingFraction: 0.72)) {
                        knobOffset = .zero
                    }
                    onChange(0, 0)
                }
        )
    }
}

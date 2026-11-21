import SwiftUI
import XboxPadNanoFFI

/// Ergonomic, multi-touch virtual Xbox gamepad overlay for iPad.
/// Supports dual floating thumbsticks, D-pad, ABXY, LB/RB/LT/RT, View/Xbox/Menu
/// and dispatches straight to `GamepadManager`'s zero-hop `.userInteractive` input queue.
struct VirtualGamepadOverlay: View {
    @ObservedObject var gamepadManager: GamepadManager
    let opacity: Double

    var body: some View {
        VStack(spacing: 0) {
            // Top shoulder & trigger row
            HStack {
                VStack(spacing: 8) {
                    triggerHoldButton("LT", isLeft: true)
                    shoulderHoldButton("LB", keyPath: \.left_shoulder)
                }
                Spacer()
                VStack(spacing: 8) {
                    triggerHoldButton("RT", isLeft: false)
                    shoulderHoldButton("RB", keyPath: \.right_shoulder)
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 78)

            Spacer()

            // Lower ergonomic thumb zone
            HStack(alignment: .bottom, spacing: 16) {
                // Left side: Left thumbstick + D-pad
                VStack(alignment: .leading, spacing: 14) {
                    VirtualThumbstick(label: "LS") { x, y in
                        gamepadManager.setVirtualLeftStick(x: x, y: y)
                    }

                    HStack(spacing: 6) {
                        padButton("←", keyPath: \.dpad_left)
                        VStack(spacing: 6) {
                            padButton("↑", keyPath: \.dpad_up)
                            padButton("↓", keyPath: \.dpad_down)
                        }
                        padButton("→", keyPath: \.dpad_right)
                    }
                }

                Spacer()

                // Center system row: View / Xbox / Menu + LS/RS click
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        miniPillButton("L3", keyPath: \.left_thumb)
                        miniPillButton("R3", keyPath: \.right_thumb)
                    }
                    HStack(spacing: 10) {
                        padButton("View", keyPath: \.view, wide: true)
                        Button {
                            gamepadManager.pulseNexusButton()
                        } label: {
                            Image(systemName: "xbox.logo")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(width: 50, height: 42)
                                .background(XboxTheme.primaryGradient, in: Capsule())
                                .overlay(Capsule().stroke(Color.white.opacity(0.32), lineWidth: 1))
                        }
                        .simultaneousGesture(
                            LongPressGesture(minimumDuration: 0.7).onEnded { _ in
                                gamepadManager.holdNexusButton(durationMs: 1200)
                            }
                        )
                        .buttonStyle(.plain)
                        padButton("Menu", keyPath: \.menu, wide: true)
                    }
                }
                .padding(.bottom, 6)

                Spacer()

                // Right side: ABXY + Right thumbstick
                VStack(alignment: .trailing, spacing: 14) {
                    HStack(spacing: 6) {
                        padButton("X", keyPath: \.x, accent: Color(red: 0.24, green: 0.58, blue: 0.98), circular: true)
                        VStack(spacing: 6) {
                            padButton("Y", keyPath: \.y, accent: Color(red: 0.96, green: 0.74, blue: 0.16), circular: true)
                            padButton("A", keyPath: \.a, accent: XboxTheme.emeraldBright, circular: true)
                        }
                        padButton("B", keyPath: \.b, accent: Color(red: 0.94, green: 0.32, blue: 0.34), circular: true)
                    }

                    VirtualThumbstick(label: "RS") { x, y in
                        gamepadManager.setVirtualRightStick(x: x, y: y)
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 22)
        }
        .opacity(max(0.22, min(1.0, opacity)))
    }

    private func shoulderHoldButton(_ title: String, keyPath: WritableKeyPath<XboxPadInputFrame, UInt8>) -> some View {
        Text(title)
            .font(.caption.bold())
            .foregroundStyle(.white)
            .frame(width: 72, height: 34)
            .background(Color.black.opacity(0.50), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.36), lineWidth: 1.1))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in gamepadManager.setVirtualButton(keyPath, pressed: true) }
                    .onEnded { _ in gamepadManager.setVirtualButton(keyPath, pressed: false) }
            )
    }

    private func triggerHoldButton(_ title: String, isLeft: Bool) -> some View {
        Text(title)
            .font(.caption.bold())
            .foregroundStyle(isLeft ? XboxTheme.emeraldBright : XboxTheme.info)
            .frame(width: 78, height: 38)
            .background(Color.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
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

    private func miniPillButton(_ title: String, keyPath: WritableKeyPath<XboxPadInputFrame, UInt8>) -> some View {
        Text(title)
            .font(.caption2.bold())
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: 44, height: 28)
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
        circular: Bool = false
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: circular ? 25 : 13, style: .continuous)
        return Text(label)
            .font(wide ? .caption.bold() : .subheadline.bold())
            .foregroundStyle(accent)
            .frame(width: wide ? 56 : 48, height: 48)
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
    let onChange: (Float, Float) -> Void

    @State private var knobOffset: CGSize = .zero
    private let baseRadius: CGFloat = 54
    private let knobRadius: CGFloat = 24

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
                    // Normalized X (+right), Y (+up so GamepadManager negates consistently with GCController)
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

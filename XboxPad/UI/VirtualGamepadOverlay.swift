import QuartzCore
import SwiftUI
#if os(iOS)
import UIKit
#endif
import XboxPadNanoFFI

#if os(iOS)
/// Pre-warmed Taptic Engine feedback helper for crisp, zero-lag virtual gamepad haptics on iPhone.
@MainActor
private final class VirtualGamepadHaptics {
    static let shared = VirtualGamepadHaptics()

    private let heavyGen = UIImpactFeedbackGenerator(style: .heavy)
    private let mediumGen = UIImpactFeedbackGenerator(style: .medium)
    private let rigidGen = UIImpactFeedbackGenerator(style: .rigid)
    private let softGen = UIImpactFeedbackGenerator(style: .soft)
    private let lightGen = UIImpactFeedbackGenerator(style: .light)

    private init() {
        prepareAll()
    }

    func prepareAll() {
        heavyGen.prepare()
        mediumGen.prepare()
        rigidGen.prepare()
        softGen.prepare()
        lightGen.prepare()
    }

    func triggerPress() {
        heavyGen.impactOccurred(intensity: 1.0)
        heavyGen.prepare()
    }

    func buttonPress() {
        mediumGen.impactOccurred(intensity: 0.96)
        mediumGen.prepare()
    }

    func stickGrab() {
        mediumGen.impactOccurred(intensity: 0.82)
        mediumGen.prepare()
    }

    func stickRimBump() {
        rigidGen.impactOccurred(intensity: 0.96)
        rigidGen.prepare()
    }

    func stickDirectionTick() {
        lightGen.impactOccurred(intensity: 0.55)
        lightGen.prepare()
    }

    func stickRelease() {
        softGen.impactOccurred(intensity: 0.58)
        softGen.prepare()
    }
}
#endif

/// Ergonomic, customizable multi-touch virtual Xbox gamepad overlay adapting cleanly to iPad & iPhone:
/// - True native UIKit multi-touch surfaces (`isMultipleTouchEnabled = true`, `isExclusiveTouch = false`)
///   so simultaneous LS + RS + ABXY + LT/RT never drop or steal touches on iOS
/// - Minimum 55ms press latch on virtual buttons so even quick thumb taps always register in 30/60fps Xbox games
/// - Tactile Taptic Engine feedback on buttons, triggers, AND thumbsticks (grab, outer rim bump, sweep ticks, snap-back)
/// - Visual Drag-to-Reposition Layout Editor (`isEditingLayout`) with saved offsets
/// - Floating Thumbstick mode (spawns stick center under finger)
struct VirtualGamepadOverlay: View {
    @ObservedObject var gamepadManager: GamepadManager
    let opacity: Double
    var scaleMultiplier: Double = 1.0
    var floatingStick: Bool = false
    var hapticTap: Bool = true
    @Binding var isEditingLayout: Bool
    @Binding var savedOffsets: [String: [Double]]
    @Binding var savedScales: [String: Double]
    var onDoneEditing: (() -> Void)? = nil

    @State private var liveDragOffsets: [String: CGSize] = [:]
    @State private var selectedClusterId: String = VirtualGamepadCluster.abxy.rawValue

    private func effectiveScale(for id: String, baseScale: CGFloat) -> CGFloat {
        let clusterMul = savedScales[id] ?? 1.0
        return min(1.60, max(0.45, baseScale * CGFloat(scaleMultiplier) * CGFloat(clusterMul)))
    }

    var body: some View {
        GeometryReader { geo in
            let shortSide = min(geo.size.width, geo.size.height)
            let baseScale: CGFloat = min(1.0, max(0.68, shortSide / 560.0))
            let scale = min(1.40, max(0.55, baseScale * CGFloat(scaleMultiplier)))
            let ltLbScale = effectiveScale(for: "lt_lb", baseScale: baseScale)
            let rtRbScale = effectiveScale(for: "rt_rb", baseScale: baseScale)
            let lsScale = effectiveScale(for: "ls", baseScale: baseScale)
            let dpadScale = effectiveScale(for: "dpad", baseScale: baseScale)
            let centerScale = effectiveScale(for: "center", baseScale: baseScale)
            let abxyScale = effectiveScale(for: "abxy", baseScale: baseScale)
            let rsScale = effectiveScale(for: "rs", baseScale: baseScale)
            let horizPad = max(14, max(geo.safeAreaInsets.leading, geo.safeAreaInsets.trailing) + (XboxPlatform.isPhone ? 10 : 20))
            let topPad = max(geo.safeAreaInsets.top + 10, XboxPlatform.isPhone ? 46 : 78)
            let bottomPad = max(geo.safeAreaInsets.bottom + 6, XboxPlatform.isPhone ? 14 : 22)

            ZStack {
                VStack(spacing: 0) {
                    // Top shoulder & trigger row
                    HStack {
                        draggableCluster(id: "lt_lb") {
                            VStack(spacing: 7 * ltLbScale) {
                                triggerHoldButton("LT", isLeft: true, scale: ltLbScale)
                                shoulderHoldButton("LB", keyPath: \.left_shoulder, scale: ltLbScale)
                            }
                        }
                        Spacer()
                        draggableCluster(id: "rt_rb") {
                            VStack(spacing: 7 * rtRbScale) {
                                triggerHoldButton("RT", isLeft: false, scale: rtRbScale)
                                shoulderHoldButton("RB", keyPath: \.right_shoulder, scale: rtRbScale)
                            }
                        }
                    }
                    .padding(.horizontal, horizPad)
                    .padding(.top, topPad)

                    Spacer()

                    // Lower ergonomic thumb zone
                    HStack(alignment: .bottom, spacing: 12 * scale) {
                        // Left side: Left thumbstick + D-pad
                        VStack(alignment: .leading, spacing: 12 * scale) {
                            draggableCluster(id: "ls") {
                                VirtualThumbstick(
                                    label: "LS",
                                    scale: lsScale,
                                    floating: floatingStick,
                                    hapticEnabled: hapticTap,
                                    disabledForEdit: isEditingLayout
                                ) { x, y in
                                    gamepadManager.setVirtualLeftStick(x: x, y: y)
                                }
                            }

                            draggableCluster(id: "dpad") {
                                HStack(spacing: 5 * dpadScale) {
                                    padButton("←", keyPath: \.dpad_left, scale: dpadScale)
                                    VStack(spacing: 5 * dpadScale) {
                                        padButton("↑", keyPath: \.dpad_up, scale: dpadScale)
                                        padButton("↓", keyPath: \.dpad_down, scale: dpadScale)
                                    }
                                    padButton("→", keyPath: \.dpad_right, scale: dpadScale)
                                }
                            }
                        }

                        Spacer()

                        // Center system row: View / Xbox / Menu + LS/RS click
                        draggableCluster(id: "center") {
                            VStack(spacing: 8 * centerScale) {
                                HStack(spacing: 8 * centerScale) {
                                    miniPillButton("L3", keyPath: \.left_thumb, scale: centerScale)
                                    miniPillButton("R3", keyPath: \.right_thumb, scale: centerScale)
                                }
                                HStack(spacing: 8 * centerScale) {
                                    padButton("View", keyPath: \.view, wide: true, scale: centerScale)
                                    Button {
                                        guard !isEditingLayout else { return }
                                        fireButtonHaptic()
                                        gamepadManager.pulseNexusButton()
                                    } label: {
                                        Image(systemName: "xbox.logo")
                                            .font(centerScale < 0.85 ? .subheadline : .headline)
                                            .foregroundStyle(.white)
                                            .frame(width: 50 * centerScale, height: 42 * centerScale)
                                            .background(XboxTheme.primaryGradient, in: Capsule())
                                            .overlay(Capsule().stroke(Color.white.opacity(0.32), lineWidth: 1))
                                    }
                                    .simultaneousGesture(
                                        LongPressGesture(minimumDuration: 0.7).onEnded { _ in
                                            guard !isEditingLayout else { return }
                                            fireTriggerHaptic()
                                            gamepadManager.holdNexusButton(durationMs: 1200)
                                        }
                                    )
                                    .buttonStyle(.plain)
                                    padButton("Menu", keyPath: \.menu, wide: true, scale: centerScale)
                                }
                            }
                            .padding(.bottom, 4 * centerScale)
                        }

                        Spacer()

                        // Right side: ABXY + Right thumbstick
                        VStack(alignment: .trailing, spacing: 12 * scale) {
                            draggableCluster(id: "abxy") {
                                HStack(spacing: 6 * abxyScale) {
                                    padButton("X", keyPath: \.x, accent: Color(red: 0.24, green: 0.58, blue: 0.98), circular: true, scale: abxyScale)
                                    VStack(spacing: 6 * abxyScale) {
                                        padButton("Y", keyPath: \.y, accent: Color(red: 0.96, green: 0.74, blue: 0.16), circular: true, scale: abxyScale)
                                        padButton("A", keyPath: \.a, accent: XboxTheme.emeraldBright, circular: true, scale: abxyScale)
                                    }
                                    padButton("B", keyPath: \.b, accent: Color(red: 0.94, green: 0.32, blue: 0.34), circular: true, scale: abxyScale)
                                }
                            }

                            draggableCluster(id: "rs") {
                                VirtualThumbstick(
                                    label: "RS",
                                    scale: rsScale,
                                    floating: floatingStick,
                                    hapticEnabled: hapticTap,
                                    disabledForEdit: isEditingLayout
                                ) { x, y in
                                    gamepadManager.setVirtualRightStick(x: x, y: y)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, horizPad)
                    .padding(.bottom, bottomPad)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .opacity(isEditingLayout ? 0.96 : max(0.22, min(1.0, opacity)))

                // Floating Edit Mode Toolbar (drag position + per-module size slider)
                if isEditingLayout {
                    VirtualLayoutEditorBar(
                        selectedClusterId: $selectedClusterId,
                        savedOffsets: $savedOffsets,
                        savedScales: $savedScales,
                        onResetAll: {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                                savedOffsets = [:]
                                savedScales = [:]
                                liveDragOffsets = [:]
                            }
                        },
                        onDone: {
                            withAnimation(.spring(response: 0.24, dampingFraction: 0.85)) {
                                isEditingLayout = false
                            }
                            onDoneEditing?()
                        }
                    )
                }
            }
            .onAppear {
                #if os(iOS)
                VirtualGamepadHaptics.shared.prepareAll()
                #endif
            }
        }
    }

    private func storedOffset(for id: String) -> CGSize {
        guard let arr = savedOffsets[id], arr.count >= 2 else { return .zero }
        return CGSize(width: arr[0], height: arr[1])
    }

    private func totalOffset(for id: String) -> CGSize {
        let base = storedOffset(for: id)
        let drag = liveDragOffsets[id] ?? .zero
        return CGSize(width: base.width + drag.width, height: base.height + drag.height)
    }

    @ViewBuilder
    private func draggableCluster<Content: View>(id: String, @ViewBuilder content: () -> Content) -> some View {
        let off = totalOffset(for: id)
        if isEditingLayout {
            let isSelected = selectedClusterId == id
            content()
                .padding(5)
                .background(
                    isSelected ? XboxTheme.emerald.opacity(0.14) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            isSelected ? XboxTheme.emeraldBright : Color.white.opacity(0.42),
                            style: StrokeStyle(lineWidth: isSelected ? 2.2 : 1.3, dash: isSelected ? [] : [5, 4])
                        )
                )
                .offset(off)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedClusterId = id
                    fireButtonHaptic()
                }
                .highPriorityGesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            if selectedClusterId != id {
                                selectedClusterId = id
                            }
                            liveDragOffsets[id] = value.translation
                        }
                        .onEnded { value in
                            let base = storedOffset(for: id)
                            let nx = max(-280, min(280, Double(base.width + value.translation.width)))
                            let ny = max(-220, min(220, Double(base.height + value.translation.height)))
                            savedOffsets[id] = [nx, ny]
                            liveDragOffsets[id] = .zero
                        }
                )
        } else {
            content()
                .offset(off)
        }
    }

    private func fireButtonHaptic() {
        #if os(iOS)
        guard hapticTap else { return }
        VirtualGamepadHaptics.shared.buttonPress()
        #endif
    }

    private func fireTriggerHaptic() {
        #if os(iOS)
        guard hapticTap else { return }
        VirtualGamepadHaptics.shared.triggerPress()
        #endif
    }

    private func shoulderHoldButton(
        _ title: String,
        keyPath: WritableKeyPath<XboxPadInputFrame, UInt8>,
        scale: CGFloat
    ) -> some View {
        HoldControlSurface(disabled: isEditingLayout) { pressed in
            if pressed { fireButtonHaptic() }
            gamepadManager.setVirtualButton(keyPath, pressed: pressed)
        } content: { pressed in
            Text(title)
                .font((scale < 0.85 ? Font.caption2 : Font.caption).bold())
                .foregroundStyle(.white)
                .frame(width: 72 * scale, height: 34 * scale)
                .background((pressed ? XboxTheme.emerald.opacity(0.55) : Color.black.opacity(0.50)), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(pressed ? 0.8 : 0.36), lineWidth: 1.1))
        }
    }

    private func triggerHoldButton(_ title: String, isLeft: Bool, scale: CGFloat) -> some View {
        let tint = isLeft ? XboxTheme.emeraldBright : XboxTheme.info
        return HoldControlSurface(disabled: isEditingLayout) { pressed in
            if pressed { fireTriggerHaptic() }
            if isLeft {
                gamepadManager.setVirtualLeftTrigger(pressed ? 1.0 : 0.0)
            } else {
                gamepadManager.setVirtualRightTrigger(pressed ? 1.0 : 0.0)
            }
        } content: { pressed in
            Text(title)
                .font((scale < 0.85 ? Font.caption2 : Font.caption).bold())
                .foregroundStyle(pressed ? .black : tint)
                .frame(width: 78 * scale, height: 38 * scale)
                .background(
                    pressed ? tint.opacity(0.85) : Color.black.opacity(0.52),
                    in: RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                        .stroke(tint.opacity(0.58), lineWidth: 1.2)
                )
        }
    }

    private func miniPillButton(
        _ title: String,
        keyPath: WritableKeyPath<XboxPadInputFrame, UInt8>,
        scale: CGFloat
    ) -> some View {
        HoldControlSurface(disabled: isEditingLayout) { pressed in
            if pressed { fireButtonHaptic() }
            gamepadManager.setVirtualButton(keyPath, pressed: pressed)
        } content: { pressed in
            Text(title)
                .font(.caption2.bold())
                .foregroundStyle(.white.opacity(pressed ? 1.0 : 0.85))
                .frame(width: 44 * scale, height: 28 * scale)
                .background(pressed ? XboxTheme.emerald.opacity(0.55) : Color.black.opacity(0.45), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.28), lineWidth: 1))
        }
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
        return HoldControlSurface(disabled: isEditingLayout) { pressed in
            if pressed { fireButtonHaptic() }
            gamepadManager.setVirtualButton(keyPath, pressed: pressed)
        } content: { pressed in
            Text(label)
                .font((wide || scale < 0.85 ? Font.caption2 : Font.subheadline).bold())
                .foregroundStyle(pressed ? .black : accent)
                .frame(width: (wide ? 56 : 48) * scale, height: size)
                .background(pressed ? accent.opacity(0.85) : Color.black.opacity(0.48), in: shape)
                .overlay(shape.stroke(accent.opacity(0.56), lineWidth: 1.2))
                .scaleEffect(pressed ? 0.94 : 1.0)
        }
    }
}

// MARK: - Native Multi-Touch Button Surface (with 55ms Minimum Latch for Quick Taps)

private struct HoldControlSurface<Content: View>: View {
    let disabled: Bool
    let onPressChange: (Bool) -> Void
    @ViewBuilder let content: (Bool) -> Content

    @State private var isPressed = false
    @State private var pressBeganAt: CFTimeInterval = 0
    @State private var pendingReleaseWork: DispatchWorkItem?

    private func handleTouchState(_ down: Bool) {
        if down {
            pendingReleaseWork?.cancel()
            pendingReleaseWork = nil
            pressBeganAt = CACurrentMediaTime()
            if !isPressed {
                isPressed = true
                onPressChange(true)
            }
        } else {
            guard isPressed else { return }
            let elapsed = CACurrentMediaTime() - pressBeganAt
            let minHold: CFTimeInterval = 0.055
            if elapsed >= minHold {
                isPressed = false
                onPressChange(false)
            } else {
                // Keep quick thumb taps latched >= 55ms so 30/60fps Xbox games never miss a tap
                let remaining = minHold - elapsed
                let work = DispatchWorkItem {
                    isPressed = false
                    onPressChange(false)
                }
                pendingReleaseWork?.cancel()
                pendingReleaseWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
            }
        }
    }

    var body: some View {
        #if os(iOS)
        content(isPressed)
            .overlay {
                if !disabled {
                    MultiTouchPressOverlay { down in
                        handleTouchState(down)
                    }
                }
            }
        #else
        content(isPressed)
            .gesture(
                disabled
                    ? nil
                    : DragGesture(minimumDistance: 0)
                        .onChanged { _ in handleTouchState(true) }
                        .onEnded { _ in handleTouchState(false) }
            )
        #endif
    }
}

#if os(iOS)
private struct MultiTouchPressOverlay: UIViewRepresentable {
    let onPressChange: (Bool) -> Void

    func makeUIView(context: Context) -> MultiTouchPressUIView {
        let v = MultiTouchPressUIView()
        v.onPressChange = onPressChange
        return v
    }

    func updateUIView(_ uiView: MultiTouchPressUIView, context: Context) {
        uiView.onPressChange = onPressChange
    }
}

private final class MultiTouchPressUIView: UIView {
    var onPressChange: ((Bool) -> Void)?
    private var activeTouches = Set<UITouch>()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let wasEmpty = activeTouches.isEmpty
        activeTouches.formUnion(touches)
        if wasEmpty && !activeTouches.isEmpty {
            onPressChange?(true)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.subtract(touches)
        if activeTouches.isEmpty {
            onPressChange?(false)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        activeTouches.subtract(touches)
        if activeTouches.isEmpty {
            onPressChange?(false)
        }
    }
}

private struct MultiTouchStickOverlay: UIViewRepresentable {
    let onTouch: (_ active: Bool, _ startPoint: CGPoint, _ currentPoint: CGPoint, _ bounds: CGRect) -> Void

    func makeUIView(context: Context) -> MultiTouchStickUIView {
        let v = MultiTouchStickUIView()
        v.onTouch = onTouch
        return v
    }

    func updateUIView(_ uiView: MultiTouchStickUIView, context: Context) {
        uiView.onTouch = onTouch
    }
}

private final class MultiTouchStickUIView: UIView {
    var onTouch: ((Bool, CGPoint, CGPoint, CGRect) -> Void)?
    private weak var trackedTouch: UITouch?
    private var startPoint: CGPoint = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard trackedTouch == nil, let first = touches.first else { return }
        trackedTouch = first
        let pt = first.location(in: self)
        startPoint = pt
        onTouch?(true, startPoint, pt, bounds)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let tracked = trackedTouch, touches.contains(tracked) else { return }
        let pt = tracked.location(in: self)
        onTouch?(true, startPoint, pt, bounds)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let tracked = trackedTouch, touches.contains(tracked) else { return }
        trackedTouch = nil
        onTouch?(false, startPoint, startPoint, bounds)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let tracked = trackedTouch, touches.contains(tracked) else { return }
        trackedTouch = nil
        onTouch?(false, startPoint, startPoint, bounds)
    }
}
#endif

// MARK: - Native Multi-Touch Virtual Thumbstick with Physical-Feel Taptic Feedback

private struct VirtualThumbstick: View {
    let label: String
    let scale: CGFloat
    let floating: Bool
    let hapticEnabled: Bool
    let disabledForEdit: Bool
    let onChange: (Float, Float) -> Void

    @State private var knobOffset: CGSize = .zero
    @State private var floatAnchorOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var hitRimLatch = false
    @State private var lastOctant: Int = -1
    @State private var lastTickTime: CFTimeInterval = 0

    private var baseRadius: CGFloat { 54 * scale }
    private var knobRadius: CGFloat { 24 * scale }

    private func handleStickUpdate(active: Bool, startPoint: CGPoint, currentPoint: CGPoint, size: CGSize) {
        if active {
            let justStarted = !isDragging
            if justStarted {
                isDragging = true
                hitRimLatch = false
                lastOctant = -1
                if floating {
                    let dxStart = startPoint.x - size.width * 0.5
                    let dyStart = startPoint.y - size.height * 0.5
                    floatAnchorOffset = CGSize(
                        width: max(-36 * scale, min(36 * scale, dxStart)),
                        height: max(-36 * scale, min(36 * scale, dyStart))
                    )
                }
                #if os(iOS)
                if hapticEnabled {
                    VirtualGamepadHaptics.shared.stickGrab()
                }
                #endif
            }

            let dx = currentPoint.x - startPoint.x
            let dy = currentPoint.y - startPoint.y
            let maxTravel = baseRadius - knobRadius * 0.45
            let dist = hypot(dx, dy)
            let clampedDist = min(dist, maxTravel)
            let angle = atan2(dy, dx)
            let cx = dist > 0.001 ? cos(angle) * clampedDist : 0
            let cy = dist > 0.001 ? sin(angle) * clampedDist : 0
            knobOffset = CGSize(width: cx, height: cy)

            let ratio = maxTravel > 0 ? (clampedDist / maxTravel) : 0
            #if os(iOS)
            if hapticEnabled {
                if ratio >= 0.92 && !hitRimLatch {
                    hitRimLatch = true
                    VirtualGamepadHaptics.shared.stickRimBump()
                } else if ratio < 0.74 && hitRimLatch {
                    hitRimLatch = false
                }
                if ratio >= 0.55 {
                    let normAngle = angle < 0 ? (angle + .pi * 2) : angle
                    let octant = Int((normAngle / (.pi / 4)).rounded()) % 8
                    let now = CACurrentMediaTime()
                    if lastOctant != -1 && octant != lastOctant && (now - lastTickTime) >= 0.075 {
                        lastTickTime = now
                        VirtualGamepadHaptics.shared.stickDirectionTick()
                    }
                    lastOctant = octant
                } else {
                    lastOctant = -1
                }
            }
            #endif

            let nx = Float(cx / maxTravel)
            let ny = Float(-cy / maxTravel)
            onChange(nx, ny)
        } else {
            if isDragging {
                #if os(iOS)
                if hapticEnabled {
                    VirtualGamepadHaptics.shared.stickRelease()
                }
                #endif
            }
            isDragging = false
            hitRimLatch = false
            lastOctant = -1
            withAnimation(.spring(response: 0.18, dampingFraction: 0.72)) {
                knobOffset = .zero
                floatAnchorOffset = .zero
            }
            onChange(0, 0)
        }
    }

    var body: some View {
        let frameSide = baseRadius * 2.4
        let stickVisual = ZStack {
            Circle()
                .fill(Color.black.opacity(0.42))
                .frame(width: baseRadius * 2, height: baseRadius * 2)
                .overlay(
                    Circle().stroke(
                        hitRimLatch ? XboxTheme.emeraldBright.opacity(0.85) : Color.white.opacity(isDragging ? 0.55 : 0.26),
                        lineWidth: hitRimLatch ? 2.0 : 1.4
                    )
                )

            Circle()
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                .frame(width: baseRadius * 1.15, height: baseRadius * 1.15)

            Circle()
                .fill(Color.white.opacity(isDragging ? 0.36 : 0.22))
                .frame(width: knobRadius * 2, height: knobRadius * 2)
                .overlay(Circle().stroke(Color.white.opacity(0.68), lineWidth: 1.5))
                .overlay(
                    Text(label)
                        .font(.caption2.bold())
                        .foregroundStyle(.white.opacity(0.88))
                )
                .offset(knobOffset)
        }
        .offset(floating ? floatAnchorOffset : .zero)
        .frame(width: frameSide, height: frameSide)

        #if os(iOS)
        stickVisual
            .overlay {
                if !disabledForEdit {
                    MultiTouchStickOverlay { active, startPt, curPt, rect in
                        handleStickUpdate(active: active, startPoint: startPt, currentPoint: curPt, size: rect.size)
                    }
                }
            }
        #else
        stickVisual
            .contentShape(Rectangle())
            .gesture(
                disabledForEdit
                    ? nil
                    : DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            handleStickUpdate(
                                active: true,
                                startPoint: value.startLocation,
                                currentPoint: value.location,
                                size: CGSize(width: frameSide, height: frameSide)
                            )
                        }
                        .onEnded { value in
                            handleStickUpdate(
                                active: false,
                                startPoint: value.startLocation,
                                currentPoint: value.location,
                                size: CGSize(width: frameSide, height: frameSide)
                            )
                        }
            )
        #endif
    }
}

// MARK: - Visual Layout Editor Bar & Full-Screen Settings Preview Editor

private struct VirtualLayoutEditorBar: View {
    @Binding var selectedClusterId: String
    @Binding var savedOffsets: [String: [Double]]
    @Binding var savedScales: [String: Double]
    let onResetAll: () -> Void
    let onDone: () -> Void

    private var selectedCluster: VirtualGamepadCluster {
        VirtualGamepadCluster(rawValue: selectedClusterId) ?? .abxy
    }

    private var currentScaleBinding: Binding<Double> {
        Binding(
            get: { savedScales[selectedClusterId] ?? 1.0 },
            set: { savedScales[selectedClusterId] = $0 }
        )
    }

    private var currentOffsetText: String {
        let arr = savedOffsets[selectedClusterId]
        let x = Int((arr?.first ?? 0).rounded())
        let y = Int(((arr?.count ?? 0) >= 2 ? arr![1] : 0).rounded())
        return "X:\(x)  Y:\(y)"
    }

    var body: some View {
        VStack {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "hand.draw.fill")
                        .font(.caption.bold())
                        .foregroundStyle(XboxTheme.emeraldBright)
                    Text("拖动模块调位置 · 点击模块调大小")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Button("重置当前") {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                            savedOffsets.removeValue(forKey: selectedClusterId)
                            savedScales.removeValue(forKey: selectedClusterId)
                        }
                    }
                    .font(.caption2.bold())
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.cyan.opacity(0.16), in: Capsule())
                    .buttonStyle(.plain)

                    Button("全部重置") {
                        onResetAll()
                    }
                    .font(.caption2.bold())
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.orange.opacity(0.18), in: Capsule())
                    .buttonStyle(.plain)

                    Button("保存完成") {
                        onDone()
                    }
                    .font(.caption.bold())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(XboxTheme.emeraldBright, in: Capsule())
                    .buttonStyle(.plain)
                }

                HStack(spacing: 10) {
                    Text(selectedCluster.shortLabel)
                        .font(.caption2.bold())
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(XboxTheme.emeraldBright, in: Capsule())

                    Text("大小")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))

                    Slider(value: currentScaleBinding, in: 0.65...1.50, step: 0.05)
                        .tint(XboxTheme.emeraldBright)

                    Text("\(Int((currentScaleBinding.wrappedValue * 100).rounded()))%")
                        .font(.caption2.monospacedDigit().bold())
                        .foregroundStyle(XboxTheme.emeraldBright)
                        .frame(width: 38, alignment: .trailing)

                    Text(currentOffsetText)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 520)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .background(Color.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(XboxTheme.emeraldBright.opacity(0.50), lineWidth: 1.1)
            )
            .padding(.top, 12)
            .padding(.horizontal, 12)

            Spacer()
        }
    }
}

/// Full-screen interactive virtual gamepad editor launched directly from Settings
/// so users can drag positions and customize per-module sizes in landscape without starting a stream.
struct VirtualGamepadLayoutEditorScreen: View {
    @EnvironmentObject var appState: AppState
    let onClose: () -> Void

    @State private var isEditing = true

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.06, blue: 0.09).ignoresSafeArea()

            // Subtle 16:9 game viewport frame guide
            GeometryReader { geo in
                let targetW = min(geo.size.width, geo.size.height * 16.0 / 9.0)
                let targetH = targetW * 9.0 / 16.0
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.03))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.10), style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
                        )
                    VStack(spacing: 6) {
                        Image(systemName: "gamecontroller.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.16))
                        Text("16:9 游戏画面参考区")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.24))
                    }
                }
                .frame(width: targetW, height: targetH)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VirtualGamepadOverlay(
                gamepadManager: appState.gamepadManager,
                opacity: appState.settings.virtualGamepadOpacity,
                scaleMultiplier: appState.settings.virtualGamepadScale,
                floatingStick: appState.settings.virtualGamepadFloatingStick,
                hapticTap: appState.settings.virtualGamepadHapticTap,
                isEditingLayout: $isEditing,
                savedOffsets: $appState.settings.virtualGamepadOffsets,
                savedScales: $appState.settings.virtualGamepadClusterScales,
                onDoneEditing: {
                    onClose()
                }
            )
            .ignoresSafeArea()
        }
        .xboxHideSystemChrome()
        .onAppear {
            if appState.activeStreamTarget == nil {
                XboxPlatform.setPreferredLandscapeForStreaming(true)
            }
        }
        .onDisappear {
            if appState.activeStreamTarget == nil {
                XboxPlatform.setPreferredLandscapeForStreaming(false)
            }
        }
    }
}

import SwiftUI

enum XboxTheme {
    // Core Obsidian + Emerald Palette
    static let bgDeep = Color(red: 0.04, green: 0.055, blue: 0.07)
    static let bgBase = Color(red: 0.055, green: 0.07, blue: 0.09)
    static let surface = Color(red: 0.095, green: 0.115, blue: 0.145)
    static let surfaceElevated = Color(red: 0.125, green: 0.15, blue: 0.19)
    static let surfaceMuted = Color(red: 0.075, green: 0.09, blue: 0.115)

    static let emerald = Color(red: 0.12, green: 0.84, blue: 0.44)
    static let emeraldBright = Color(red: 0.24, green: 0.92, blue: 0.54)
    static let emeraldDeep = Color(red: 0.06, green: 0.56, blue: 0.27)

    static let info = Color(red: 0.24, green: 0.74, blue: 0.98)
    static let warning = Color(red: 0.98, green: 0.65, blue: 0.16)
    static let danger = Color(red: 0.94, green: 0.30, blue: 0.32)

    static let borderGradient = LinearGradient(
        colors: [Color.white.opacity(0.16), Color.white.opacity(0.04)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let emeraldBorderGradient = LinearGradient(
        colors: [emerald.opacity(0.55), emeraldDeep.opacity(0.18)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let primaryGradient = LinearGradient(
        colors: [Color(red: 0.10, green: 0.76, blue: 0.38), Color(red: 0.06, green: 0.54, blue: 0.26)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let heroBrandGradient = LinearGradient(
        colors: [emeraldBright, emeraldDeep],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static var appVersionDisplay: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(short) (\(build))"
    }
}

struct XboxAmbientBackground: View {
    var intensity: Double = 1.0

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [XboxTheme.bgDeep, XboxTheme.bgBase, Color(red: 0.035, green: 0.045, blue: 0.06)],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [
                    XboxTheme.emerald.opacity(0.13 * intensity),
                    XboxTheme.emeraldDeep.opacity(0.04 * intensity),
                    Color.clear,
                ],
                center: .topLeading,
                startRadius: 20,
                endRadius: 560
            )

            RadialGradient(
                colors: [
                    XboxTheme.info.opacity(0.05 * intensity),
                    Color.clear,
                ],
                center: .bottomTrailing,
                startRadius: 10,
                endRadius: 480
            )
        }
        .ignoresSafeArea()
    }
}

struct XboxCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 18
    var highlighted: Bool = false
    var fill: Color = XboxTheme.surface

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill.opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        highlighted ? XboxTheme.emeraldBorderGradient : XboxTheme.borderGradient,
                        lineWidth: highlighted ? 1.2 : 1
                    )
            )
            .shadow(color: Color.black.opacity(0.28), radius: 14, x: 0, y: 6)
    }
}

extension View {
    func xboxCard(
        cornerRadius: CGFloat = 18,
        highlighted: Bool = false,
        fill: Color = XboxTheme.surface
    ) -> some View {
        modifier(XboxCardModifier(cornerRadius: cornerRadius, highlighted: highlighted, fill: fill))
    }
}

struct XboxPrimaryButtonStyle: ButtonStyle {
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .subheadline.weight(.semibold) : .headline)
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 14 : 18)
            .padding(.vertical, compact ? 10 : 13)
            .background(
                RoundedRectangle(cornerRadius: compact ? 12 : 14, style: .continuous)
                    .fill(XboxTheme.primaryGradient)
            )
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 12 : 14, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: XboxTheme.emeraldDeep.opacity(configuration.isPressed ? 0.15 : 0.35), radius: 10, x: 0, y: 4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct XboxSecondaryButtonStyle: ButtonStyle {
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .subheadline.weight(.medium) : .subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, compact ? 12 : 16)
            .padding(.vertical, compact ? 9 : 12)
            .background(
                RoundedRectangle(cornerRadius: compact ? 12 : 14, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.13 : 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 12 : 14, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct XboxStatusPill: View {
    let text: String
    let color: Color
    var pulse: Bool = false

    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                if pulse {
                    Circle()
                        .fill(color.opacity(0.35))
                        .frame(width: 14, height: 14)
                        .scaleEffect(isPulsing ? 1.35 : 0.75)
                        .opacity(isPulsing ? 0.0 : 0.9)
                }
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
            }
            .frame(width: 12, height: 12)

            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.16), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 1))
        .onAppear {
            guard pulse else { return }
            withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) {
                isPulsing = true
            }
        }
    }
}

struct XboxIconBadge: View {
    let systemName: String
    let color: Color
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(color.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .stroke(color.opacity(0.32), lineWidth: 0.8)
                )
            Image(systemName: systemName)
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
    }
}

struct XboxBrandEmblem: View {
    var size: CGFloat = 72

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
        Image("BrandIcon")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay(
                shape.stroke(XboxTheme.emeraldBorderGradient, lineWidth: 1.4)
            )
            .shadow(color: XboxTheme.emerald.opacity(0.26), radius: size * 0.24, x: 0, y: size * 0.08)
    }
}

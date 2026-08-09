import AppKit
import SwiftUI

enum BatteryGuardPalette {
    static let accent = adaptive(
        light: NSColor(red: 0.42, green: 0.42, blue: 0.66, alpha: 1),
        dark: NSColor(red: 0.69, green: 0.68, blue: 0.88, alpha: 1)
    )
    static let lavender = adaptive(
        light: NSColor(red: 0.78, green: 0.75, blue: 0.91, alpha: 1),
        dark: NSColor(red: 0.42, green: 0.39, blue: 0.57, alpha: 1)
    )
    static let mint = adaptive(
        light: NSColor(red: 0.68, green: 0.84, blue: 0.78, alpha: 1),
        dark: NSColor(red: 0.32, green: 0.49, blue: 0.43, alpha: 1)
    )
    static let peach = adaptive(
        light: NSColor(red: 0.94, green: 0.75, blue: 0.68, alpha: 1),
        dark: NSColor(red: 0.56, green: 0.38, blue: 0.34, alpha: 1)
    )
    static let butter = adaptive(
        light: NSColor(red: 0.91, green: 0.84, blue: 0.60, alpha: 1),
        dark: NSColor(red: 0.54, green: 0.47, blue: 0.25, alpha: 1)
    )
    static let sky = adaptive(
        light: NSColor(red: 0.68, green: 0.81, blue: 0.91, alpha: 1),
        dark: NSColor(red: 0.31, green: 0.45, blue: 0.57, alpha: 1)
    )
    static let lavenderInk = accent
    static let mintInk = success
    static let peachInk = adaptive(
        light: NSColor(red: 0.64, green: 0.33, blue: 0.27, alpha: 1),
        dark: NSColor(red: 0.91, green: 0.57, blue: 0.49, alpha: 1)
    )
    static let butterInk = warning
    static let skyInk = adaptive(
        light: NSColor(red: 0.27, green: 0.47, blue: 0.61, alpha: 1),
        dark: NSColor(red: 0.48, green: 0.69, blue: 0.84, alpha: 1)
    )
    static let surface = adaptive(
        light: NSColor(red: 0.99, green: 0.985, blue: 1, alpha: 0.93),
        dark: NSColor(red: 0.13, green: 0.13, blue: 0.17, alpha: 0.94)
    )
    static let canvasTop = adaptive(
        light: NSColor(red: 0.97, green: 0.95, blue: 0.99, alpha: 1),
        dark: NSColor(red: 0.09, green: 0.09, blue: 0.12, alpha: 1)
    )
    static let canvasBottom = adaptive(
        light: NSColor(red: 0.92, green: 0.97, blue: 0.95, alpha: 1),
        dark: NSColor(red: 0.10, green: 0.13, blue: 0.13, alpha: 1)
    )
    static let border = adaptive(
        light: NSColor(white: 1, alpha: 0.82),
        dark: NSColor(white: 1, alpha: 0.10)
    )
    static let shadow = adaptive(
        light: NSColor(red: 0.28, green: 0.24, blue: 0.39, alpha: 0.12),
        dark: NSColor(white: 0, alpha: 0.28)
    )
    static let danger = adaptive(
        light: NSColor(red: 0.71, green: 0.27, blue: 0.31, alpha: 1),
        dark: NSColor(red: 0.95, green: 0.50, blue: 0.53, alpha: 1)
    )
    static let warning = adaptive(
        light: NSColor(red: 0.69, green: 0.43, blue: 0.16, alpha: 1),
        dark: NSColor(red: 0.94, green: 0.68, blue: 0.35, alpha: 1)
    )
    static let success = adaptive(
        light: NSColor(red: 0.25, green: 0.55, blue: 0.43, alpha: 1),
        dark: NSColor(red: 0.47, green: 0.78, blue: 0.64, alpha: 1)
    )

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? dark : light
        })
    }
}

struct PastelCanvas: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [BatteryGuardPalette.canvasTop, BatteryGuardPalette.canvasBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if !reduceTransparency {
                RadialGradient(
                    colors: [BatteryGuardPalette.lavender.opacity(0.24), .clear],
                    center: .topLeading,
                    startRadius: 12,
                    endRadius: 720
                )
                RadialGradient(
                    colors: [BatteryGuardPalette.peach.opacity(0.16), .clear],
                    center: .bottomTrailing,
                    startRadius: 12,
                    endRadius: 620
                )
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct PastelCard<Content: View>: View {
    private let tint: Color
    private let padding: CGFloat
    private let fillsAvailableHeight: Bool
    private let content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(
        tint: Color = BatteryGuardPalette.lavender,
        padding: CGFloat = 20,
        fillsAvailableHeight: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.tint = tint
        self.padding = padding
        self.fillsAvailableHeight = fillsAvailableHeight
        self.content = content()
    }

    var body: some View {
        cardContent
            .padding(padding)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(reduceTransparency ? BatteryGuardPalette.surface : Color.clear)
                    if !reduceTransparency {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(.regularMaterial)
                    }
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(tint.opacity(reduceTransparency ? 0.08 : 0.055))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(BatteryGuardPalette.border, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: BatteryGuardPalette.shadow, radius: 18, x: 0, y: 8)
    }

    @ViewBuilder
    private var cardContent: some View {
        if fillsAvailableHeight {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            content
        }
    }
}

struct PastelSectionHeader: View {
    let title: String
    let subtitle: String?
    let icon: String
    let tint: Color

    init(_ title: String, subtitle: String? = nil, icon: String, tint: Color) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct PastelStatusPill: View {
    let title: String
    let tint: Color
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
            } else {
                Circle().frame(width: 7, height: 7)
            }
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.13), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct PastelMetricRow: View {
    let icon: String
    let label: String
    let value: String
    var tint: Color = BatteryGuardPalette.accent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

struct PastelNotice: View {
    enum Kind {
        case info
        case warning
        case critical

        var tint: Color {
            switch self {
            case .info: return BatteryGuardPalette.accent
            case .warning: return BatteryGuardPalette.warning
            case .critical: return BatteryGuardPalette.danger
            }
        }

        var icon: String {
            switch self {
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .critical: return "xmark.octagon.fill"
            }
        }
    }

    let message: String
    let kind: Kind

    var body: some View {
        Label(message, systemImage: kind.icon)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(kind.tint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(kind.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(kind.tint.opacity(0.18), lineWidth: 1)
            }
    }
}

extension ChargeState {
    var presentationTint: Color {
        switch self {
        case .charging, .topUp: return BatteryGuardPalette.success
        case .chargingPaused: return BatteryGuardPalette.warning
        case .discharging: return BatteryGuardPalette.sky
        case .notConnected: return .secondary
        case .unknown: return BatteryGuardPalette.danger
        }
    }

    var presentationIcon: String {
        switch self {
        case .charging: return "bolt.fill"
        case .topUp: return "arrow.up.to.line.compact"
        case .chargingPaused: return "pause.fill"
        case .discharging: return "arrow.down.to.line.compact"
        case .notConnected: return "powerplug.fill"
        case .unknown: return "questionmark"
        }
    }
}

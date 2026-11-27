import AppKit
import SwiftUI

enum BatteryGuardRadius {
    static let card: CGFloat = 14
    static let control: CGFloat = 9
    static let iconBadge: CGFloat = 8
    static let pill: CGFloat = 999
}

enum BatteryGuardPalette {
    // Single locked brand accent: deep pine emerald (battery/energy native, zero purple/violet).
    static let accent = adaptive(
        light: NSColor(red: 0.08, green: 0.45, blue: 0.34, alpha: 1),
        dark: NSColor(red: 0.24, green: 0.76, blue: 0.58, alpha: 1)
    )

    // Neutral surfaces (off-white / rich off-black, one crisp step between canvas, card, and inset).
    static let canvas = adaptive(
        light: NSColor(red: 0.955, green: 0.957, blue: 0.955, alpha: 1),
        dark: NSColor(red: 0.082, green: 0.085, blue: 0.092, alpha: 1)
    )
    static let surface = adaptive(
        light: NSColor(red: 0.996, green: 0.996, blue: 0.995, alpha: 1),
        dark: NSColor(red: 0.125, green: 0.130, blue: 0.140, alpha: 1)
    )
    static let surfaceInset = adaptive(
        light: NSColor(red: 0.948, green: 0.951, blue: 0.953, alpha: 1),
        dark: NSColor(red: 0.155, green: 0.161, blue: 0.173, alpha: 1)
    )
    static let border = adaptive(
        light: NSColor(white: 0, alpha: 0.085),
        dark: NSColor(white: 1, alpha: 0.105)
    )
    static let borderSubtle = adaptive(
        light: NSColor(white: 0, alpha: 0.06),
        dark: NSColor(white: 1, alpha: 0.075)
    )
    static let topHighlight = adaptive(
        light: NSColor(white: 1, alpha: 0),
        dark: NSColor(white: 1, alpha: 0.06)
    )
    static let hoverFill = adaptive(
        light: NSColor(white: 0, alpha: 0.045),
        dark: NSColor(white: 1, alpha: 0.07)
    )
    static let neutralInk = adaptive(
        light: NSColor(red: 0.36, green: 0.39, blue: 0.42, alpha: 1),
        dark: NSColor(red: 0.67, green: 0.70, blue: 0.74, alpha: 1)
    )

    // Semantic status colors only (never used for random decorative variety).
    static let success = adaptive(
        light: NSColor(red: 0.09, green: 0.48, blue: 0.32, alpha: 1),
        dark: NSColor(red: 0.26, green: 0.78, blue: 0.55, alpha: 1)
    )
    static let warning = adaptive(
        light: NSColor(red: 0.62, green: 0.34, blue: 0.04, alpha: 1),
        dark: NSColor(red: 0.95, green: 0.70, blue: 0.28, alpha: 1)
    )
    static let danger = adaptive(
        light: NSColor(red: 0.73, green: 0.18, blue: 0.21, alpha: 1),
        dark: NSColor(red: 0.96, green: 0.44, blue: 0.47, alpha: 1)
    )
    static let info = adaptive(
        light: NSColor(red: 0.14, green: 0.41, blue: 0.64, alpha: 1),
        dark: NSColor(red: 0.42, green: 0.70, blue: 0.95, alpha: 1)
    )

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? dark : light
        })
    }
}

struct BatteryGuardCanvas: View {
    var body: some View {
        BatteryGuardPalette.canvas
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

struct SurfaceCard<Content: View>: View {
    private let padding: CGFloat
    private let fillsAvailableHeight: Bool
    private let content: Content

    init(
        padding: CGFloat = 20,
        fillsAvailableHeight: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.fillsAvailableHeight = fillsAvailableHeight
        self.content = content()
    }

    var body: some View {
        cardContent
            .padding(padding)
            .background(
                BatteryGuardPalette.surface,
                in: RoundedRectangle(cornerRadius: BatteryGuardRadius.card, style: .continuous)
            )
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: BatteryGuardRadius.card, style: .continuous)
                    .stroke(BatteryGuardPalette.topHighlight, lineWidth: 1)
                    .mask(
                        VStack(spacing: 0) {
                            Rectangle().frame(height: 1)
                            Spacer(minLength: 0)
                        }
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: BatteryGuardRadius.card, style: .continuous)
                    .stroke(BatteryGuardPalette.border, lineWidth: 1)
            }
    }

    @ViewBuilder
    private var cardContent: some View {
        if fillsAvailableHeight {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            content
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String?
    let icon: String
    var tint: Color = BatteryGuardPalette.neutralInk

    init(
        _ title: String,
        subtitle: String? = nil,
        icon: String,
        tint: Color = BatteryGuardPalette.neutralInk
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(
                    tint.opacity(0.11),
                    in: RoundedRectangle(cornerRadius: BatteryGuardRadius.iconBadge, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14.5, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct StatusPill: View {
    let title: String
    let tint: Color
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4.5)
        .background(tint.opacity(0.12), in: Capsule())
        .overlay {
            Capsule().stroke(tint.opacity(0.20), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

struct MetricRow: View {
    let icon: String
    let label: String
    let value: String
    var tint: Color = BatteryGuardPalette.neutralInk

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(
                    BatteryGuardPalette.surfaceInset,
                    in: RoundedRectangle(cornerRadius: BatteryGuardRadius.iconBadge, style: .continuous)
                )
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

struct StatusNotice: View {
    enum Kind {
        case info
        case warning
        case critical

        var tint: Color {
            switch self {
            case .info: return BatteryGuardPalette.info
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
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: kind.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(kind.tint)
                .padding(.top, 1)
            Text(message)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(
            kind.tint.opacity(0.08),
            in: RoundedRectangle(cornerRadius: BatteryGuardRadius.control, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: BatteryGuardRadius.control, style: .continuous)
                .stroke(kind.tint.opacity(0.22), lineWidth: 1)
        }
    }
}

extension BatteryPresentationTone {
    var presentationTint: Color {
        switch self {
        case .success: return BatteryGuardPalette.success
        case .warning: return BatteryGuardPalette.warning
        case .info: return BatteryGuardPalette.info
        case .neutral: return BatteryGuardPalette.neutralInk
        case .danger: return BatteryGuardPalette.danger
        }
    }
}

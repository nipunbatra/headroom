// Colours, spacing and number formats shared by every view.
import AppKit
import SwiftUI

enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 20       // window margins and the gap between groups
}

/// A colour with its own light and dark step, so charts can also pick readable text for it.
struct Swatch {
    let light: UInt32
    let dark: UInt32

    var color: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    func hex(_ scheme: ColorScheme) -> UInt32 { scheme == .dark ? dark : light }

    /// Black or white, whichever reads better on this fill.
    func ink(_ scheme: ColorScheme) -> Color {
        let h = hex(scheme)
        func lin(_ v: UInt32) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let l = 0.2126 * lin((h >> 16) & 255) + 0.7152 * lin((h >> 8) & 255) + 0.0722 * lin(h & 255)
        return l > 0.36 ? Color.black.opacity(0.85) : Color.white
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                  blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

/// The chart palette: a fixed order, validated for colour-blind separation in both modes.
enum Palette {
    static let safe = Swatch(light: 0x0ca30c, dark: 0x0ca30c)
    static let review = Swatch(light: 0xfab219, dark: 0xfab219)
    static let crit = Swatch(light: 0xd03b3b, dark: 0xe66767)
    static let track = Swatch(light: 0xdfe3ea, dark: 0x2a2f38)
    static let series: [Swatch] = [
        Swatch(light: 0x9aa1ad, dark: 0x596170),   // 0: everything else
        Swatch(light: 0x2a78d6, dark: 0x3987e5),
        Swatch(light: 0xeb6834, dark: 0xd95926),
        Swatch(light: 0x1baf7a, dark: 0x199e70),
        Swatch(light: 0xeda100, dark: 0xc98500),
        Swatch(light: 0xe87ba4, dark: 0xd55181),
        Swatch(light: 0x008300, dark: 0x0ca30c),
        Swatch(light: 0x6250d6, dark: 0x9085e9),
        Swatch(light: 0xe34948, dark: 0xe66767),
    ]
    static func slot(_ index: Int) -> Swatch { series[index < 7 ? index + 1 : 0] }
}


/// Sizes the way Finder shows them: decimal units, three significant figures.
func fmt(_ bytes: Int64) -> String {
    let b = Double(bytes)
    if bytes >= GB {
        let g = b / 1e9
        return String(format: g >= 100 ? "%.0f GB" : g >= 10 ? "%.1f GB" : "%.2f GB", g)
    }
    if bytes >= MB { return String(format: bytes >= 100 * MB ? "%.0f MB" : "%.1f MB", b / 1e6) }
    return "\(bytes > 0 ? max(1, Int((b / 1e3).rounded())) : 0) KB"
}

func signed(_ bytes: Int64) -> String { (bytes < 0 ? "−" : "+") + fmt(abs(bytes)) }

func plural(_ n: Int, _ word: String) -> String { "\(n.formatted()) \(word)\(n == 1 ? "" : "s")" }

func ageText(_ ts: Double?, now: Double) -> String {
    guard let ts, ts > 0 else { return "no record" }
    let d = Int((now - ts) / 86400)
    if d < 1 { return "today" }
    if d < 2 { return "yesterday" }
    if d < 60 { return "\(d) days ago" }
    if d < 730 { return "\(Int((Double(d) / 30.4).rounded())) months ago" }
    return String(format: "%.1f years ago", Double(d) / 365)
}

func baseName(_ p: String) -> String { p.split(separator: "/").last.map(String.init) ?? p }

func dirName(_ p: String) -> String {
    guard let i = p.lastIndex(of: "/"), i != p.startIndex else { return "/" }
    return String(p[..<i])
}

func expandTilde(_ p: String) -> String { (p as NSString).expandingTildeInPath }

struct Pill: Hashable {
    enum Kind { case safe, review, keep, crit, plain }
    var text: String
    var kind: Kind = .plain

    static func safety(_ s: String, _ label: String? = nil) -> Pill {
        switch s {
        case "safe": return Pill(text: label ?? "Safe to Clear", kind: .safe)
        case "review": return Pill(text: label ?? "Review First", kind: .review)
        default: return Pill(text: label ?? "Leave Alone", kind: .keep)
        }
    }
}

/// A status always carries an icon and a word, never colour alone.
@MainActor struct PillView: View {
    let pill: Pill

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(tint)
            }
            Text(pill.text).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(tint.opacity(pill.kind == .plain || pill.kind == .keep ? 0.12 : 0.16), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var symbol: String? {
        switch pill.kind {
        case .safe: return "checkmark"
        case .review: return "eye"
        case .keep: return "lock.fill"
        case .crit: return "exclamationmark"
        case .plain: return nil
        }
    }

    private var tint: Color {
        switch pill.kind {
        case .safe: return Palette.safe.color
        case .review: return Palette.review.color
        case .crit: return Palette.crit.color
        case .keep, .plain: return .secondary
        }
    }
}

/// The surface content sits on: a quiet card, never glass.
@MainActor struct Card<Content: View>: View {
    var title: String?
    var subtitle: String?
    var trailing: AnyView?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, subtitle: String? = nil, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if title != nil || trailing != nil {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let title { Text(title).font(.headline) }
                        if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: Space.s)
                    if let trailing { trailing }
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
    }
}

/// A thin proportional bar next to a number.
@MainActor struct MiniBar: View {
    var fraction: Double
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track.color)
                Capsule().fill(color).frame(width: max(2, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

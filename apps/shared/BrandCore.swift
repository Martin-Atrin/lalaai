import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

// Shared by the macOS and iOS presenter apps.

/// La Laai brand palette: Blue #002060, Aqua #45C2F9, Warm #F9606C.
extension Color {
    static let brandNavy = Color(red: 0x00 / 255, green: 0x20 / 255, blue: 0x60 / 255)
    static let brandAqua = Color(red: 0x45 / 255, green: 0xC2 / 255, blue: 0xF9 / 255)
    static let brandWarm = Color(red: 0xF9 / 255, green: 0x60 / 255, blue: 0x6C / 255)
    static let brandWarmLight = Color(red: 0xFF / 255, green: 0x8A / 255, blue: 0x66 / 255)

    /// Primary/tint: navy in light mode, aqua in dark mode (navy is unreadable on dark backgrounds).
    #if canImport(AppKit)
    static let brandPrimary = Color(nsColor: NSColor(name: "brandPrimary") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0x45 / 255, green: 0xC2 / 255, blue: 0xF9 / 255, alpha: 1)
            : NSColor(red: 0x00 / 255, green: 0x20 / 255, blue: 0x60 / 255, alpha: 1)
    })
    #else
    static let brandPrimary = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0x45 / 255, green: 0xC2 / 255, blue: 0xF9 / 255, alpha: 1)
            : UIColor(red: 0x00 / 255, green: 0x20 / 255, blue: 0x60 / 255, alpha: 1)
    })
    #endif
}

/// The logo mark: navy + warm speech bubbles with the aqua drop between them.
struct LogoMark: View {
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width / 240, size.height / 190)
            ctx.translateBy(x: (size.width - 240 * s) / 2, y: (size.height - 190 * s) / 2)
            ctx.scaleBy(x: s, y: s)
            let warm = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [.brandWarmLight, .brandWarm]), startPoint: .init(x: 110, y: 16), endPoint: .init(x: 220, y: 168))
            ctx.fill(Path(ellipseIn: CGRect(x: 20, y: 16, width: 120, height: 120)), with: .color(.brandNavy))
            ctx.fill(Path { p in p.move(to: .init(x: 42, y: 118)); p.addLine(to: .init(x: 22, y: 168)); p.addLine(to: .init(x: 84, y: 134)); p.closeSubpath() }, with: .color(.brandNavy))
            ctx.fill(Path(ellipseIn: CGRect(x: 100, y: 16, width: 120, height: 120)), with: warm)
            ctx.fill(Path { p in p.move(to: .init(x: 198, y: 118)); p.addLine(to: .init(x: 218, y: 168)); p.addLine(to: .init(x: 156, y: 134)); p.closeSubpath() }, with: warm)
            let drop = Path { p in
                p.move(to: .init(x: 120, y: 46))
                p.addCurve(to: .init(x: 154, y: 122), control1: .init(x: 132, y: 70), control2: .init(x: 154, y: 92))
                p.addArc(center: .init(x: 120, y: 122), radius: 34, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
                p.addCurve(to: .init(x: 120, y: 46), control1: .init(x: 86, y: 92), control2: .init(x: 108, y: 70))
                p.closeSubpath()
            }
            ctx.stroke(drop, with: .color(.white), style: .init(lineWidth: 9, lineJoin: .round))
            ctx.fill(drop, with: .color(.brandAqua))
        }
        .aspectRatio(240 / 190, contentMode: .fit)
    }
}

/// "La Laai" wordmark: navy/primary "La", warm gradient "Laai".
struct Wordmark: View {
    var size: CGFloat = 22
    var body: some View {
        HStack(spacing: size * 0.22) {
            Text("La").foregroundStyle(Color.brandPrimary)
            Text("Laai").foregroundStyle(LinearGradient(colors: [.brandWarmLight, .brandWarm], startPoint: .leading, endPoint: .trailing))
        }
        .font(.system(size: size, weight: .heavy, design: .rounded))
    }
}


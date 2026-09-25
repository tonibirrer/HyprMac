// The brand mark drawn in SwiftUI, so it stays crisp at any size and
// needs no asset catalog. Geometry is lifted from the brand kit's
// hyprmac-mark-h-*.svg: a magenta→cyan keycap with an etched H inside
// four rounded focus brackets. Also the lockup (mark + "HyprMac") and
// the "hypr" key chip.

import SwiftUI

// MARK: - mark

/// The HyprMac mark. `brackets: false` draws the key alone (the kit's
/// small mark, meant for sizes under 24 px).
struct HyprMark: View {
    var size: CGFloat
    var showsH = true
    var brackets = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { ctx, canvas in
            // the svg draws the mark in a 450-unit box; the key alone spans 340
            let box: CGFloat = brackets ? 450 : 340
            ctx.scaleBy(x: canvas.width / box, y: canvas.height / box)
            if !brackets { ctx.translateBy(x: -55, y: -55) }
            HyprMarkDrawing.draw(in: ctx, dark: scheme == .dark, showsH: showsH, brackets: brackets)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

enum HyprMarkDrawing {
    static let magenta = Color(red: 0xE8 / 255, green: 0x4B / 255, blue: 0xCB / 255)
    static let cyan = Color(red: 0x56 / 255, green: 0xD8 / 255, blue: 0xF0 / 255)
    static let ink = Color(red: 0x0A / 255, green: 0x0C / 255, blue: 0x12 / 255)
    static let paper = Color(red: 0xEC / 255, green: 0xEC / 255, blue: 0xF1 / 255)

    static func draw(in ctx: GraphicsContext, dark: Bool, showsH: Bool, brackets: Bool) {
        let gradient = Gradient(colors: [magenta, cyan])
        func diagonal(_ r: CGRect) -> GraphicsContext.Shading {
            .linearGradient(gradient, startPoint: r.origin, endPoint: CGPoint(x: r.maxX, y: r.maxY))
        }

        // skirt, darkened so the face reads as raised
        let skirt = CGRect(x: 55, y: 55, width: 340, height: 340)
        let skirtPath = Path(roundedRect: skirt, cornerRadius: 78.2)
        ctx.fill(skirtPath, with: diagonal(skirt))
        ctx.fill(skirtPath, with: .color(.black.opacity(0.38)))

        // face, top highlight and rim
        let face = CGRect(x: 70.3, y: 59.08, width: 309.4, height: 309.4)
        let facePath = Path(roundedRect: face, cornerRadius: 62.9)
        ctx.fill(facePath, with: diagonal(face))
        ctx.fill(facePath, with: .linearGradient(
            Gradient(stops: [
                .init(color: .white.opacity(0.225), location: 0),
                .init(color: .white.opacity(0), location: 0.5)
            ]),
            startPoint: CGPoint(x: face.midX, y: face.minY),
            endPoint: CGPoint(x: face.midX, y: face.maxY)))
        ctx.stroke(Path(roundedRect: face.insetBy(dx: 1.36, dy: 1.36), cornerRadius: 62.9),
                   with: .color(.white.opacity(0.28)), lineWidth: 2.72)

        // etched H: a light lip under a dark cut
        if showsH {
            let strokes = [
                CGRect(x: 175.5, y: 151.9, width: 24.75, height: 123.76),
                CGRect(x: 249.75, y: 151.9, width: 24.75, height: 123.76),
                CGRect(x: 199.25, y: 202.64, width: 51.5, height: 22.28)
            ]
            for r in strokes {
                ctx.fill(Path(roundedRect: r.offsetBy(dx: 0, dy: 3), cornerRadius: 3.47),
                         with: .color(.white.opacity(0.22)))
            }
            for r in strokes {
                ctx.fill(Path(roundedRect: r, cornerRadius: 3.47), with: .color(ink.opacity(0.5)))
            }
        }

        // four brackets, concentric with the key's corners
        guard brackets else { return }
        var corner = Path()
        corner.move(to: CGPoint(x: 11, y: 167))
        corner.addLine(to: CGPoint(x: 11, y: 133.2))
        corner.addRelativeArc(center: CGPoint(x: 133.2, y: 133.2), radius: 122.2,
                              startAngle: .degrees(180), delta: .degrees(90))
        corner.addLine(to: CGPoint(x: 167, y: 11))
        let style = StrokeStyle(lineWidth: 22, lineCap: .round, lineJoin: .round)
        let bracketColor = dark ? paper : ink
        for quarter in 0..<4 {
            var c = ctx
            c.translateBy(x: 225, y: 225)
            c.rotate(by: .degrees(Double(quarter) * 90))
            c.translateBy(x: -225, y: -225)
            c.stroke(corner, with: .color(bracketColor), style: style)
        }
    }
}

// MARK: - lockup

/// Mark plus "HyprMac" in SF Pro Semibold, cap height matched to the key.
/// Ratios follow the brand kit; the gap is a touch wider than the svg's
/// because SwiftUI adds no side bearing of its own.
struct HyprLockup: View {
    var markSize: CGFloat = 22

    var body: some View {
        HStack(spacing: markSize * 0.22) {
            HyprMark(size: markSize)
            Text("HyprMac")
                .font(.system(size: markSize * 1.0723, weight: .semibold))
                .tracking(-0.01 * markSize * 1.0723)
                .foregroundStyle(Color.hyprTextPrimary)
                .lineLimit(1)
                .fixedSize()
                .offset(y: -markSize * 0.026)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("HyprMac")
    }
}

// MARK: - hypr key chip

/// The Hypr modifier as a keycap: the mono word "hypr" in a cyan-tinted
/// chip, as on the website. Same metrics as `KeyChip` so rows line up.
struct HyprKeyChip: View {
    var fontSize: CGFloat = 13

    var body: some View {
        Text("hypr")
            .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minWidth: 28)
            .background(
                RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                    .fill(Color.hyprCyan.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: HyprRadius.md, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.hyprCyan.opacity(0.35), Color.hyprCyan.opacity(0.6)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .foregroundStyle(Color.hyprCyan)
            .accessibilityLabel("Hypr")
    }
}

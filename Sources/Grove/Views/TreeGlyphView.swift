import AppKit
import SwiftUI

/// Subtle native loading badge showing the transparent cutout pruning shears gently pulsing during initial scans.
struct GroveAppIconLoader: View {
    var size: CGFloat = 64
    @LocalState private var isPulsing: Bool = false

    private var cutoutImage: NSImage? {
        if let url = Bundle.main.url(forResource: "AppIconArtwork", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return NSApplication.shared.applicationIconImage
    }

    var body: some View {
        Group {
            if let icon = cutoutImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .scaleEffect(isPulsing ? 1.03 : 0.97)
                    .opacity(isPulsing ? 1.0 : 0.88)
                    .animation(
                        .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                        value: isPulsing
                    )
                    .onAppear { isPulsing = true }
            } else {
                ProgressView()
                    .controlSize(.regular)
            }
        }
    }
}

// MARK: - Official GitHub Octicon Vector Glyphs (16×16 Grid)

enum OcticonKind {
    case repo
    case fileDirectory
    case gitMerge
    case gitBranch
    case gitCommit
    case diffModified
    case upload
    case alert
    case clock
}

struct OcticonGlyph: View {
    let kind: OcticonKind
    var size: CGFloat = 11.5

    var body: some View {
        Canvas { context, canvasSize in
            let s = min(canvasSize.width, canvasSize.height)
            let scale = s / 16.0
            let ox = (canvasSize.width - s) / 2.0
            let oy = (canvasSize.height - s) / 2.0

            var c = context
            c.translateBy(x: ox, y: oy)
            c.scaleBy(x: scale, y: scale)

            let stroke = StrokeStyle(lineWidth: 1.55, lineCap: .round, lineJoin: .round)

            switch kind {
            case .repo:
                var cover = Path()
                cover.move(to: CGPoint(x: 3.0, y: 12.2))
                cover.addLine(to: CGPoint(x: 3.0, y: 3.0))
                cover.addQuadCurve(to: CGPoint(x: 4.8, y: 1.4), control: CGPoint(x: 3.0, y: 1.4))
                cover.addLine(to: CGPoint(x: 13.0, y: 1.4))
                cover.addLine(to: CGPoint(x: 13.0, y: 12.6))
                cover.addLine(to: CGPoint(x: 10.6, y: 12.6))
                c.stroke(cover, with: .foreground, style: stroke)

                var spine = Path()
                spine.move(to: CGPoint(x: 13.0, y: 10.2))
                spine.addLine(to: CGPoint(x: 4.6, y: 10.2))
                spine.addQuadCurve(to: CGPoint(x: 3.0, y: 11.4), control: CGPoint(x: 3.0, y: 10.2))
                spine.addQuadCurve(to: CGPoint(x: 4.6, y: 12.6), control: CGPoint(x: 3.0, y: 12.6))
                spine.addLine(to: CGPoint(x: 5.4, y: 12.6))
                c.stroke(spine, with: .foreground, style: stroke)

                var bookmark = Path()
                bookmark.move(to: CGPoint(x: 5.8, y: 12.0))
                bookmark.addLine(to: CGPoint(x: 5.8, y: 14.8))
                bookmark.addLine(to: CGPoint(x: 7.4, y: 13.7))
                bookmark.addLine(to: CGPoint(x: 9.0, y: 14.8))
                bookmark.addLine(to: CGPoint(x: 9.0, y: 12.0))
                c.stroke(bookmark, with: .foreground, style: stroke)

            case .fileDirectory:
                var folder = Path()
                folder.move(to: CGPoint(x: 2.2, y: 2.2))
                folder.addLine(to: CGPoint(x: 5.6, y: 2.2))
                folder.addLine(to: CGPoint(x: 7.0, y: 4.0))
                folder.addLine(to: CGPoint(x: 13.6, y: 4.0))
                folder.addQuadCurve(to: CGPoint(x: 14.6, y: 5.0), control: CGPoint(x: 14.6, y: 4.0))
                folder.addLine(to: CGPoint(x: 14.6, y: 12.6))
                folder.addQuadCurve(to: CGPoint(x: 13.6, y: 13.6), control: CGPoint(x: 14.6, y: 13.6))
                folder.addLine(to: CGPoint(x: 2.4, y: 13.6))
                folder.addQuadCurve(to: CGPoint(x: 1.4, y: 12.6), control: CGPoint(x: 1.4, y: 13.6))
                folder.addLine(to: CGPoint(x: 1.4, y: 3.2))
                folder.addQuadCurve(to: CGPoint(x: 2.2, y: 2.2), control: CGPoint(x: 1.4, y: 2.2))
                folder.closeSubpath()
                c.stroke(folder, with: .foreground, style: stroke)

            case .gitMerge:
                var trunk = Path()
                trunk.move(to: CGPoint(x: 4.25, y: 5.0))
                trunk.addLine(to: CGPoint(x: 4.25, y: 11.0))
                c.stroke(trunk, with: .foreground, style: stroke)

                var curve = Path()
                curve.move(to: CGPoint(x: 4.25, y: 5.0))
                curve.addCurve(
                    to: CGPoint(x: 10.6, y: 8.25),
                    control1: CGPoint(x: 4.25, y: 7.4),
                    control2: CGPoint(x: 6.7, y: 8.25)
                )
                c.stroke(curve, with: .foreground, style: stroke)

                for pt in [CGPoint(x: 4.25, y: 3.25), CGPoint(x: 4.25, y: 12.75), CGPoint(x: 12.35, y: 8.25)] {
                    let ring = Path(ellipseIn: CGRect(x: pt.x - 1.75, y: pt.y - 1.75, width: 3.5, height: 3.5))
                    c.stroke(ring, with: .foreground, style: stroke)
                }

            case .gitBranch:
                var trunk = Path()
                trunk.move(to: CGPoint(x: 4.25, y: 5.0))
                trunk.addLine(to: CGPoint(x: 4.25, y: 11.0))
                c.stroke(trunk, with: .foreground, style: stroke)

                var fork = Path()
                fork.move(to: CGPoint(x: 11.75, y: 5.0))
                fork.addCurve(
                    to: CGPoint(x: 4.25, y: 9.8),
                    control1: CGPoint(x: 11.75, y: 8.0),
                    control2: CGPoint(x: 4.25, y: 7.0)
                )
                c.stroke(fork, with: .foreground, style: stroke)

                for pt in [CGPoint(x: 4.25, y: 3.25), CGPoint(x: 11.75, y: 3.25), CGPoint(x: 4.25, y: 12.75)] {
                    let ring = Path(ellipseIn: CGRect(x: pt.x - 1.75, y: pt.y - 1.75, width: 3.5, height: 3.5))
                    c.stroke(ring, with: .foreground, style: stroke)
                }

            case .gitCommit:
                var left = Path()
                left.move(to: CGPoint(x: 1.2, y: 8.0))
                left.addLine(to: CGPoint(x: 5.0, y: 8.0))
                c.stroke(left, with: .foreground, style: stroke)

                var right = Path()
                right.move(to: CGPoint(x: 11.0, y: 8.0))
                right.addLine(to: CGPoint(x: 14.8, y: 8.0))
                c.stroke(right, with: .foreground, style: stroke)

                let ring = Path(ellipseIn: CGRect(x: 5.0, y: 5.0, width: 6.0, height: 6.0))
                c.stroke(ring, with: .foreground, style: stroke)

            case .diffModified:
                let box = Path(roundedRect: CGRect(x: 2.0, y: 2.0, width: 12.0, height: 12.0), cornerRadius: 2.2)
                c.stroke(box, with: .foreground, style: stroke)
                let dot = Path(ellipseIn: CGRect(x: 6.0, y: 6.0, width: 4.0, height: 4.0))
                c.fill(dot, with: .foreground)

            case .upload:
                var arrow = Path()
                arrow.move(to: CGPoint(x: 8.0, y: 10.6))
                arrow.addLine(to: CGPoint(x: 8.0, y: 2.6))
                arrow.move(to: CGPoint(x: 4.6, y: 5.8))
                arrow.addLine(to: CGPoint(x: 8.0, y: 2.4))
                arrow.addLine(to: CGPoint(x: 11.4, y: 5.8))
                c.stroke(arrow, with: .foreground, style: stroke)

                var tray = Path()
                tray.move(to: CGPoint(x: 2.2, y: 10.8))
                tray.addLine(to: CGPoint(x: 2.2, y: 12.6))
                tray.addQuadCurve(to: CGPoint(x: 3.4, y: 13.8), control: CGPoint(x: 2.2, y: 13.8))
                tray.addLine(to: CGPoint(x: 12.6, y: 13.8))
                tray.addQuadCurve(to: CGPoint(x: 13.8, y: 12.6), control: CGPoint(x: 13.8, y: 13.8))
                tray.addLine(to: CGPoint(x: 13.8, y: 10.8))
                c.stroke(tray, with: .foreground, style: stroke)

            case .alert:
                var tri = Path()
                tri.move(to: CGPoint(x: 8.0, y: 2.0))
                tri.addLine(to: CGPoint(x: 14.3, y: 13.3))
                tri.addLine(to: CGPoint(x: 1.7, y: 13.3))
                tri.closeSubpath()
                c.stroke(tri, with: .foreground, style: stroke)

                var ex = Path()
                ex.move(to: CGPoint(x: 8.0, y: 6.2))
                ex.addLine(to: CGPoint(x: 8.0, y: 9.4))
                c.stroke(ex, with: .foreground, style: stroke)

                let dot = Path(ellipseIn: CGRect(x: 7.2, y: 10.8, width: 1.6, height: 1.6))
                c.fill(dot, with: .foreground)

            case .clock:
                let circle = Path(ellipseIn: CGRect(x: 1.8, y: 1.8, width: 12.4, height: 12.4))
                c.stroke(circle, with: .foreground, style: stroke)

                var hands = Path()
                hands.move(to: CGPoint(x: 8.0, y: 4.5))
                hands.addLine(to: CGPoint(x: 8.0, y: 8.2))
                hands.addLine(to: CGPoint(x: 10.6, y: 9.8))
                c.stroke(hands, with: .foreground, style: stroke)
            }
        }
        .frame(width: size, height: size)
    }
}

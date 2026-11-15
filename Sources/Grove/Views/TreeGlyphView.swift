import AppKit
import SwiftUI

/// Simplified flat-design Tree glyph matching Grove's Candidate 1 app icon:
/// a minimal Y-forked trunk beneath a balanced three-circle overlapping canopy.
struct GroveTreeGlyph: View {
    var trunkColor: Color = .primary
    var leftCanopyColor: Color = .primary.opacity(0.68)
    var rightCanopyColor: Color = .primary.opacity(0.84)
    var topCanopyColor: Color = .primary

    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height)
            var c = context
            c.translateBy(x: size.width / 2, y: size.height / 2)
            c.scaleBy(x: s / 100.0, y: s / 100.0)

            // 1. Minimal tapered trunk + Y-fork branches
            var trunk = Path()
            trunk.move(to: CGPoint(x: -5.5, y: 44))
            trunk.addLine(to: CGPoint(x: -3.8, y: 15))
            trunk.addLine(to: CGPoint(x: 3.8, y: 15))
            trunk.addLine(to: CGPoint(x: 5.5, y: 44))
            trunk.closeSubpath()
            c.fill(trunk, with: .color(trunkColor))

            let branchStyle = StrokeStyle(lineWidth: 6.2, lineCap: .round, lineJoin: .round)
            var fork = Path()
            fork.move(to: CGPoint(x: -14, y: 2))
            fork.addLine(to: CGPoint(x: 0, y: 17))
            fork.addLine(to: CGPoint(x: 14, y: 2))
            c.stroke(fork, with: .color(trunkColor), style: branchStyle)

            // 2. Three overlapping geometric canopy circles (left, right, top-center)
            let leftCrown = Path(ellipseIn: CGRect(x: -38, y: -27, width: 42, height: 42))
            c.fill(leftCrown, with: .color(leftCanopyColor))

            let rightCrown = Path(ellipseIn: CGRect(x: -4, y: -27, width: 42, height: 42))
            c.fill(rightCrown, with: .color(rightCanopyColor))

            let topCrown = Path(ellipseIn: CGRect(x: -22, y: -44, width: 44, height: 44))
            c.fill(topCrown, with: .color(topCanopyColor))
        }
    }
}

/// Gentle swaying flat tree indicator shown in the toolbar and empty state while scanning.
struct SwayingTreeIndicator: View {
    var size: CGFloat = 24
    @LocalState private var isSwaying: Bool = false

    var body: some View {
        GroveTreeGlyph(
            trunkColor: Color(red: 0.58, green: 0.36, blue: 0.16),
            leftCanopyColor: Color(red: 0.30, green: 0.83, blue: 0.60),
            rightCanopyColor: Color(red: 0.06, green: 0.72, blue: 0.48),
            topCanopyColor: Color(red: 0.05, green: 0.66, blue: 0.44).opacity(0.92)
        )
        .frame(width: size, height: size)
        .rotationEffect(.degrees(isSwaying ? 4.5 : -4.5), anchor: .bottom)
        .scaleEffect(isSwaying ? 1.03 : 0.97, anchor: .bottom)
        .animation(
            .easeInOut(duration: 0.65).repeatForever(autoreverses: true),
            value: isSwaying
        )
        .onAppear {
            isSwaying = true
        }
    }
}

enum MenuBarTreeImage {
    /// Crisp monochrome flat template tree (`isTemplate = true`) with subtle alpha layering
    /// matching Candidate 1's overlapping three-circle canopy in light and dark macOS menu bars.
    @MainActor
    static func makeTemplateImage(pointSize: CGFloat = 18) -> NSImage {
        let view = GroveTreeGlyph(
            trunkColor: .black,
            leftCanopyColor: .black.opacity(0.62),
            rightCanopyColor: .black.opacity(0.78),
            topCanopyColor: .black.opacity(0.95)
        )
        .frame(width: pointSize, height: pointSize)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0

        if let cgImage = renderer.cgImage {
            let img = NSImage(cgImage: cgImage, size: NSSize(width: pointSize, height: pointSize))
            img.isTemplate = true
            return img
        }
        return NSImage(size: NSSize(width: pointSize, height: pointSize))
    }
}

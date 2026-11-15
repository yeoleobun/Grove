#!/usr/bin/env swift
import AppKit
import Foundation
import SwiftUI

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: generate_icon.swift <output.iconset> [artwork.jpg]\n", stderr)
    exit(1)
}

let iconsetPath = CommandLine.arguments[1]
let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let rootDir = scriptDir.deletingLastPathComponent()
let artworkPath = CommandLine.arguments.count >= 3
    ? CommandLine.arguments[2]
    : rootDir.appendingPathComponent("Resources/AppIconArtwork.jpg").path

guard let artworkImage = NSImage(contentsOfFile: artworkPath) else {
    fputs("Error: could not load icon artwork at \(artworkPath)\n", stderr)
    exit(1)
}

let fm = FileManager.default
try? fm.removeItem(atPath: iconsetPath)
try fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

/// Authentic Apple macOS continuous squircle plate (824x824 inside 1024x1024)
/// Prevents macOS 26 Dock from wrapping the icon in a gray system container.
struct GroveAppIcon: View {
    let image: NSImage
    let size: CGFloat

    var body: some View {
        let pad = size * (100.0 / 1024.0)
        let box = size - pad * 2
        let radius = box * 0.225

        ZStack {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .scaledToFill()
                .frame(width: box, height: box)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .shadow(color: .black.opacity(0.20), radius: size * 0.024, x: 0, y: size * 0.011)
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.75), Color.black.opacity(0.08)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: max(0.5, size * 0.0025)
                        )
                )
        }
        .frame(width: size, height: size)
    }
}

@MainActor
func writeIcon(pixels: Int, filename: String) throws {
    let size = CGFloat(pixels)
    let renderer = ImageRenderer(content: GroveAppIcon(image: artworkImage, size: size))
    renderer.scale = 1.0
    guard let cgImage = renderer.cgImage else {
        throw NSError(domain: "GenerateIcon", code: 1)
    }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = NSSize(width: size, height: size)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "GenerateIcon", code: 2)
    }
    let outURL = URL(fileURLWithPath: iconsetPath).appendingPathComponent(filename)
    try png.write(to: outURL)
}

let specs: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

try MainActor.assumeIsolated {
    for (px, name) in specs {
        try writeIcon(pixels: px, filename: name)
    }
}

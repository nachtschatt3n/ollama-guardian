#!/usr/bin/env swift
// One-shot generator for macOS AppIcon iconset + .icns.
// Renders GuardianBrandMark via SwiftUI ImageRenderer at every required size.
// Usage: swift scripts/generate-app-icon.swift
// Output: assets/AppIcon.iconset/* PNGs and Sources/local-ollama-monitor/Resources/AppIcon.icns

import AppKit
import Foundation
import SwiftUI

private struct BrandPalette {
    var background = Color(nsColor: NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.24, alpha: 1))
    var backgroundHighlight = Color(nsColor: NSColor(calibratedRed: 0.18, green: 0.30, blue: 0.41, alpha: 1))
    var fur = Color(nsColor: NSColor(calibratedRed: 0.89, green: 0.84, blue: 0.75, alpha: 1))
    var furShadow = Color(nsColor: NSColor(calibratedRed: 0.77, green: 0.70, blue: 0.60, alpha: 1))
    var muzzle = Color(nsColor: NSColor(calibratedRed: 0.96, green: 0.92, blue: 0.86, alpha: 1))
    var nose = Color(nsColor: NSColor(calibratedRed: 0.28, green: 0.26, blue: 0.24, alpha: 1))
    var hat = Color(nsColor: NSColor(calibratedRed: 0.11, green: 0.18, blue: 0.28, alpha: 1))
    var hatBand = Color(nsColor: NSColor(calibratedRed: 0.26, green: 0.69, blue: 0.63, alpha: 1))
    var badge = Color(nsColor: NSColor(calibratedRed: 0.96, green: 0.78, blue: 0.33, alpha: 1))
    var eye = Color.black.opacity(0.85)
}

private struct PoliceBadgeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cx = rect.midX
        let cy = rect.midY
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.48
        for index in 0..<6 {
            let outerAngle = Angle.degrees(Double(index) * 60 - 90)
            let innerAngle = Angle.degrees(Double(index) * 60 + 30 - 90)
            let op = CGPoint(x: cx + cos(outerAngle.radians) * outer, y: cy + sin(outerAngle.radians) * outer)
            let ip = CGPoint(x: cx + cos(innerAngle.radians) * inner, y: cy + sin(innerAngle.radians) * inner)
            if index == 0 { path.move(to: op) } else { path.addLine(to: op) }
            path.addLine(to: ip)
        }
        path.closeSubpath()
        return path
    }
}

private struct BrandMark: View {
    var showPlate: Bool = true
    private let palette = BrandPalette()

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                if showPlate {
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .fill(LinearGradient(colors: [palette.backgroundHighlight, palette.background], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                llama(size: size)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder private func llama(size: CGFloat) -> some View {
        let faceWidth = size * 0.46
        let faceHeight = size * 0.40
        ZStack {
            RoundedRectangle(cornerRadius: faceWidth * 0.32, style: .continuous)
                .fill(palette.furShadow)
                .frame(width: faceWidth * 1.02, height: faceHeight * 1.05)
                .offset(y: size * 0.065)

            ear(left: true, size: size).offset(x: -size * 0.16, y: -size * 0.12)
            ear(left: false, size: size).offset(x: size * 0.16, y: -size * 0.12)

            VStack(spacing: 0) {
                policeHat(size: size).offset(y: size * 0.01)
                ZStack {
                    RoundedRectangle(cornerRadius: faceWidth * 0.32, style: .continuous)
                        .fill(palette.fur)
                        .frame(width: faceWidth, height: faceHeight)
                    RoundedRectangle(cornerRadius: faceWidth * 0.23, style: .continuous)
                        .fill(palette.muzzle)
                        .frame(width: faceWidth * 0.48, height: faceHeight * 0.28)
                        .offset(y: faceHeight * 0.16)
                    HStack(spacing: faceWidth * 0.2) {
                        Circle().fill(palette.eye).frame(width: faceWidth * 0.055, height: faceWidth * 0.055)
                        Circle().fill(palette.eye).frame(width: faceWidth * 0.055, height: faceWidth * 0.055)
                    }
                    .offset(y: -faceHeight * 0.03)
                    VStack(spacing: faceHeight * 0.03) {
                        RoundedRectangle(cornerRadius: faceWidth * 0.06, style: .continuous)
                            .fill(palette.nose)
                            .frame(width: faceWidth * 0.12, height: faceHeight * 0.055)
                        HStack(spacing: faceWidth * 0.04) {
                            RoundedRectangle(cornerRadius: faceWidth * 0.03, style: .continuous)
                                .fill(palette.nose.opacity(0.75))
                                .frame(width: faceWidth * 0.06, height: faceHeight * 0.02)
                            RoundedRectangle(cornerRadius: faceWidth * 0.03, style: .continuous)
                                .fill(palette.nose.opacity(0.75))
                                .frame(width: faceWidth * 0.06, height: faceHeight * 0.02)
                        }
                    }
                    .offset(y: faceHeight * 0.10)
                }
                .offset(y: -size * 0.01)
            }
        }
        .offset(y: showPlate ? -size * 0.01 : 0)
    }

    @ViewBuilder private func ear(left: Bool, size: CGFloat) -> some View {
        let path = Path { p in
            p.move(to: CGPoint(x: 0.50, y: 0.00))
            p.addLine(to: CGPoint(x: 0.90, y: 0.98))
            p.addQuadCurve(to: CGPoint(x: 0.10, y: 0.98), control: CGPoint(x: 0.50, y: 0.76))
            p.closeSubpath()
        }
        ZStack {
            path.fill(palette.furShadow)
            path.fill(palette.fur).padding(size * 0.012)
            path.fill(palette.muzzle.opacity(0.92)).padding(size * 0.038)
        }
        .frame(width: size * 0.16, height: size * 0.22)
        .rotationEffect(.degrees(left ? -18 : 18))
    }

    @ViewBuilder private func policeHat(size: CGFloat) -> some View {
        let crown = Path { p in
            p.move(to: CGPoint(x: 0.18, y: 0.86))
            p.addLine(to: CGPoint(x: 0.30, y: 0.18))
            p.addQuadCurve(to: CGPoint(x: 0.70, y: 0.18), control: CGPoint(x: 0.50, y: -0.02))
            p.addLine(to: CGPoint(x: 0.82, y: 0.86))
            p.closeSubpath()
        }
        ZStack {
            crown
                .fill(LinearGradient(colors: [palette.hat.opacity(0.94), palette.hat.opacity(0.78)], startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.40, height: size * 0.18)
                .offset(y: -size * 0.015)
            RoundedRectangle(cornerRadius: size * 0.03, style: .continuous)
                .fill(palette.hatBand)
                .frame(width: size * 0.30, height: size * 0.032)
                .offset(y: size * 0.002)
            Capsule()
                .fill(palette.hat)
                .frame(width: size * 0.46, height: size * 0.08)
                .offset(y: size * 0.06)
            PoliceBadgeShape()
                .fill(palette.badge)
                .frame(width: size * 0.09, height: size * 0.09)
                .overlay {
                    Circle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: size * 0.025, height: size * 0.025)
                }
                .offset(y: size * 0.01)
        }
        .frame(width: size * 0.5, height: size * 0.24)
    }
}

@MainActor
func renderPNG(size: CGFloat, scale: CGFloat, to path: String) {
    let view = BrandMark(showPlate: true)
        .frame(width: size, height: size)
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    renderer.isOpaque = false
    guard let cg = renderer.cgImage else {
        FileHandle.standardError.write(Data("failed to render \(path)\n".utf8))
        exit(1)
    }
    let rep = NSBitmapImageRep(cgImage: cg)
    rep.size = NSSize(width: size, height: size)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("failed to encode \(path)\n".utf8))
        exit(1)
    }
    try? data.write(to: URL(fileURLWithPath: path))
    FileHandle.standardOutput.write(Data("wrote \(path)\n".utf8))
}

@MainActor
func main() {
    let cwd = FileManager.default.currentDirectoryPath
    let iconset = "\(cwd)/assets/AppIcon.iconset"
    let icnsPath = "\(cwd)/Sources/local-ollama-monitor/Resources/AppIcon.icns"
    try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

    let entries: [(name: String, size: CGFloat, scale: CGFloat)] = [
        ("icon_16x16.png", 16, 1),
        ("icon_16x16@2x.png", 16, 2),
        ("icon_32x32.png", 32, 1),
        ("icon_32x32@2x.png", 32, 2),
        ("icon_128x128.png", 128, 1),
        ("icon_128x128@2x.png", 128, 2),
        ("icon_256x256.png", 256, 1),
        ("icon_256x256@2x.png", 256, 2),
        ("icon_512x512.png", 512, 1),
        ("icon_512x512@2x.png", 512, 2),
    ]

    for entry in entries {
        renderPNG(size: entry.size, scale: entry.scale, to: "\(iconset)/\(entry.name)")
    }

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    task.arguments = ["-c", "icns", iconset, "-o", icnsPath]
    do {
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus == 0 {
            FileHandle.standardOutput.write(Data("wrote \(icnsPath)\n".utf8))
        } else {
            FileHandle.standardError.write(Data("iconutil exited with status \(task.terminationStatus)\n".utf8))
            exit(1)
        }
    } catch {
        FileHandle.standardError.write(Data("failed to run iconutil: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

MainActor.assumeIsolated { main() }

import AppKit
import SwiftUI

enum GuardianBrandVariant {
    case logo
    case tray
    case watermark
}

private struct GuardianBrandPalette {
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

struct GuardianBrandMark: View {
    var showPlate: Bool = true

    private let palette = GuardianBrandPalette()

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)

            ZStack {
                if showPlate {
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [palette.backgroundHighlight, palette.background],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                llama(size: size)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder
    private func llama(size: CGFloat) -> some View {
        let faceWidth = size * 0.46
        let faceHeight = size * 0.40

        ZStack {
            RoundedRectangle(cornerRadius: faceWidth * 0.32, style: .continuous)
                .fill(palette.furShadow)
                .frame(width: faceWidth * 1.02, height: faceHeight * 1.05)
                .offset(y: size * 0.065)

            ear(left: true, size: size)
                .offset(x: -size * 0.16, y: -size * 0.12)
            ear(left: false, size: size)
                .offset(x: size * 0.16, y: -size * 0.12)

            VStack(spacing: 0) {
                policeHat(size: size)
                    .offset(y: size * 0.01)

                ZStack {
                    RoundedRectangle(cornerRadius: faceWidth * 0.32, style: .continuous)
                        .fill(palette.fur)
                        .frame(width: faceWidth, height: faceHeight)

                    RoundedRectangle(cornerRadius: faceWidth * 0.23, style: .continuous)
                        .fill(palette.muzzle)
                        .frame(width: faceWidth * 0.48, height: faceHeight * 0.28)
                        .offset(y: faceHeight * 0.16)

                    HStack(spacing: faceWidth * 0.2) {
                        Circle()
                            .fill(palette.eye)
                            .frame(width: faceWidth * 0.055, height: faceWidth * 0.055)
                        Circle()
                            .fill(palette.eye)
                            .frame(width: faceWidth * 0.055, height: faceWidth * 0.055)
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

    @ViewBuilder
    private func ear(left: Bool, size: CGFloat) -> some View {
        let path = Path { path in
            path.move(to: CGPoint(x: 0.50, y: 0.00))
            path.addLine(to: CGPoint(x: 0.90, y: 0.98))
            path.addQuadCurve(to: CGPoint(x: 0.10, y: 0.98), control: CGPoint(x: 0.50, y: 0.76))
            path.closeSubpath()
        }

        ZStack {
            path
                .fill(palette.furShadow)
            path
                .fill(palette.fur)
                .padding(size * 0.012)
            path
                .fill(palette.muzzle.opacity(0.92))
                .padding(size * 0.038)
        }
        .frame(width: size * 0.16, height: size * 0.22)
        .rotationEffect(.degrees(left ? -18 : 18))
    }

    @ViewBuilder
    private func policeHat(size: CGFloat) -> some View {
        let crown = Path { path in
            path.move(to: CGPoint(x: 0.18, y: 0.86))
            path.addLine(to: CGPoint(x: 0.30, y: 0.18))
            path.addQuadCurve(to: CGPoint(x: 0.70, y: 0.18), control: CGPoint(x: 0.50, y: -0.02))
            path.addLine(to: CGPoint(x: 0.82, y: 0.86))
            path.closeSubpath()
        }

        ZStack {
            crown
                .fill(
                    LinearGradient(
                        colors: [palette.hat.opacity(0.94), palette.hat.opacity(0.78)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
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

            GuardianPoliceBadgeShape()
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

private struct GuardianPoliceBadgeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cx = rect.midX
        let cy = rect.midY
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.48

        for index in 0..<6 {
            let outerAngle = Angle.degrees(Double(index) * 60 - 90)
            let innerAngle = Angle.degrees(Double(index) * 60 + 30 - 90)

            let outerPoint = CGPoint(
                x: cx + cos(outerAngle.radians) * outer,
                y: cy + sin(outerAngle.radians) * outer
            )
            let innerPoint = CGPoint(
                x: cx + cos(innerAngle.radians) * inner,
                y: cy + sin(innerAngle.radians) * inner
            )

            if index == 0 {
                path.move(to: outerPoint)
            } else {
                path.addLine(to: outerPoint)
            }
            path.addLine(to: innerPoint)
        }

        path.closeSubpath()
        return path
    }
}

private enum GuardianBrandAssets {
    static func nsImage(for variant: GuardianBrandVariant) -> NSImage? {
        let name: String
        switch variant {
        case .logo, .watermark:
            name = "guardian-brand-large"
        case .tray:
            name = "guardian-brand-tray"
        }

        guard let url = Bundle.module.url(forResource: name, withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}

struct GuardianBrandGraphic: View {
    let variant: GuardianBrandVariant

    var body: some View {
        if let image = GuardianBrandAssets.nsImage(for: variant) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .aspectRatio(contentMode: .fit)
        } else {
            GuardianBrandMark(showPlate: variant != .tray)
        }
    }
}

enum GuardianBrandRenderer {
    @MainActor
    static func trayImage() -> NSImage? {
        if let image = GuardianBrandAssets.nsImage(for: .tray) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = false
            return image
        }

        let renderer = ImageRenderer(
            content: GuardianBrandMark(showPlate: false)
                .frame(width: 18, height: 18)
                .foregroundStyle(.black)
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        return image
    }
}

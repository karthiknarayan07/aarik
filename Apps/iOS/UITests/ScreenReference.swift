import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Compares pixels, with a tolerance, so a reference screenshot survives font smoothing and encoder noise but not a
/// moved or clipped view.
enum PixelDiff {
    struct Result {
        /// Pixels whose colour differs by more than the channel tolerance, outside the mask.
        let differing: Int
        /// Pixels compared (the image minus the mask).
        let compared: Int
        /// The expected image dimmed, with every differing pixel in red; nil when the sizes differ.
        let image: CGImage?

        var fraction: Double { compared == 0 ? 0 : Double(differing) / Double(compared) }
    }

    /// - Parameters:
    ///   - maskTop: rows (pixels) at the top ignored in both images: the status bar's clock and battery change.
    ///   - channelTolerance: how far one 8-bit channel may differ before the pixel counts.
    static func compare(
        actual: CGImage, expected: CGImage, maskTop: Int, channelTolerance: Int = 12
    ) -> Result {
        guard actual.width == expected.width, actual.height == expected.height,
            let a = rgba(actual), let e = rgba(expected)
        else { return Result(differing: max(actual.width * actual.height, 1), compared: 1, image: nil) }
        let width = actual.width
        let height = actual.height
        var out = [UInt8](repeating: 255, count: width * height * 4)
        var differing = 0
        let firstRow = min(max(maskTop, 0), height)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                var differs = false
                if y >= firstRow {
                    for c in 0..<3 where abs(Int(a[i + c]) - Int(e[i + c])) > channelTolerance { differs = true }
                }
                if differs {
                    differing += 1
                    out[i] = 255
                    out[i + 1] = 0
                    out[i + 2] = 0
                } else {
                    for c in 0..<3 { out[i + c] = UInt8(255 - (255 - Int(e[i + c])) / 3) }
                }
                out[i + 3] = 255
            }
        }
        let image = out.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        return Result(differing: differing, compared: (height - firstRow) * width, image: image)
    }

    private static func rgba(_ image: CGImage) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? bytes : nil
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

extension AppTestCase {
    /// The folder of reference screenshots, next to this file (the Simulator reads and writes the Mac's files).
    private static var referenceDirectory: URL {
        URL(filePath: #filePath).deletingLastPathComponent().appending(path: "References", directoryHint: .isDirectory)
    }

    /// Reference screenshots are of this device: the iPhone 17 (393 x 852 pt at 3x). On another device the
    /// comparison is skipped, because the same layout legitimately looks different.
    private static let referenceScreenPixels = CGSize(width: 1179, height: 2556)

    /// Compares the whole screen with `References/<name>.png`. With `RECORD_SNAPSHOTS=1` (pass it as
    /// `TEST_RUNNER_RECORD_SNAPSHOTS=1`) the reference is written instead. On a mismatch the actual, expected and
    /// diff images are attached to the test. The status bar is masked; `tolerance` is the share of pixels that may
    /// differ.
    func assertScreenMatchesReference(
        _ name: String, tolerance: Double = 0.004, file: StaticString = #filePath, line: UInt = #line
    ) {
        let screenshot = XCUIScreen.main.screenshot()
        guard let actual = screenshot.image.cgImage else {
            XCTFail("No image for \(name)", file: file, line: line)
            return
        }
        guard CGSize(width: actual.width, height: actual.height) == Self.referenceScreenPixels else { return }
        let url = Self.referenceDirectory.appending(path: "\(name).png")
        if ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "1" {
            try? FileManager.default.createDirectory(at: Self.referenceDirectory, withIntermediateDirectories: true)
            guard let data = PixelDiff.png(actual), (try? data.write(to: url)) != nil else {
                XCTFail("Couldn't record \(name)", file: file, line: line)
                return
            }
            return
        }
        guard let expected = PixelDiff.load(url) else {
            XCTFail(
                "No reference screenshot for \(name); record with RECORD_SNAPSHOTS=1 (scripts/ios-ui-tests.sh --record-snapshots)",
                file: file, line: line)
            return
        }
        // The status bar plus the Dynamic Island (62 pt) at 3x.
        let result = PixelDiff.compare(actual: actual, expected: expected, maskTop: 62 * 3)
        guard result.fraction > tolerance else { return }
        attachImage(UIImage(cgImage: actual), named: "\(name) actual")
        attachImage(UIImage(cgImage: expected), named: "\(name) expected")
        if let diff = result.image { attachImage(UIImage(cgImage: diff), named: "\(name) diff") }
        XCTFail(
            "\(name) differs from its reference in \(String(format: "%.2f", result.fraction * 100)) % of its pixels "
                + "(allowed \(String(format: "%.2f", tolerance * 100)) %)",
            file: file, line: line)
    }

    private func attachImage(_ image: UIImage, named name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

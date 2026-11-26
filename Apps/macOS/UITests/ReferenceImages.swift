import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Pixel comparison of a window screenshot against a PNG in `References/`, without a dependency.
///
/// `RECORD_SNAPSHOTS=1` writes the reference instead of comparing (pass it to the test runner as
/// `TEST_RUNNER_RECORD_SNAPSHOTS=1`; `scripts/record-mac-references.sh` does and copies the result into
/// `References/`, since the sandboxed runner can only write to its own temporary folder). A mismatch attaches the
/// actual, expected and difference images to the test.
enum ReferenceImages {
    /// A pixel differs when any colour channel is further than this (0 to 255) from the reference: enough to ignore
    /// anti-aliasing noise, not a changed colour.
    static let channelThreshold = 24
    /// The share of differing pixels that still counts as the same picture.
    static let allowedFraction = 0.002

    static let directory = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "References", directoryHint: .isDirectory)

    /// Where recording writes: the runner's sandbox allows nothing else.
    static let recordingDirectory = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
        .appending(path: "ui-references", directoryHint: .isDirectory)

    static var isRecording: Bool { ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "1" }

    /// Compares `screenshot` with `References/<name>.png`, or records it.
    @MainActor
    static func assertMatches(
        _ screenshot: XCUIScreenshot, named name: String, in testCase: XCTestCase, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let url = directory.appending(path: "\(name).png")
        if isRecording {
            do {
                try FileManager.default.createDirectory(at: recordingDirectory, withIntermediateDirectories: true)
                try screenshot.pngRepresentation.write(to: recordingDirectory.appending(path: "\(name).png"))
            } catch {
                XCTFail("Couldn't record \(name): \(error)", file: file, line: line)
            }
            return
        }
        guard let expectedData = try? Data(contentsOf: url), let expected = decode(expectedData) else {
            XCTFail("No reference \(name).png (record with RECORD_SNAPSHOTS=1)", file: file, line: line)
            attach(screenshot.image, named: "\(name) actual", to: testCase)
            return
        }
        guard let actual = decode(screenshot.pngRepresentation) else {
            XCTFail("Couldn't read the screenshot of \(name)", file: file, line: line)
            return
        }
        let result = compare(actual: actual, expected: expected)
        guard result.fraction > allowedFraction else { return }
        attach(screenshot.image, named: "\(name) actual", to: testCase)
        attach(image(from: expected), named: "\(name) expected", to: testCase)
        if let diff = result.diff { attach(diff, named: "\(name) difference", to: testCase) }
        let percent = (result.fraction * 100).formatted(.number.precision(.fractionLength(2)))
        let size =
            result.sizeMismatch
            ? " (sizes differ: \(actual.width)×\(actual.height) vs \(expected.width)×\(expected.height))" : ""
        XCTFail("\(name) differs from its reference in \(percent) % of its pixels\(size)", file: file, line: line)
    }

    // MARK: Comparison

    struct Comparison {
        let fraction: Double
        let sizeMismatch: Bool
        let diff: NSImage?
    }

    /// The share of pixels that differ, and an image of them in red over a faded copy of the reference.
    static func compare(actual: CGImage, expected: CGImage) -> Comparison {
        guard actual.width == expected.width, actual.height == expected.height else {
            return Comparison(fraction: 1, sizeMismatch: true, diff: nil)
        }
        let width = actual.width
        let height = actual.height
        guard let a = pixels(of: actual), let e = pixels(of: expected) else {
            return Comparison(fraction: 1, sizeMismatch: false, diff: nil)
        }
        var out = [UInt8](repeating: 255, count: a.count)
        var differing = 0
        for pixel in 0..<(width * height) {
            let i = pixel * 4
            var worst = 0
            for channel in 0..<3 { worst = max(worst, abs(Int(a[i + channel]) - Int(e[i + channel]))) }
            if worst > channelThreshold {
                differing += 1
                out[i] = 255
                out[i + 1] = 0
                out[i + 2] = 0
            } else {
                for channel in 0..<3 { out[i + channel] = UInt8(160 + Int(e[i + channel]) * 95 / 255) }
            }
        }
        return Comparison(
            fraction: Double(differing) / Double(width * height), sizeMismatch: false,
            diff: differing == 0 ? nil : image(fromRGBA: out, width: width, height: height))
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 8-bit RGBA, premultiplied last, in sRGB.
    private static func pixels(of image: CGImage) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? bytes : nil
    }

    private static func image(fromRGBA bytes: [UInt8], width: Int, height: Int) -> NSImage? {
        var bytes = bytes
        let cg = bytes.withUnsafeMutableBytes { buffer -> CGImage? in
            CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        return cg.map { NSImage(cgImage: $0, size: NSSize(width: width, height: height)) }
    }

    private static func image(from cg: CGImage) -> NSImage {
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    @MainActor
    private static func attach(_ image: NSImage?, named name: String, to testCase: XCTestCase) {
        guard let image else { return }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }
}

import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Configuration for generating synthetic test images offline without touching any user files.
public struct ImageFixtureOptions: Sendable {
    public var width: Int = 1200
    public var height: Int = 900
    public var utType: UTType = .heic
    public var orientation: Int = 1
    public var withAlpha: Bool = false
    public var frameCount: Int = 1
    public var colorSpaceName: String = CGColorSpace.displayP3 as String
    public var cameraMake: String? = "Apple"
    public var cameraModel: String? = "iPhone 17 Pro"
    public var lensModel: String? = "Main 24mm f/1.78"
    public var dateTimeOriginal: String? = "2026:11:27 10:15:30"
    public var gpsLatitude: Double? = 37.3349
    public var gpsLongitude: Double? = -122.0090
    public var iptcCaption: String? = "Test photo caption"
    public var livePhotoContentID: String? = nil
    public var includeGainMap: Bool = false
    public var extendedAttributes: [String: Data] = [:]

    public init() {}
}

public enum ImageFixtureFactory {
    /// Writes a synthetic image to a fresh temp directory and returns its file URL.
    public static func makeImage(_ options: ImageFixtureOptions = ImageFixtureOptions()) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "image-fixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = options.utType.preferredFilenameExtension ?? "heic"
        let url = dir.appending(path: "fixture.\(ext)")

        let destType: String =
            if options.frameCount > 1, options.utType == .heic {
                "public.heics"
            } else {
                options.utType.identifier
            }

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, destType as CFString, options.frameCount, nil)
        else {
            throw NSError(domain: "ImageFixtureFactory", code: 1)
        }

        let baseProps = buildProperties(options)
        for frameIndex in 0..<max(1, options.frameCount) {
            let image = try renderPatternImage(
                width: options.width,
                height: options.height,
                seed: frameIndex,
                withAlpha: options.withAlpha,
                colorSpaceName: options.colorSpaceName
            )
            var frameProps = baseProps
            if options.frameCount > 1 {
                if options.utType == .gif {
                    frameProps[kCGImagePropertyGIFDictionary as String] = [
                        kCGImagePropertyGIFDelayTime as String: 0.1
                    ]
                } else if options.utType == .png {
                    frameProps[kCGImagePropertyPNGDictionary as String] = [
                        kCGImagePropertyAPNGDelayTime as String: 0.1
                    ]
                } else if options.utType == .heic {
                    frameProps[kCGImagePropertyHEICSDictionary as String] = [
                        kCGImagePropertyHEICSDelayTime as String: 0.1
                    ]
                }
            }
            CGImageDestinationAddImage(dest, image, frameProps as CFDictionary)
        }

        if options.includeGainMap {
            let gainMap = try makeGainMapPayload(width: max(64, options.width / 2), height: max(64, options.height / 2))
            CGImageDestinationAddAuxiliaryDataInfo(dest, kCGImageAuxiliaryDataTypeHDRGainMap, gainMap as CFDictionary)
        }

        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "ImageFixtureFactory", code: 2)
        }

        for (name, data) in options.extendedAttributes {
            _ = data.withUnsafeBytes {
                setxattr(url.path, name, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW)
            }
        }
        return url
    }

    private static func buildProperties(_ options: ImageFixtureOptions) -> [String: Any] {
        var props: [String: Any] = [
            kCGImagePropertyOrientation as String: options.orientation
        ]
        var tiff: [String: Any] = [kCGImagePropertyTIFFOrientation as String: options.orientation]
        if let make = options.cameraMake { tiff[kCGImagePropertyTIFFMake as String] = make }
        if let model = options.cameraModel { tiff[kCGImagePropertyTIFFModel as String] = model }
        props[kCGImagePropertyTIFFDictionary as String] = tiff

        var exif: [String: Any] = [:]
        if let lens = options.lensModel { exif[kCGImagePropertyExifLensModel as String] = lens }
        if let date = options.dateTimeOriginal { exif[kCGImagePropertyExifDateTimeOriginal as String] = date }
        exif[kCGImagePropertyExifISOSpeedRatings as String] = [100]
        props[kCGImagePropertyExifDictionary as String] = exif

        if let lat = options.gpsLatitude, let lon = options.gpsLongitude {
            props[kCGImagePropertyGPSDictionary as String] = [
                kCGImagePropertyGPSLatitude as String: abs(lat),
                kCGImagePropertyGPSLatitudeRef as String: lat >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude as String: abs(lon),
                kCGImagePropertyGPSLongitudeRef as String: lon >= 0 ? "E" : "W",
            ]
        }
        if let caption = options.iptcCaption {
            props[kCGImagePropertyIPTCDictionary as String] = [
                kCGImagePropertyIPTCCaptionAbstract as String: caption
            ]
        }
        if let contentID = options.livePhotoContentID {
            props[kCGImagePropertyMakerAppleDictionary as String] = ["17": contentID]
        }
        return props
    }

    private static func renderPatternImage(
        width: Int, height: Int, seed: Int, withAlpha: Bool, colorSpaceName: String
    ) throws -> CGImage {
        let cs = CGColorSpace(name: colorSpaceName as CFString) ?? CGColorSpaceCreateDeviceRGB()
        let alpha: CGImageAlphaInfo = withAlpha ? .premultipliedLast : .noneSkipLast
        guard
            let ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: cs,
                bitmapInfo: alpha.rawValue
            )
        else {
            throw NSError(domain: "ImageFixtureFactory", code: 3)
        }

        if let buffer = ctx.data?.assumingMemoryBound(to: UInt8.self) {
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    let wave = ((x * 7 + y * 13 + seed * 41) & 0xFF)
                    buffer[i] = UInt8((x * 255 / max(1, width)) ^ (wave >> 2))
                    buffer[i + 1] = UInt8((y * 255 / max(1, height)) ^ (wave >> 1))
                    buffer[i + 2] = UInt8(((x ^ y) + seed * 29) & 0xFF)
                    buffer[i + 3] = withAlpha && x < width / 4 ? 128 : 255
                }
            }
        }
        guard let image = ctx.makeImage() else {
            throw NSError(domain: "ImageFixtureFactory", code: 4)
        }
        return image
    }

    private static func makeGainMapPayload(width: Int, height: Int) throws -> [String: Any] {
        var bytes = Data(count: width * height)
        bytes.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<(width * height) {
                base[i] = UInt8(i & 0xFF)
            }
        }
        let desc: [String: Any] = [
            kCGImagePropertyWidth as String: width,
            kCGImagePropertyHeight as String: height,
            kCGImagePropertyBytesPerRow as String: width,
            kCGImagePropertyPixelFormat as String: kCVPixelFormatType_OneComponent8,
        ]
        return [
            kCGImageAuxiliaryDataInfoData as String: bytes,
            kCGImageAuxiliaryDataInfoDataDescription as String: desc,
        ]
    }
}

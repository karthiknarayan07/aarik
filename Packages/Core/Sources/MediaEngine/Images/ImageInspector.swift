import AppCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Structural properties read from an image header without decoding full pixel buffers.
public struct ImageInspection: Sendable, Equatable, Hashable {
    /// Upright displayed pixel dimensions (after accounting for EXIF orientation).
    public let pixelSize: CGSize
    /// Raw EXIF/TIFF orientation (`1...8`, defaulting to `1`).
    public let orientation: Int
    public let sourceUTI: String
    public let colorSpaceName: String?
    public let bitDepth: Int
    public let hasAlpha: Bool
    public let isRAW: Bool
    public let frameCount: Int
    public let hasHDRGainMap: Bool
    public let hasDepthMatte: Bool
    public let captureDate: Date?

    public var isAnimated: Bool { frameCount > 1 }
    public var megapixels: Double { (pixelSize.width * pixelSize.height) / 1_000_000.0 }
}

/// Reads structural properties and a normalized `MetadataInventory` from any ImageIO-supported image file.
public struct ImageInspector: Sendable {
    public init() {}

    /// Reads header and auxiliary metadata without decoding pixels.
    public func inspect(url: URL) throws -> ImageInspection {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            throw ImageConversionError.unsupportedSource("Could not open \(url.lastPathComponent) as an image.")
        }
        guard let sourceUTI = CGImageSourceGetType(source) as String? else {
            throw ImageConversionError.unsupportedSource("Unknown image format for \(url.lastPathComponent).")
        }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else {
            throw ImageConversionError.unsupportedSource("Image file contains no frames.")
        }
        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
        let rawWidth = Self.doubleValue(props[kCGImagePropertyPixelWidth as String]) ?? 0
        let rawHeight = Self.doubleValue(props[kCGImagePropertyPixelHeight as String]) ?? 0
        let orientation =
            Self.intValue(props[kCGImagePropertyOrientation as String])
            ?? Self.intValue(
                (props[kCGImagePropertyTIFFDictionary as String] as? [String: Any])?[
                    kCGImagePropertyTIFFOrientation as String])
            ?? 1
        let swappedAxes = (5...8).contains(orientation)
        let pixelSize =
            swappedAxes ? CGSize(width: rawHeight, height: rawWidth) : CGSize(width: rawWidth, height: rawHeight)

        let hasAlpha = (props[kCGImagePropertyHasAlpha as String] as? Bool) ?? false
        let bitDepth = Self.intValue(props[kCGImagePropertyDepth as String]) ?? 8
        let colorProfile =
            props[kCGImagePropertyProfileName as String] as? String
            ?? props[kCGImagePropertyColorModel as String] as? String
        let uti = UTType(sourceUTI)
        let isRAW = uti?.conforms(to: .rawImage) ?? false

        let hasGainMap = Self.hasAuxiliaryData(
            source: source, index: 0,
            types: [
                kCGImageAuxiliaryDataTypeHDRGainMap as String,
                "urn:com:apple:photo:2020:aux:hdrgainmap",
                kCGImageAuxiliaryDataTypeISOGainMap as String,
            ])
        let hasDepth = Self.hasAuxiliaryData(
            source: source, index: 0,
            types: [
                kCGImageAuxiliaryDataTypeDisparity as String,
                kCGImageAuxiliaryDataTypeDepth as String,
                kCGImageAuxiliaryDataTypePortraitEffectsMatte as String,
            ])

        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let captureDate = Self.parseEXIFDate(
            exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String
                ?? tiff?[kCGImagePropertyTIFFDateTime as String] as? String,
            offset: exif?[kCGImagePropertyExifOffsetTimeOriginal as String] as? String
        )

        return ImageInspection(
            pixelSize: pixelSize,
            orientation: orientation,
            sourceUTI: sourceUTI,
            colorSpaceName: colorProfile,
            bitDepth: bitDepth,
            hasAlpha: hasAlpha,
            isRAW: isRAW,
            frameCount: frameCount,
            hasHDRGainMap: hasGainMap,
            hasDepthMatte: hasDepth,
            captureDate: captureDate
        )
    }

    /// Reads normalized metadata items + file attributes for LossCheck and post-conversion verification.
    public func inventory(of url: URL) throws -> MetadataInventory {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            throw ImageConversionError.unsupportedSource("Could not open \(url.lastPathComponent) as an image.")
        }
        let info = try inspect(url: url)
        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
        let xmp = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        var items = Self.extractItems(from: props, xmp: xmp, inspection: info)
        items += try FileAttributes.read(url)
        return MetadataInventory(items: items)
    }

    // MARK: - Private helpers

    private static func hasAuxiliaryData(source: CGImageSource, index: Int, types: [String]) -> Bool {
        for type in types {
            if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, type as CFString) != nil {
                return true
            }
        }
        return false
    }

    private static func extractItems(
        from props: [String: Any], xmp: CGImageMetadata?, inspection: ImageInspection
    ) -> [MetadataItem] {
        var items: [MetadataItem] = []

        func add(_ key: String, _ category: MetadataCategory, _ displayName: String, _ value: String?) {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            items.append(MetadataItem(key: key, category: category, displayName: displayName, value: value))
        }

        if let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            add("img.tiff.make", .camera, "Camera make", tiff[kCGImagePropertyTIFFMake as String] as? String)
            add("img.tiff.model", .camera, "Camera model", tiff[kCGImagePropertyTIFFModel as String] as? String)
            add("img.tiff.software", .camera, "Software", tiff[kCGImagePropertyTIFFSoftware as String] as? String)
            add("img.tiff.artist", .other, "Artist", tiff[kCGImagePropertyTIFFArtist as String] as? String)
            add("img.tiff.copyright", .other, "Copyright", tiff[kCGImagePropertyTIFFCopyright as String] as? String)
        }

        if let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            if let dateStr = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
                let offset = exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String ?? ""
                add("img.exif.dateOriginal", .date, "Capture date", dateStr + offset)
            }
            add("img.exif.lensMake", .camera, "Lens make", exif[kCGImagePropertyExifLensMake as String] as? String)
            add("img.exif.lensModel", .camera, "Lens model", exif[kCGImagePropertyExifLensModel as String] as? String)
            add(
                "img.exif.focalLength", .camera, "Focal length",
                formattedNumber(exif[kCGImagePropertyExifFocalLength as String]))
            add("img.exif.fNumber", .camera, "Aperture", formattedNumber(exif[kCGImagePropertyExifFNumber as String]))
            add(
                "img.exif.exposureTime", .camera, "Exposure time",
                formattedNumber(exif[kCGImagePropertyExifExposureTime as String], decimals: 4))
            if let isos = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Any], let first = isos.first {
                add("img.exif.iso", .camera, "ISO", "\(first)")
            }
            if let bodySerial = exif[kCGImagePropertyExifBodySerialNumber as String] as? String {
                add("img.exif.bodySerial", .camera, "Camera serial number", bodySerial)
            }
        }

        if let makerApple = props[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any] {
            if let rawContentID = makerApple["17"] as? String {
                let contentID = rawContentID.trimmingCharacters(
                    in: CharacterSet.controlCharacters.union(.whitespacesAndNewlines))
                add("img.apple.contentID", .image, "Live Photo identifier", contentID)
            }
            add("img.maker.apple", .camera, "Apple camera notes", "present")
        }

        if let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any] {
            if let coords = normalizedCoordinates(gps) {
                add("img.gps.location", .location, "Location", coords)
            }
            if let alt = doubleValue(gps[kCGImagePropertyGPSAltitude as String]) {
                let ref = intValue(gps[kCGImagePropertyGPSAltitudeRef as String]) ?? 0
                let signed = ref == 1 ? -alt : alt
                add("img.gps.altitude", .location, "Altitude", String(format: "%.1f m", signed))
            }
        }

        if let iptc = props[kCGImagePropertyIPTCDictionary as String] as? [String: Any] {
            add(
                "img.iptc.caption", .other, "Description",
                iptc[kCGImagePropertyIPTCCaptionAbstract as String] as? String)
            add(
                "img.iptc.copyright", .other, "Copyright notice",
                iptc[kCGImagePropertyIPTCCopyrightNotice as String] as? String)
            if let keywords = iptc[kCGImagePropertyIPTCKeywords as String] as? [String], !keywords.isEmpty {
                add("img.iptc.keywords", .other, "Keywords", keywords.sorted().joined(separator: ","))
            }
        }

        add("img.uti", .image, "File format", inspection.sourceUTI)
        if inspection.pixelSize.width > 0, inspection.pixelSize.height > 0 {
            add(
                "img.dimensions", .image, "Dimensions",
                "\(Int(inspection.pixelSize.width.rounded()))x\(Int(inspection.pixelSize.height.rounded()))")
        }
        add("img.colorProfile", .image, "Color profile", inspection.colorSpaceName)
        if inspection.hasAlpha {
            add("img.alpha", .image, "Transparency", "present")
        }
        if inspection.hasHDRGainMap {
            add("img.hdrGainMap", .hdr, "HDR Gain Map", "present")
        }
        if inspection.hasDepthMatte {
            add("img.depth", .image, "Portrait depth data", "present")
        }
        if inspection.isAnimated {
            add("img.animation", .image, "Animation frames", "\(inspection.frameCount)")
        }
        if inspection.isRAW {
            add("img.raw", .camera, "RAW sensor data", "present")
        }

        if let xmp, let tags = CGImageMetadataCopyTags(xmp) as? [CGImageMetadataTag], !tags.isEmpty {
            let names = tags.compactMap { tag -> String? in
                guard let ns = CGImageMetadataTagCopyNamespace(tag) as String?,
                    let name = CGImageMetadataTagCopyName(tag) as String?
                else { return nil }
                // Exclude dimension/orientation tags that change legitimately on resize/normalization.
                if name == "PixelXDimension" || name == "PixelYDimension"
                    || name == "ImageWidth" || name == "ImageLength" || name == "Orientation"
                {
                    return nil
                }
                return "\(ns):\(name)"
            }
            .sorted()
            if !names.isEmpty {
                add("img.xmp", .other, "XMP metadata", sha256Hex(Data(names.joined(separator: "\n").utf8)))
            }
        }

        return items
    }

    private static func normalizedCoordinates(_ gps: [String: Any]) -> String? {
        guard let lat = doubleValue(gps[kCGImagePropertyGPSLatitude as String]),
            let lon = doubleValue(gps[kCGImagePropertyGPSLongitude as String])
        else { return nil }
        let latRef = (gps[kCGImagePropertyGPSLatitudeRef as String] as? String) ?? "N"
        let lonRef = (gps[kCGImagePropertyGPSLongitudeRef as String] as? String) ?? "E"
        let signedLat = latRef.uppercased() == "S" ? -lat : lat
        let signedLon = lonRef.uppercased() == "W" ? -lon : lon
        return String(format: "%.4f,%.4f", signedLat, signedLon)
    }

    private static func formattedNumber(_ raw: Any?, decimals: Int = 2) -> String? {
        guard let value = doubleValue(raw) else { return nil }
        return String(format: "%.\(decimals)f", value)
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        if let n = raw as? Double { return n }
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String { return Double(s) }
        return nil
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let n = raw as? Int { return n }
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String { return Int(s) }
        return nil
    }

    private static func parseEXIFDate(_ string: String?, offset: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let offset, !offset.isEmpty {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
            if let date = formatter.date(from: string + offset) { return date }
        }
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter.date(from: string)
    }
}

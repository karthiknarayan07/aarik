import AppCore
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ImageConversionResult: Sendable, Equatable {
    public let output: URL
    public let pixelSize: CGSize
    public let byteSize: Int64
    public let outputFormat: ImageOutputFormat
}

/// Converts and resizes images offline using ImageIO and CoreImage, writing atomically via `AtomicOutput` and
/// preserving EXIF, TIFF, GPS, IPTC, XMP, ICC color profile, Gain Map HDR, Portrait Depth/Matte, and animations.
public struct ImageConverter: Sendable {
    public init() {}

    @concurrent
    public func convert(
        source: URL,
        to destination: URL,
        spec: ImageSpec,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> ImageConversionResult {
        try Task.checkCancellation()
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ImageConversionError.outputExists
        }

        await WorkSlots.downscales.acquire()
        defer { Task { await WorkSlots.downscales.release() } }
        try Task.checkCancellation()

        let partial = AtomicOutput.partialURL(for: destination)
        defer { try? FileManager.default.removeItem(at: partial) }

        let result = try encodeAtomically(
            source: source, partial: partial, destination: destination, spec: spec, progress: progress)
        try FileAttributes.copy(from: source, to: partial)
        try commit(partial: partial, to: destination)
        return result
    }

    // MARK: - Core encoding

    private func encodeAtomically(
        source: URL,
        partial: URL,
        destination: URL,
        spec: ImageSpec,
        progress: (@Sendable (Double) -> Void)?
    ) throws -> ImageConversionResult {
        progress?(0.05)
        let inspection = try ImageInspector().inspect(url: source)
        let resolvedFormat = spec.format.resolvedFormat(sourceUTI: inspection.sourceUTI)
        guard resolvedFormat.isEncodingSupported else {
            throw ImageConversionError.unsupportedSource("This device cannot encode \(resolvedFormat.title) images.")
        }

        let targetAnimation = inspection.isAnimated && resolvedFormat.supportsAnimation
        guard let destTypeID = resolvedFormat.destinationIdentifier(isAnimated: targetAnimation) else {
            throw ImageConversionError.unsupportedSource("Could not determine output image format.")
        }

        guard
            let imgSource = CGImageSourceCreateWithURL(
                source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else {
            throw ImageConversionError.unsupportedSource("Could not read \(source.lastPathComponent).")
        }

        let targetSize = spec.outputPixelSize(for: inspection.pixelSize)
        guard targetSize.width >= 1, targetSize.height >= 1 else {
            throw ImageConversionError.unsupportedSource("Image dimensions could not be read.")
        }

        progress?(0.2)

        if targetAnimation {
            try encodeAnimated(
                imgSource: imgSource,
                inspection: inspection,
                targetSize: targetSize,
                destTypeID: destTypeID,
                resolvedFormat: resolvedFormat,
                spec: spec,
                partial: partial,
                progress: progress
            )
            let bytes = try fileSize(partial)
            progress?(1.0)
            return ImageConversionResult(
                output: destination, pixelSize: targetSize, byteSize: bytes, outputFormat: resolvedFormat)
        }

        // Static image path (supports RAW/ProRAW, Gain Map HDR, Portrait Depth/Matte, Target File Size search).
        let baseFrame = try loadUprightImage(
            sourceURL: source, imgSource: imgSource, index: 0, inspection: inspection)
        let sourceProps = (CGImageSourceCopyPropertiesAtIndex(imgSource, 0, nil) as? [String: Any]) ?? [:]
        let sourceXMP = CGImageSourceCopyMetadataAtIndex(imgSource, 0, nil)

        let effectiveQuality = spec.isLossless ? 1.0 : spec.quality
        let auxiliaryPayloads =
            resolvedFormat.supportsGainMap || resolvedFormat.supportsDepthMatte
            ? readAuxiliaryPayloads(imgSource: imgSource, index: 0, format: resolvedFormat)
            : []

        let finalSize: CGSize
        let encodedData: Data
        if let cap = spec.targetByteSize, resolvedFormat.supportsLossyQuality, !spec.isLossless {
            let searched = try encodeFittingTargetSize(
                baseFrame: baseFrame,
                initialSize: targetSize,
                capBytes: cap,
                maxQuality: effectiveQuality,
                destTypeID: destTypeID,
                resolvedFormat: resolvedFormat,
                sourceProps: sourceProps,
                sourceXMP: sourceXMP,
                auxiliaryPayloads: auxiliaryPayloads,
                progress: progress
            )
            encodedData = searched.data
            finalSize = searched.size
        } else {
            let scaledFrame = try resizeImage(baseFrame, to: targetSize, preserveAlpha: resolvedFormat.supportsAlpha)
            progress?(0.6)
            encodedData = try encodeStaticData(
                image: scaledFrame,
                size: targetSize,
                destTypeID: destTypeID,
                resolvedFormat: resolvedFormat,
                quality: effectiveQuality,
                sourceProps: sourceProps,
                sourceXMP: sourceXMP,
                auxiliaryPayloads: auxiliaryPayloads
            )
            finalSize = targetSize
        }

        try encodedData.write(to: partial, options: .atomic)
        let bytes = Int64(encodedData.count)
        progress?(1.0)
        return ImageConversionResult(
            output: destination, pixelSize: finalSize, byteSize: bytes, outputFormat: resolvedFormat)
    }

    private func encodeFittingTargetSize(
        baseFrame: CGImage,
        initialSize: CGSize,
        capBytes: Int64,
        maxQuality: Double,
        destTypeID: String,
        resolvedFormat: ImageOutputFormat,
        sourceProps: [String: Any],
        sourceXMP: CGImageMetadata?,
        auxiliaryPayloads: [(type: CFString, info: [String: Any])],
        progress: (@Sendable (Double) -> Void)?
    ) throws -> (data: Data, size: CGSize) {
        let initialFrame = try resizeImage(baseFrame, to: initialSize, preserveAlpha: resolvedFormat.supportsAlpha)
        let initialData = try encodeStaticData(
            image: initialFrame,
            size: initialSize,
            destTypeID: destTypeID,
            resolvedFormat: resolvedFormat,
            quality: maxQuality,
            sourceProps: sourceProps,
            sourceXMP: sourceXMP,
            auxiliaryPayloads: auxiliaryPayloads
        )
        if Int64(initialData.count) <= capBytes {
            return (initialData, initialSize)
        }

        // Scale candidates: requested size first, then gentle step-downs only if minimum quality still exceeds cap.
        let scaleFactors: [Double] = [1.0, 0.85, 0.70, 0.50]
        var smallestAchieved = Int64(initialData.count)

        for (stepIndex, scale) in scaleFactors.enumerated() {
            try Task.checkCancellation()
            let candidateSize = CGSize(
                width: max(1, (initialSize.width * scale).rounded()),
                height: max(1, (initialSize.height * scale).rounded())
            )
            if scale < 1.0 && max(candidateSize.width, candidateSize.height) < 256 {
                break
            }
            let frame =
                scale == 1.0
                ? initialFrame
                : try resizeImage(baseFrame, to: candidateSize, preserveAlpha: resolvedFormat.supportsAlpha)

            // Check floor quality first to fail fast on a resolution step that can't fit.
            let minQuality = 0.08
            let floorData = try encodeStaticData(
                image: frame,
                size: candidateSize,
                destTypeID: destTypeID,
                resolvedFormat: resolvedFormat,
                quality: minQuality,
                sourceProps: sourceProps,
                sourceXMP: sourceXMP,
                auxiliaryPayloads: auxiliaryPayloads
            )
            smallestAchieved = min(smallestAchieved, Int64(floorData.count))
            if Int64(floorData.count) > capBytes {
                continue
            }

            var low = minQuality
            var high = maxQuality
            var best = floorData
            for _ in 0..<6 {
                try Task.checkCancellation()
                let mid = (low + high) / 2.0
                let trial = try encodeStaticData(
                    image: frame,
                    size: candidateSize,
                    destTypeID: destTypeID,
                    resolvedFormat: resolvedFormat,
                    quality: mid,
                    sourceProps: sourceProps,
                    sourceXMP: sourceXMP,
                    auxiliaryPayloads: auxiliaryPayloads
                )
                if Int64(trial.count) <= capBytes {
                    best = trial
                    low = mid
                } else {
                    high = mid
                }
            }
            progress?(0.6 + 0.3 * Double(stepIndex + 1) / Double(scaleFactors.count))
            return (best, candidateSize)
        }

        throw ImageConversionError.targetSizeUnreachable(minimumAchieved: smallestAchieved, target: capBytes)
    }

    private func encodeStaticData(
        image: CGImage,
        size: CGSize,
        destTypeID: String,
        resolvedFormat: ImageOutputFormat,
        quality: Double,
        sourceProps: [String: Any],
        sourceXMP: CGImageMetadata?,
        auxiliaryPayloads: [(type: CFString, info: [String: Any])]
    ) throws -> Data {
        let outData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(outData, destTypeID as CFString, 1, nil) else {
            throw ImageConversionError.encoderFailed(
                "Could not initialize image destination for \(resolvedFormat.title).")
        }

        let props = buildDestinationProperties(
            sourceProps: sourceProps,
            outputSize: size,
            resolvedFormat: resolvedFormat,
            quality: quality
        )

        if let sourceXMP {
            // Merge updated orientation & dimensions cleanly while carrying full XMP tags.
            let mutableXMP = CGImageMetadataCreateMutableCopy(sourceXMP)
            if let mutableXMP {
                CGImageMetadataSetValueMatchingImageProperty(
                    mutableXMP, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, 1 as CFNumber)
                CGImageDestinationAddImageAndMetadata(dest, image, mutableXMP, props as CFDictionary)
            } else {
                CGImageDestinationAddImage(dest, image, props as CFDictionary)
            }
        } else {
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
        }

        for payload in auxiliaryPayloads {
            let scaled = scaleAuxiliaryInfo(payload.info, toImageSize: size, type: payload.type)
            CGImageDestinationAddAuxiliaryDataInfo(dest, payload.type, scaled as CFDictionary)
        }

        guard CGImageDestinationFinalize(dest) else {
            throw ImageConversionError.encoderFailed("Image encoding failed for \(resolvedFormat.title).")
        }
        return outData as Data
    }

    private func encodeAnimated(
        imgSource: CGImageSource,
        inspection: ImageInspection,
        targetSize: CGSize,
        destTypeID: String,
        resolvedFormat: ImageOutputFormat,
        spec: ImageSpec,
        partial: URL,
        progress: (@Sendable (Double) -> Void)?
    ) throws {
        guard
            let dest = CGImageDestinationCreateWithURL(
                partial as CFURL, destTypeID as CFString, inspection.frameCount, nil)
        else {
            throw ImageConversionError.encoderFailed(
                "Could not initialize animated output for \(resolvedFormat.title).")
        }

        let containerProps = (CGImageSourceCopyProperties(imgSource, nil) as? [String: Any]) ?? [:]
        var cleanContainer: [String: Any] = [:]
        if let gifContainer = containerProps[kCGImagePropertyGIFDictionary as String] {
            cleanContainer[kCGImagePropertyGIFDictionary as String] = gifContainer
        }
        if let pngContainer = containerProps[kCGImagePropertyPNGDictionary as String] {
            cleanContainer[kCGImagePropertyPNGDictionary as String] = pngContainer
        }
        if !cleanContainer.isEmpty {
            CGImageDestinationSetProperties(dest, cleanContainer as CFDictionary)
        }

        let effectiveQuality = spec.isLossless ? 1.0 : spec.quality
        for index in 0..<inspection.frameCount {
            try Task.checkCancellation()
            let frame = try loadUprightImage(
                sourceURL: nil, imgSource: imgSource, index: index, inspection: inspection)
            let resized = try resizeImage(frame, to: targetSize, preserveAlpha: resolvedFormat.supportsAlpha)
            let frameProps = (CGImageSourceCopyPropertiesAtIndex(imgSource, index, nil) as? [String: Any]) ?? [:]
            let destProps = buildDestinationProperties(
                sourceProps: frameProps,
                outputSize: targetSize,
                resolvedFormat: resolvedFormat,
                quality: effectiveQuality
            )
            CGImageDestinationAddImage(dest, resized, destProps as CFDictionary)
            progress?(0.2 + 0.75 * Double(index + 1) / Double(max(1, inspection.frameCount)))
        }

        guard CGImageDestinationFinalize(dest) else {
            throw ImageConversionError.encoderFailed("Animated image encoding failed for \(resolvedFormat.title).")
        }
    }

    // MARK: - Image loading, RAW development, and scaling

    private func loadUprightImage(
        sourceURL: URL?, imgSource: CGImageSource, index: Int, inspection: ImageInspection
    ) throws -> CGImage {
        if index == 0, inspection.isRAW, let sourceURL, let rawFilter = CIRAWFilter(imageURL: sourceURL) {
            let context = CIContext(options: [
                .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) as Any,
                .cacheIntermediates: false,
            ])
            if let outputCI = rawFilter.outputImage {
                let targetCS = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
                if let cgImage = context.createCGImage(
                    outputCI, from: outputCI.extent, format: .RGBAh, colorSpace: targetCS)
                {
                    return cgImage
                }
            }
        }

        guard let cgImage = CGImageSourceCreateImageAtIndex(imgSource, index, nil) else {
            throw ImageConversionError.unsupportedSource("Could not decode image frame \(index).")
        }
        return try orientUpright(cgImage, orientation: inspection.orientation)
    }

    private func orientUpright(_ image: CGImage, orientation: Int) throws -> CGImage {
        guard orientation != 1 else { return image }
        let ciImage = CIImage(cgImage: image).oriented(forExifOrientation: Int32(orientation))
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let upright = context.createCGImage(ciImage, from: ciImage.extent, format: .RGBA8, colorSpace: colorSpace)
        else {
            throw ImageConversionError.encoderFailed("Could not apply image orientation.")
        }
        return upright
    }

    private func resizeImage(_ image: CGImage, to size: CGSize, preserveAlpha: Bool) throws -> CGImage {
        let width = Int(size.width)
        let height = Int(size.height)
        if image.width == width && image.height == height && (preserveAlpha || !hasAlpha(image)) {
            return image
        }

        let targetColorSpace = usableOutputColorSpace(from: image.colorSpace)
        let bitsPerComponent = image.bitsPerComponent > 8 ? 16 : 8
        let alphaInfo: CGImageAlphaInfo =
            preserveAlpha
            ? (hasAlpha(image) ? .premultipliedLast : .noneSkipLast)
            : .noneSkipLast
        let bitmapInfo = CGBitmapInfo(rawValue: alphaInfo.rawValue)
            .union(bitsPerComponent == 16 ? [.byteOrder16Little, .floatComponents] : [])

        var ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: 0,
            space: targetColorSpace,
            bitmapInfo: bitmapInfo.rawValue
        )
        if ctx == nil {
            ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: targetColorSpace,
                bitmapInfo: alphaInfo.rawValue
            )
        }
        guard let context = ctx else {
            throw ImageConversionError.encoderFailed("Could not create graphics context to resize image.")
        }

        context.interpolationQuality = .high
        if !preserveAlpha {
            // Paint clean white behind transparent regions if targeting an opaque format like JPEG.
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let output = context.makeImage() else {
            throw ImageConversionError.encoderFailed("Could not render resized image.")
        }
        return output
    }

    private func usableOutputColorSpace(from source: CGColorSpace?) -> CGColorSpace {
        if let source, source.model == .rgb {
            return source
        }
        return CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
    }

    private func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly: true
        case .none, .noneSkipFirst, .noneSkipLast: false
        @unknown default: false
        }
    }

    // MARK: - Metadata & auxiliary payloads

    private func buildDestinationProperties(
        sourceProps: [String: Any],
        outputSize: CGSize,
        resolvedFormat: ImageOutputFormat,
        quality: Double
    ) -> [String: Any] {
        var props = sourceProps
        // Normalize orientation to upright because pixels have been transformed upright.
        props[kCGImagePropertyOrientation as String] = 1
        props[kCGImagePropertyPixelWidth as String] = Int(outputSize.width)
        props[kCGImagePropertyPixelHeight as String] = Int(outputSize.height)
        props.removeValue(forKey: "RawDictionary")

        if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            props[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if var exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = Int(outputSize.width)
            exif[kCGImagePropertyExifPixelYDimension as String] = Int(outputSize.height)
            props[kCGImagePropertyExifDictionary as String] = exif
        }

        if resolvedFormat.supportsLossyQuality {
            props[kCGImageDestinationLossyCompressionQuality as String] = quality
        }
        if resolvedFormat.supportsGainMap {
            props[kCGImageDestinationPreserveGainMap as String] = true
        }
        return props
    }

    private func readAuxiliaryPayloads(
        imgSource: CGImageSource, index: Int, format: ImageOutputFormat
    ) -> [(type: CFString, info: [String: Any])] {
        var candidateTypes: [CFString] = []
        if format.supportsGainMap {
            candidateTypes.append(kCGImageAuxiliaryDataTypeHDRGainMap)
            candidateTypes.append(kCGImageAuxiliaryDataTypeISOGainMap)
        }
        if format.supportsDepthMatte {
            candidateTypes.append(kCGImageAuxiliaryDataTypeDisparity)
            candidateTypes.append(kCGImageAuxiliaryDataTypeDepth)
            candidateTypes.append(kCGImageAuxiliaryDataTypePortraitEffectsMatte)
        }

        var results: [(type: CFString, info: [String: Any])] = []
        for type in candidateTypes {
            if let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(imgSource, index, type) as? [String: Any] {
                results.append((type, info))
            }
        }
        return results
    }

    private func scaleAuxiliaryInfo(
        _ info: [String: Any], toImageSize size: CGSize, type: CFString
    ) -> [String: Any] {
        // Keep metadata/description intact; auxiliary maps remain aligned via ImageIO's metadata descriptions unless
        // dimensions exceed the resized main image, in which case proportionally resize description metadata.
        var updated = info
        guard let desc = info[kCGImageAuxiliaryDataInfoDataDescription as String] as? [String: Any],
            let rawW = (desc[kCGImagePropertyWidth as String] as? NSNumber)?.doubleValue,
            let rawH = (desc[kCGImagePropertyHeight as String] as? NSNumber)?.doubleValue,
            rawW > 0, rawH > 0,
            rawW > Double(size.width) || rawH > Double(size.height)
        else {
            return updated
        }

        // Preserve relative ratio of auxiliary map (for Gain Map / Depth).
        let factor = min(Double(size.width) / rawW, Double(size.height) / rawH)
        let newW = max(1, Int((rawW * factor).rounded()))
        let newH = max(1, Int((rawH * factor).rounded()))
        if let rawData = info[kCGImageAuxiliaryDataInfoData as String] as? Data {
            let ciContext = CIContext(options: [.cacheIntermediates: false])
            let bpr = (desc[kCGImagePropertyBytesPerRow as String] as? NSNumber)?.intValue ?? (Int(rawW) * 4)
            let pixelFormatNum = (desc[kCGImagePropertyPixelFormat as String] as? NSNumber)?.uint32Value ?? 0
            let ciFormat: CIFormat = pixelFormatNum == 0 ? .L8 : .RGBA8
            if rawData.count >= bpr * Int(rawH),
                let ciImage = Optional(
                    CIImage(
                        bitmapData: rawData, bytesPerRow: bpr, size: CGSize(width: rawW, height: rawH),
                        format: ciFormat, colorSpace: nil)),
                let resizedCI = Optional(
                    ciImage.transformed(by: CGAffineTransform(scaleX: Double(newW) / rawW, y: Double(newH) / rawH)))
            {
                let outBPR = newW * (ciFormat == .L8 ? 1 : 4)
                var buffer = Data(count: outBPR * newH)
                buffer.withUnsafeMutableBytes { ptr in
                    if let base = ptr.baseAddress {
                        ciContext.render(
                            resizedCI, toBitmap: base, rowBytes: outBPR,
                            bounds: CGRect(x: 0, y: 0, width: newW, height: newH),
                            format: ciFormat, colorSpace: nil)
                    }
                }
                var newDesc = desc
                newDesc[kCGImagePropertyWidth as String] = newW
                newDesc[kCGImagePropertyHeight as String] = newH
                newDesc[kCGImagePropertyBytesPerRow as String] = outBPR
                updated[kCGImageAuxiliaryDataInfoData as String] = buffer
                updated[kCGImageAuxiliaryDataInfoDataDescription as String] = newDesc
                return updated
            }
        }
        _ = type
        return updated
    }

    // MARK: - Atomics & file utilities

    private func commit(partial: URL, to destination: URL) throws {
        do {
            try AtomicOutput.commit(partial: partial, to: destination)
        } catch DownscaleError.outputExists {
            throw ImageConversionError.outputExists
        } catch let error as DownscaleError {
            throw ImageConversionError.encoderFailed(error.localizedDescription)
        }
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }
}

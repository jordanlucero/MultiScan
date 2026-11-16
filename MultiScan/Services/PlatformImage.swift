//
//  PlatformImage.swift
//  MultiScan
//
//  Cross-platform image decoding and encoding on CGImage/ImageIO — the one place that knows about EXIF orientation, HEIC/JPEG encoding, and thumbnail generation.
//  `nonisolated`: called from the main actor (thumbnails), `@concurrent` work (OCR, PDF rendering, the viewer decode), and `ProjectStore`.
//

import SwiftUI
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

nonisolated enum PlatformImage {

    // MARK: - SwiftUI Image (thumbnails)

    /// Create SwiftUI Image from raw image Data
    /// - Parameters:
    ///   - data: Image data in any system-supported format
    ///   - userRotation: User-applied rotation in degrees (0, 90, 180, 270). Default is 0.
    /// - Returns: A SwiftUI Image, or nil if the data couldn't be decoded
    static func from(data: Data, userRotation: Int = 0) -> Image? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        // Read EXIF orientation and combine with user rotation
        let exifOrientation = exifOrientation(from: source)
        let finalOrientation = combinedOrientation(exif: exifOrientation, userRotation: userRotation)
        return Image(decorative: cgImage, scale: 1.0, orientation: finalOrientation)
    }

    // MARK: - Orientation

    /// Combine EXIF orientation with user-applied rotation
    /// - Parameters:
    ///   - exif: The EXIF orientation from the image metadata
    ///   - userRotation: User rotation in degrees (0, 90, 180, 270)
    /// - Returns: The combined orientation
    static func combinedOrientation(exif: Image.Orientation, userRotation: Int) -> Image.Orientation {
        // Normalize rotation to 0, 1, 2, or 3 (representing 0°, 90°, 180°, 270°)
        let rotationSteps = ((userRotation % 360) + 360) % 360 / 90

        guard rotationSteps > 0 else { return exif }

        // Non-mirrored orientations rotate clockwise
        // Mirrored orientations rotate counter-clockwise (due to horizontal flip)
        let nonMirroredSequence: [Image.Orientation] = [.up, .right, .down, .left]
        let mirroredSequence: [Image.Orientation] = [.upMirrored, .leftMirrored, .downMirrored, .rightMirrored]

        let (sequence, currentIndex): ([Image.Orientation], Int) = switch exif {
        case .up: (nonMirroredSequence, 0)
        case .right: (nonMirroredSequence, 1)
        case .down: (nonMirroredSequence, 2)
        case .left: (nonMirroredSequence, 3)
        case .upMirrored: (mirroredSequence, 0)
        case .leftMirrored: (mirroredSequence, 1)
        case .downMirrored: (mirroredSequence, 2)
        case .rightMirrored: (mirroredSequence, 3)
        }

        let newIndex = (currentIndex + rotationSteps) % 4
        return sequence[newIndex]
    }

    /// Read EXIF orientation from image source and convert to SwiftUI Image.Orientation
    private static func exifOrientation(from source: CGImageSource) -> Image.Orientation {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exifOrientation = properties[kCGImagePropertyOrientation] as? UInt32 else {
            return .up
        }

        // EXIF orientation values map to SwiftUI Image.Orientation
        // https://developer.apple.com/documentation/imageio/kcgimagepropertyorientation
        switch exifOrientation {
        case 1: return .up
        case 2: return .upMirrored
        case 3: return .down
        case 4: return .downMirrored
        case 5: return .leftMirrored
        case 6: return .right
        case 7: return .rightMirrored
        case 8: return .left
        default: return .up
        }
    }

    /// Convert SwiftUI Image.Orientation to CGImagePropertyOrientation
    private static func cgImagePropertyOrientation(from orientation: Image.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: .up
        case .upMirrored: .upMirrored
        case .down: .down
        case .downMirrored: .downMirrored
        case .left: .left
        case .leftMirrored: .leftMirrored
        case .right: .right
        case .rightMirrored: .rightMirrored
        }
    }

    // MARK: - Processed CGImage for Platform Views

    /// Shared CIContext for image processing (thread-safe, reusable)
    private static let ciContext = CIContext()

    /// Create a processed CGImage with rotation and optional adjustments baked in.
    /// Unlike `from(data:userRotation:)` which returns a SwiftUI Image with orientation metadata,
    /// this produces a correctly-oriented CGImage suitable for UIImageView / NSImageView.
    /// - Parameters:
    ///   - data: Image data in any system-supported format
    ///   - userRotation: User-applied rotation in degrees (0, 90, 180, 270)
    ///   - increaseContrast: Whether to apply contrast boost (matches SwiftUI .contrast(1.3))
    ///   - increaseBlackPoint: Whether to apply brightness reduction (matches SwiftUI .brightness(-0.1))
    /// - Returns: A correctly-oriented, optionally adjusted CGImage, or nil if decoding fails
    ///   - crop: The region of the EXIF-upright image to show (normalized 0…1, upper-left origin), applied *before* `userRotation` — a page Smart Separate split off a two-page scan shows only its half (`Page.imageCrop`). `nil` shows the whole image.
    static func processedCGImage(
        from data: Data,
        crop: CGRect? = nil,
        userRotation: Int = 0,
        increaseContrast: Bool = false,
        increaseBlackPoint: Bool = false
    ) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        // Decode HDR content when present. SDR sources decode normally under this request, and the nil-options decode is a fallback for any decoder that rejects it.
        // Whether HDR actually *displays* is controlled at the view layer via preferredImageDynamicRange (see ZoomableImageView).
        let hdrOptions = [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary
        guard let rawCGImage = CGImageSourceCreateImageAtIndex(source, 0, hdrOptions)
                ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        // Get combined orientation (EXIF + user rotation)
        let exif = exifOrientation(from: source)
        let finalOrientation = combinedOrientation(exif: exif, userRotation: userRotation)

        // Fast path: no crop, no rotation needed, and no adjustments
        if crop == nil && finalOrientation == .up && !increaseContrast && !increaseBlackPoint {
            return rawCGImage
        }

        // Build CIImage pipeline: orientation (→ crop → user rotation) → optional adjustments → render
        var ciImage = CIImage(cgImage: rawCGImage)

        if let crop {
            // The crop is defined on the EXIF-upright image, so the two rotations can't be merged here: upright first, cut, then the user's rotation.
            ciImage = Self.normalizedToOrigin(ciImage.oriented(cgImagePropertyOrientation(from: exif)))
            let extent = ciImage.extent
            // Core Image's origin is lower-left; the stored crop's is upper-left.
            let region = CGRect(
                x: crop.minX * extent.width,
                y: (1 - crop.maxY) * extent.height,
                width: crop.width * extent.width,
                height: crop.height * extent.height
            ).integral.intersection(extent)
            if region.width >= 1, region.height >= 1 {
                ciImage = Self.normalizedToOrigin(ciImage.cropped(to: region))
            }
            let rotation = combinedOrientation(exif: .up, userRotation: userRotation)
            if rotation != .up {
                ciImage = Self.normalizedToOrigin(ciImage.oriented(cgImagePropertyOrientation(from: rotation)))
            }
        } else if finalOrientation != .up {
            ciImage = ciImage.oriented(cgImagePropertyOrientation(from: finalOrientation))
        }

        if increaseContrast || increaseBlackPoint {
            if let filter = CIFilter(name: "CIColorControls") {
                filter.setValue(ciImage, forKey: kCIInputImageKey)
                if increaseContrast {
                    filter.setValue(1.3, forKey: kCIInputContrastKey)
                }
                if increaseBlackPoint {
                    filter.setValue(-0.1, forKey: kCIInputBrightnessKey)
                }
                if let output = filter.outputImage {
                    ciImage = output
                }
            }
        }

        // More than 8 bits per component means the source decoded to HDR — render half-float into the source color space so the headroom survives the filter chain.
        if rawCGImage.bitsPerComponent > 8, let colorSpace = rawCGImage.colorSpace {
            return ciContext.createCGImage(ciImage, from: ciImage.extent, format: .RGBAh, colorSpace: colorSpace)
        }
        return ciContext.createCGImage(ciImage, from: ciImage.extent)
    }

    /// Convenience for a page's image source (bytes + crop).
    static func processedCGImage(
        from source: PageImageSource,
        userRotation: Int = 0,
        increaseContrast: Bool = false,
        increaseBlackPoint: Bool = false
    ) -> CGImage? {
        processedCGImage(
            from: source.data,
            crop: source.crop,
            userRotation: userRotation,
            increaseContrast: increaseContrast,
            increaseBlackPoint: increaseBlackPoint
        )
    }

    /// Moves a CIImage's extent to the origin, so a following crop/orientation works in plain 0…width coordinates.
    private static func normalizedToOrigin(_ image: CIImage) -> CIImage {
        let origin = image.extent.origin
        guard origin != .zero else { return image }
        return image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    }

    // MARK: - Geometry on decoded images

    /// Crops `image` to a normalized (0…1, upper-left origin) rectangle. `nil` when the region is degenerate.
    static func cropped(_ image: CGImage, to normalizedRect: CGRect) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        let rect = CGRect(
            x: normalizedRect.minX * size.width,
            y: normalizedRect.minY * size.height,
            width: normalizedRect.width * size.width,
            height: normalizedRect.height * size.height
        ).integral.intersection(CGRect(origin: .zero, size: size))
        guard rect.width > 8, rect.height > 8 else { return nil }
        return image.cropping(to: rect)
    }

    /// `image` turned clockwise by a page's user rotation (0, 90, 180, 270).
    static func rotated(_ image: CGImage, clockwise degrees: Int) -> CGImage? {
        let orientation = combinedOrientation(exif: .up, userRotation: degrees)
        return oriented(image, cgImagePropertyOrientation(from: orientation))
    }

    /// A copy of `image` with page regions marked on it, for showing where a scan was separated: everything outside `highlighted` is dimmed, and every region is outlined (the highlighted one in `accent`, the rest in white). Regions are normalized (0…1, upper-left origin) on `image` as given. An 8-bit sRGB rendering — a reference picture, not the viewer's image pipeline.
    static func markingRegions(_ regions: [CGRect], highlighted: CGRect?, accent: CGColor, on image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: bounds)

        // Core Graphics' origin is lower-left; the regions' is upper-left.
        func pixelRect(_ region: CGRect) -> CGRect {
            CGRect(
                x: region.minX * CGFloat(width),
                y: (1 - region.maxY) * CGFloat(height),
                width: region.width * CGFloat(width),
                height: region.height * CGFloat(height)
            )
        }

        if let highlighted {
            context.saveGState()
            context.addRect(bounds)
            context.addRect(pixelRect(highlighted))
            context.clip(using: .evenOdd)
            context.setFillColor(CGColor(gray: 0, alpha: 0.45))
            context.fill(bounds)
            context.restoreGState()
        }

        let lineWidth = max(CGFloat(max(width, height)) / 400, 2)
        context.setLineWidth(lineWidth)
        for region in regions where region != highlighted {
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            context.stroke(pixelRect(region).insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
        }
        if let highlighted {
            context.setStrokeColor(accent)
            context.stroke(pixelRect(highlighted).insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
        }
        return context.makeImage()
    }

    /// The decoded bitmap and its EXIF orientation, as the recognizers want them (they apply the orientation themselves).
    static func decodedImage(from data: Data) -> (image: CGImage, orientation: CGImagePropertyOrientation)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (image, cgImagePropertyOrientation(from: exifOrientation(from: source)))
    }

    /// The bitmap the recognizers read for a page: standard dynamic range, EXIF-upright, cut to the page's region of the scan, and turned by the user's rotation — i.e. the page as displayed, minus the display adjustments.
    static func recognitionImage(from source: PageImageSource, userRotation: Int) -> CGImage? {
        guard let decoded = decodedImage(from: source.data),
              var image = oriented(decoded.image, decoded.orientation) else { return nil }
        if let crop = source.crop, let region = cropped(image, to: crop) {
            image = region
        }
        return rotated(image, clockwise: userRotation) ?? image
    }

    // MARK: - Orientation baking

    /// Returns `image` with `orientation` applied to its pixels (so the result is `.up`). Returns the input unchanged for `.up`.
    /// Used by Smart Separate (crops must be taken in upright space) and when handing pages to transformer OCR engines.
    static func oriented(_ image: CGImage, _ orientation: CGImagePropertyOrientation) -> CGImage? {
        guard orientation != .up else { return image }
        let ciImage = CIImage(cgImage: image).oriented(orientation)
        return ciContext.createCGImage(ciImage, from: ciImage.extent)
    }

    // MARK: - Encoding

    /// Encodes a CGImage as `type` (HEIC or JPEG) at the given lossy quality.
    static func encode(_ image: CGImage, as type: UTType, quality: CGFloat) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Re-encodes image data as HEIC ("Optimize images on import" / "Optimize Images…"). Returns nil if the data can't be decoded or encoded.
    ///
    /// Re-encodes **from the image source**, not from a decoded bitmap, so the image's metadata comes along — above all its EXIF orientation. Encoding the bare `CGImage` drops the tag while leaving the pixels as stored, which turned every optimized phone photo sideways (and would misplace the crops of separated pages, which are defined on the upright image).
    static func heicReencoding(_ data: Data, quality: CGFloat = 0.8) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.heic.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImageFromSource(destination, source, 0, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// `heicReencoding(_:quality:)` on the cooperative pool, for main-actor callers.
    @concurrent
    static func heicReencodingInBackground(_ data: Data, quality: CGFloat = 0.8) async -> Data? {
        heicReencoding(data, quality: quality)
    }

    // MARK: - Thumbnails

    /// A downscaled, EXIF-corrected thumbnail of the source's first image.
    static func thumbnail(from source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Encoded, downscaled copy of an already-decoded (and already upright) image — the thumbnail of a region cut from a shared scan, which has no encoded file of its own to thumbnail.
    static func thumbnailData(of image: CGImage, maxPixelSize: Int, as type: UTType, quality: CGFloat) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImageDestinationImageMaxPixelSize: maxPixelSize
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Encoded thumbnail of `data`: HEIC at 400 px for page thumbnails, small JPEGs for the Spotlight index.
    static func thumbnailData(from data: Data?, maxPixelSize: Int, as type: UTType, quality: CGFloat) -> Data? {
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = thumbnail(from: source, maxPixelSize: maxPixelSize) else { return nil }
        return encode(thumbnail, as: type, quality: quality)
    }
}

//  Cross-platform image loading utilities

import SwiftUI
import CoreGraphics
import CoreImage
import ImageIO

/// Cross-platform image loading from Data to SwiftUI Image
/// Uses CGImage which is available on all Apple platforms
enum PlatformImage {
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

    /// Combine EXIF orientation with user-applied rotation
    /// - Parameters:
    ///   - exif: The EXIF orientation from the image metadata
    ///   - userRotation: User rotation in degrees (0, 90, 180, 270)
    /// - Returns: The combined orientation
    private static func combinedOrientation(exif: Image.Orientation, userRotation: Int) -> Image.Orientation {
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

    /// Get image dimensions from Data without fully decoding the image
    /// Accounts for EXIF orientation and user rotation (rotated images return their apparent dimensions)
    /// - Parameters:
    ///   - data: Image data
    ///   - userRotation: User-applied rotation in degrees (0, 90, 180, 270). Default is 0.
    /// - Returns: The image dimensions, or nil if they couldn't be determined
    static func dimensions(of data: Data, userRotation: Int = 0) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            return nil
        }

        // Count total 90° rotations from both EXIF and user
        var rotationCount = 0

        // EXIF orientations 5-8 include a 90° or 270° rotation
        if let orientation = properties[kCGImagePropertyOrientation] as? UInt32,
           orientation >= 5 && orientation <= 8 {
            rotationCount += 1
        }

        // Add user rotation (90° or 270° = odd number of 90° steps)
        let userSteps = ((userRotation % 360) + 360) % 360 / 90
        if userSteps == 1 || userSteps == 3 {
            rotationCount += 1
        }

        // If total rotations is odd, swap dimensions
        if rotationCount % 2 == 1 {
            return CGSize(width: height, height: width)
        }

        return CGSize(width: width, height: height)
    }

    /// Create a CGImage from Data for use with Vision framework or other CoreGraphics operations
    /// - Parameter data: Image data
    /// - Returns: A CGImage, or nil if the data couldn't be decoded
    static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
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
    static func processedCGImage(
        from data: Data,
        userRotation: Int = 0,
        increaseContrast: Bool = false,
        increaseBlackPoint: Bool = false
    ) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let rawCGImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        // Get combined orientation (EXIF + user rotation)
        let exif = exifOrientation(from: source)
        let finalOrientation = combinedOrientation(exif: exif, userRotation: userRotation)

        // Fast path: no rotation needed and no adjustments
        if finalOrientation == .up && !increaseContrast && !increaseBlackPoint {
            return rawCGImage
        }

        // Build CIImage pipeline: orientation → optional adjustments → render
        var ciImage = CIImage(cgImage: rawCGImage)

        if finalOrientation != .up {
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

        return ciContext.createCGImage(ciImage, from: ciImage.extent)
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
}

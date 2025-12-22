//
//  PlatformImage.swift
//  MultiScan
//
//  Cross-platform image loading utilities
//

import SwiftUI
import CoreGraphics
import ImageIO

/// Cross-platform image loading from Data to SwiftUI Image
/// Uses CGImage which is available on all Apple platforms
enum PlatformImage {
    /// Create SwiftUI Image from raw image Data
    /// - Parameter data: Image data in any supported format (JPEG, PNG, HEIC, etc.)
    /// - Returns: A SwiftUI Image, or nil if the data couldn't be decoded
    static func from(data: Data) -> Image? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        // Read EXIF orientation and convert to SwiftUI orientation
        let orientation = exifOrientation(from: source)
        return Image(decorative: cgImage, scale: 1.0, orientation: orientation)
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
    /// Accounts for EXIF orientation (rotated images return their apparent dimensions)
    /// - Parameter data: Image data
    /// - Returns: The image dimensions, or nil if they couldn't be determined
    static func dimensions(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            return nil
        }

        // Check if orientation requires swapping dimensions (90° or 270° rotation)
        if let orientation = properties[kCGImagePropertyOrientation] as? UInt32,
           orientation >= 5 && orientation <= 8 {
            // Orientations 5-8 are rotated 90° or 270°, so swap width/height
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
}

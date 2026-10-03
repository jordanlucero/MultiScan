//
//  PlatformImageTests.swift
//  MultiScanTests
//

import CoreGraphics
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import MultiScan

@Suite("Platform image")
struct PlatformImageTests {
    @Test func combinesEXIFOrientationWithUserRotation() {
        #expect(PlatformImage.combinedOrientation(exif: .up, userRotation: 0) == .up)
        #expect(PlatformImage.combinedOrientation(exif: .up, userRotation: 90) == .right)
        #expect(PlatformImage.combinedOrientation(exif: .up, userRotation: 180) == .down)
        #expect(PlatformImage.combinedOrientation(exif: .up, userRotation: 270) == .left)
        #expect(PlatformImage.combinedOrientation(exif: .up, userRotation: 360) == .up)
        #expect(PlatformImage.combinedOrientation(exif: .up, userRotation: -90) == .left)
        #expect(PlatformImage.combinedOrientation(exif: .right, userRotation: 90) == .down)
        #expect(PlatformImage.combinedOrientation(exif: .left, userRotation: 90) == .up)
        // Mirrored orientations rotate the other way around the flip
        #expect(PlatformImage.combinedOrientation(exif: .upMirrored, userRotation: 90) == .leftMirrored)
        #expect(PlatformImage.combinedOrientation(exif: .rightMirrored, userRotation: 90) == .upMirrored)
    }

    /// A solid 100×50 image.
    private func makeImage() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 100, height: 50, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
        return try #require(context.makeImage())
    }

    private func decode(_ data: Data) throws -> CGImage {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    @Test func encodesAndDecodesJPEG() throws {
        let jpeg = try #require(PlatformImage.encode(try makeImage(), as: .jpeg, quality: 0.8))
        let decoded = try decode(jpeg)
        #expect(decoded.width == 100)
        #expect(decoded.height == 50)
    }

    @Test func thumbnailsRespectMaxPixelSize() throws {
        let jpeg = try #require(PlatformImage.encode(try makeImage(), as: .jpeg, quality: 0.8))
        let thumbnail = try #require(PlatformImage.thumbnailData(from: jpeg, maxPixelSize: 20, as: .jpeg, quality: 0.5))
        let decoded = try decode(thumbnail)
        #expect(max(decoded.width, decoded.height) <= 20)
        #expect(PlatformImage.thumbnailData(from: nil, maxPixelSize: 20, as: .jpeg, quality: 0.5) == nil)
    }

    @Test func processedImageAppliesRotation() throws {
        let jpeg = try #require(PlatformImage.encode(try makeImage(), as: .jpeg, quality: 0.8))

        let upright = try #require(PlatformImage.processedCGImage(from: jpeg))
        #expect(upright.width == 100 && upright.height == 50)

        let rotated = try #require(PlatformImage.processedCGImage(from: jpeg, userRotation: 90))
        #expect(rotated.width == 50 && rotated.height == 100)

        let adjusted = try #require(PlatformImage.processedCGImage(from: jpeg, increaseContrast: true, increaseBlackPoint: true))
        #expect(adjusted.width == 100 && adjusted.height == 50)

        #expect(PlatformImage.processedCGImage(from: Data("not an image".utf8)) == nil)
        #expect(PlatformImage.from(data: jpeg) != nil)
    }
}

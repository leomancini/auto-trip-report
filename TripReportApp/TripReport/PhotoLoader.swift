import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PhotoLoader {
    static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "tiff", "tif"]

    /// Expand folders (recursively) and loose files into a sorted photo list.
    static func findPhotos(in roots: [URL]) -> [URL] {
        var found: [URL] = []
        let fm = FileManager.default
        for root in roots {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                if extensions.contains(root.pathExtension.lowercased()) { found.append(root) }
                continue
            }
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker where extensions.contains(url.pathExtension.lowercased()) {
                found.append(url)
            }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.path).inserted }.sorted { $0.path < $1.path }
    }

    /// sha256(first 1 MB + file size) — identical to analyze.py's file_key.
    static func fileKey(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 1 << 20),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        else { return nil }
        var hasher = SHA256()
        hasher.update(data: head)
        hasher.update(data: Data(String(size.int64Value).utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func thumbnail(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(src, maxPixel: maxPixel)
    }

    static func thumbnail(_ src: CGImageSource, maxPixel: Int) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func jpegData(_ image: CGImage, quality: Double = 0.85) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// The 1024px JPEG the vision model sees, base64-encoded.
    static func modelImage(_ url: URL) -> String? {
        guard let img = thumbnail(url, maxPixel: 1024), let data = jpegData(img) else { return nil }
        return data.base64EncodedString()
    }

    /// Read EXIF metadata and compute the perceptual hash for one file.
    static func load(_ url: URL, key: String) -> Photo? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumb = thumbnail(src, maxPixel: 256) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]

        let rawDate = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
            ?? tiff?[kCGImagePropertyTIFFDateTime] as? String

        var lat: Double?, lng: Double?
        if let la = gps?[kCGImagePropertyGPSLatitude] as? Double,
           let lo = gps?[kCGImagePropertyGPSLongitude] as? Double {
            lat = (gps?[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -la : la
            lng = (gps?[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lo : lo
            lat = (lat! * 1e6).rounded() / 1e6
            lng = (lng! * 1e6).rounded() / 1e6
        }
        let heading = (gps?[kCGImagePropertyGPSImgDirection] as? Double).map {
            ($0.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        }

        return Photo(
            id: key, path: url.path, name: url.lastPathComponent,
            datetime: rawDate.flatMap(NaiveTime.fromExif),
            lat: lat, lng: lng, heading: heading,
            phash: perceptualHash(thumb),
            aspect: Double(thumb.width) / Double(max(thumb.height, 1)))
    }

    // MARK: Perceptual hash (DCT pHash, 64 bits)

    private static let dctTable: [[Double]] = (0..<8).map { u in
        (0..<32).map { x in cos(Double(2 * x + 1) * Double(u) * .pi / 64) }
    }

    static func perceptualHash(_ image: CGImage) -> UInt64 {
        let n = 32
        var pixels = [UInt8](repeating: 0, count: n * n)
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                      bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return 0 }

        // separable 2D DCT, keeping only the 8x8 low-frequency corner
        var rows = [Double](repeating: 0, count: n * 8)
        for y in 0..<n {
            for v in 0..<8 {
                var sum = 0.0
                for x in 0..<n { sum += Double(pixels[y * n + x]) * dctTable[v][x] }
                rows[y * 8 + v] = sum
            }
        }
        var low = [Double](repeating: 0, count: 64)
        for u in 0..<8 {
            for v in 0..<8 {
                var sum = 0.0
                for y in 0..<n { sum += rows[y * 8 + v] * dctTable[u][y] }
                low[u * 8 + v] = sum
            }
        }
        let sorted = low.sorted()
        let median = (sorted[31] + sorted[32]) / 2
        var hash: UInt64 = 0
        for (i, value) in low.enumerated() where value > median { hash |= 1 << UInt64(i) }
        return hash
    }
}

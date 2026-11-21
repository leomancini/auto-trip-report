import AppKit
import ImageIO

/// Downsized JPEGs stored inside each project's folder, so a saved guide
/// still displays even if the original photos are moved or offline.
final class ThumbnailStore: @unchecked Sendable {
    static let shared = ThumbnailStore()

    private let memory: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 400 << 20
        return cache
    }()
    private let gate = AsyncSemaphore(4)

    static func size(for shot: ShotType) -> Int { shot == .primary ? 1600 : 800 }

    static func fileURL(projectDir: URL, id: String, maxPixel: Int) -> URL {
        projectDir.appendingPathComponent("thumbs/\(maxPixel)/\(id).jpg")
    }

    /// Create the thumbnail file if it isn't there yet.
    @discardableResult
    static func ensureFile(source: URL, dest: URL, maxPixel: Int) -> Bool {
        if FileManager.default.fileExists(atPath: dest.path) { return true }
        guard let image = PhotoLoader.thumbnail(source, maxPixel: maxPixel),
              let data = PhotoLoader.jpegData(image) else { return false }
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        return (try? data.write(to: dest, options: .atomic)) != nil
    }

    func image(photo: Photo, projectDir: URL, maxPixel: Int) async -> NSImage? {
        let key = "\(projectDir.lastPathComponent)/\(photo.id)/\(maxPixel)" as NSString
        if let hit = memory.object(forKey: key) { return hit }
        await gate.acquire()
        let image: NSImage? = await Task.detached(priority: .userInitiated) {
            if Task.isCancelled { return nil }
            let file = Self.fileURL(projectDir: projectDir, id: photo.id, maxPixel: maxPixel)
            guard Self.ensureFile(source: photo.url, dest: file, maxPixel: maxPixel),
                  let cg = PhotoLoader.thumbnail(file, maxPixel: maxPixel) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        await gate.release()
        if let image {
            memory.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height) * 4)
        }
        return image
    }
}

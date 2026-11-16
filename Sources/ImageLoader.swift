import AppKit
import ImageIO

/// Decodes photos off the main thread and caches them.
/// RAW files show their embedded JPEG preview first, which is near-instant;
/// the full RAW decode only happens when zooming to 100%.
final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()

    private let previews = NSCache<NSURL, CGImage>()
    private let fulls = NSCache<NSURL, CGImage>()
    private let thumbs = NSCache<NSURL, CGImage>()

    let previewPixels: Int

    private init() {
        previews.countLimit = 10
        fulls.countLimit = 3
        thumbs.countLimit = 3000
        let screen = NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }.max() ?? 3000
        previewPixels = max(2000, Int(screen))
    }

    /// True while the file is still an iCloud placeholder. Asks iCloud to fetch it.
    static func waitingOnCloud(_ url: URL) -> Bool {
        let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
            .ubiquitousItemDownloadingStatus
        guard status == .notDownloaded else { return false }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        return true
    }

    func cachedPreview(_ url: URL) -> CGImage? { previews.object(forKey: url as NSURL) }

    func preview(_ url: URL) async -> CGImage? {
        if let hit = previews.object(forKey: url as NSURL) { return hit }
        let px = previewPixels
        let img = await Task.detached(priority: .userInitiated) {
            Self.decode(url, maxPixel: px, minAcceptable: 1400, forceFull: false)
        }.value
        if let img { previews.setObject(img, forKey: url as NSURL) }
        return img
    }

    func prefetch(_ url: URL) {
        guard previews.object(forKey: url as NSURL) == nil else { return }
        Task { _ = await preview(url) }
    }

    func full(_ url: URL) async -> CGImage? {
        if let hit = fulls.object(forKey: url as NSURL) { return hit }
        let img = await Task.detached(priority: .userInitiated) {
            Self.decode(url, maxPixel: 30000, minAcceptable: 0, forceFull: true)
        }.value
        if let img { fulls.setObject(img, forKey: url as NSURL) }
        return img
    }

    func thumb(_ url: URL) async -> CGImage? {
        if let hit = thumbs.object(forKey: url as NSURL) { return hit }
        let img = await Task.detached(priority: .utility) {
            Self.decode(url, maxPixel: 240, minAcceptable: 120, forceFull: false)
        }.value
        if let img { thumbs.setObject(img, forKey: url as NSURL) }
        return img
    }

    static func decode(_ url: URL, maxPixel: Int, minAcceptable: Int, forceFull: Bool) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if !forceFull {
            // Use the embedded preview if it is big enough to look sharp.
            opts[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
            if let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
               max(img.width, img.height) >= min(minAcceptable, maxPixel) {
                return img
            }
            opts[kCGImageSourceCreateThumbnailFromImageIfAbsent] = nil
        }
        opts[kCGImageSourceCreateThumbnailFromImageAlways] = true
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Full pixel size as displayed (rotation applied).
    static func pixelSize(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double,
              let h = props[kCGImagePropertyPixelHeight] as? Double
        else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// Exposure details, e.g. "1/250 s · ƒ/5.6 · ISO 200 · 40 mm".
    static func shotInfo(_ url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        else { return nil }
        func tidy(_ x: Double) -> String { String(format: "%g", (x * 10).rounded() / 10) }
        var parts: [String] = []
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double, t > 0 {
            parts.append(t >= 0.4 ? "\(tidy(t)) s" : "1/\(Int((1 / t).rounded())) s")
        }
        if let f = exif[kCGImagePropertyExifFNumber] as? Double, f > 0 { parts.append("ƒ/" + tidy(f)) }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Any])?.first as? NSNumber {
            parts.append("ISO \(iso.intValue)")
        }
        if let fl = exif[kCGImagePropertyExifFocalLength] as? Double, fl > 0 { parts.append("\(Int(fl.rounded())) mm") }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String, !lens.isEmpty { parts.append(lens) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    /// When the shutter fired, from the photo's own metadata.
    /// File dates are not used: files copied together all share one date.
    static func captureDate(_ url: URL) -> Date? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        guard let text = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
                ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
                ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard var date = f.date(from: text) else { return nil }
        if let sub = exif?[kCGImagePropertyExifSubsecTimeOriginal] as? String, let frac = Double("0." + sub) {
            date.addTimeInterval(frac)
        }
        return date
    }
}

import Foundation
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

struct ShareItem {
    enum Source { case photo(PHAssetResource, PHAsset), file(URL) }
    let name: String
    let mime: String
    let size: Int64
    let source: Source
}

// What this iPhone makes available: the photo library (after one permission) and
// folders the owner picked once in the Files app (saved as bookmarks).
final class ShareLibrary {
    private let bookmarksKey = "folderBookmarks"
    private var activeFolders: [URL] = []

    var folderCount: Int { (UserDefaults.standard.array(forKey: bookmarksKey) as? [Data])?.count ?? 0 }

    func requestPhotos() async -> PHAuthorizationStatus {
        await withCheckedContinuation { cont in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { cont.resume(returning: $0) }
        }
    }

    var photosStatus: PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }

    func addFolder(_ url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData()
        var all = (UserDefaults.standard.array(forKey: bookmarksKey) as? [Data]) ?? []
        all.append(data)
        UserDefaults.standard.set(all, forKey: bookmarksKey)
    }

    func removeFolders() {
        UserDefaults.standard.removeObject(forKey: bookmarksKey)
        activeFolders.forEach { $0.stopAccessingSecurityScopedResource() }
        activeFolders = []
    }

    func listItems() async -> [ShareItem] {
        buildItems()
    }

    private func buildItems() -> [ShareItem] {
        var out: [ShareItem] = []
        let status = photosStatus
        if status == .authorized || status == .limited {
            let opts = PHFetchOptions()
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            opts.fetchLimit = 500
            PHAsset.fetchAssets(with: opts).enumerateObjects { asset, _, _ in
                let res = PHAssetResource.assetResources(for: asset)
                guard let r = res.first(where: { $0.type == .photo || $0.type == .video }) ?? res.first else { return }
                let size = (r.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
                let mime = UTType(r.uniformTypeIdentifier)?.preferredMIMEType ?? "application/octet-stream"
                out.append(ShareItem(name: r.originalFilename, mime: mime, size: size, source: .photo(r, asset)))
            }
        }
        for bookmark in (UserDefaults.standard.array(forKey: bookmarksKey) as? [Data]) ?? [] {
            var stale = false
            guard let folder = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else { continue }
            if !activeFolders.contains(folder) {
                if folder.startAccessingSecurityScopedResource() { activeFolders.append(folder) }
            }
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
            guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { continue }
            while let next = walker.nextObject() as? URL {
                guard let v = try? next.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                let mime = UTType(filenameExtension: next.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                out.append(ShareItem(name: next.lastPathComponent, mime: mime, size: Int64(v.fileSize ?? 0), source: .file(next)))
                if out.count > 3000 { return out }
            }
        }
        return out
    }

    // Small JPEG preview (about 300 px) so the remote device can show a gallery
    func thumbnail(for item: ShareItem) async -> Data? {
        switch item.source {
        case .photo(_, let asset):
            return await withCheckedContinuation { cont in
                let opts = PHImageRequestOptions()
                opts.deliveryMode = .highQualityFormat
                opts.resizeMode = .exact
                opts.isNetworkAccessAllowed = true
                opts.isSynchronous = false
                var done = false
                PHImageManager.default().requestImage(
                    for: asset, targetSize: CGSize(width: 300, height: 300),
                    contentMode: .aspectFill, options: opts
                ) { image, info in
                    if done { return }
                    if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                    done = true
                    cont.resume(returning: image?.jpegData(compressionQuality: 0.6))
                }
            }
        case .file(let url):
            guard item.mime.hasPrefix("image/"),
                  let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 300
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return UIImage(cgImage: cg).jpegData(compressionQuality: 0.6)
        }
    }

    // Returns a readable file URL, and whether it is a temporary copy to delete afterwards
    func exportToTemp(_ item: ShareItem) async throws -> (URL, Bool) {
        switch item.source {
        case .file(let url):
            return (url, false)
        case .photo(let resource, _):
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "-" + resource.originalFilename)
            let opts = PHAssetResourceRequestOptions()
            opts.isNetworkAccessAllowed = true
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(for: resource, toFile: tmp, options: opts) { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                }
            }
            return (tmp, true)
        }
    }
}

import AppKit
import Foundation

struct SlideImagePathEntry {
    let rawPath: String
    let resolvedURL: URL?
    let scaleFactor: CGFloat

    var displayName: String {
        if let resolvedURL {
            return resolvedURL.lastPathComponent
        }
        let candidate = (rawPath as NSString).lastPathComponent
        return candidate.isEmpty ? rawPath : candidate
    }
}

enum SlideImagePathResolver {
    static func resolveEntries(from lines: [String], deckDirectoryPath: String?) -> [SlideImagePathEntry] {
        let deckDirectoryURL = deckDirectoryPath.flatMap { path -> URL? in
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return nil
            }
            return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
        }

        return lines.compactMap { line in
            let normalizedPath = normalizePath(line)
            guard !normalizedPath.isEmpty else {
                return nil
            }

            let parsedScale = splitScaleSuffix(from: normalizedPath)
            guard !parsedScale.path.isEmpty else {
                return nil
            }

            return SlideImagePathEntry(
                rawPath: parsedScale.path,
                resolvedURL: resolvedFileURL(for: parsedScale.path, relativeTo: deckDirectoryURL),
                scaleFactor: parsedScale.scaleFactor
            )
        }
    }

    private static func normalizePath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            return trimmed
        }
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) ||
            (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func splitScaleSuffix(from path: String) -> (path: String, scaleFactor: CGFloat) {
        guard path.hasSuffix("%"), let suffixStart = path.lastIndex(of: ":") else {
            return (path, 1.0)
        }
        let numberStart = path.index(after: suffixStart)
        let numberEnd = path.index(before: path.endIndex)
        guard numberStart < numberEnd else {
            return (path, 1.0)
        }

        let numberText = path[numberStart..<numberEnd].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let percentage = Double(numberText), percentage > 0 else {
            return (path, 1.0)
        }

        let strippedPath = String(path[..<suffixStart]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !strippedPath.isEmpty else {
            return (path, 1.0)
        }

        let scale = CGFloat(percentage / 100.0)
        return (strippedPath, min(max(scale, 0.05), 3.0))
    }

    private static func resolvedFileURL(for rawPath: String, relativeTo deckDirectoryURL: URL?) -> URL? {
        if let parsedURL = URL(string: rawPath), parsedURL.isFileURL {
            return parsedURL.standardizedFileURL
        }

        if rawPath.hasPrefix("~") {
            let expanded = (rawPath as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }

        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: rawPath).standardizedFileURL
        }

        if let deckDirectoryURL {
            return URL(fileURLWithPath: rawPath, relativeTo: deckDirectoryURL).standardizedFileURL
        }

        let currentDirectoryURL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        return URL(fileURLWithPath: rawPath, relativeTo: currentDirectoryURL).standardizedFileURL
    }
}

final class SlideImageLoader: @unchecked Sendable {
    static let shared = SlideImageLoader()

    private let cache = NSCache<NSString, NSImage>()
    private let lock = NSLock()

    private init() {}

    func image(for entry: SlideImagePathEntry) -> NSImage? {
        guard let url = entry.resolvedURL else {
            return nil
        }
        let key = url.path as NSString

        lock.lock()
        if let cached = cache.object(forKey: key) {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let loaded = NSImage(contentsOf: url) else {
            return nil
        }

        lock.lock()
        cache.setObject(loaded, forKey: key)
        lock.unlock()
        return loaded
    }
}

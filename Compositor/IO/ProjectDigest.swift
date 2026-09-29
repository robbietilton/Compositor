import CryptoKit
import Foundation

/// A fingerprint of what a project package contains: the manifest byte for byte, and each asset's name and size. A
/// package that was only touched (a sync client rewriting metadata, a permission change, the same bytes saved again)
/// has the same digest as before, so it is not treated as a change.
///
/// Assets are not read: every save and open takes a fresh digest, and hashing every image of a large project would
/// hold each save for seconds. Anything that edits a project rewrites its manifest, and a PNG whose pixels change
/// all but always changes size, so names and sizes catch the rest from the file system alone.
nonisolated struct ProjectDigest: Equatable, Sendable {
    let value: Data

    /// Reads the package outside file coordination on purpose: it is called after a change was already seen and
    /// it must never wait on a writer. A package caught half written yields a digest that matches nothing, or an
    /// error; both make the caller wait for the next change.
    static func compute(for url: URL) throws -> ProjectDigest {
        var hasher = SHA256()
        let manifest = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
        hasher.update(data: manifest)
        let images = url.appendingPathComponent("images", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: images.path)) ?? []).sorted()
        for name in names {
            let values = try images.appendingPathComponent(name).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            hasher.update(data: Data(name.utf8))
            let count = UInt64(values.fileSize ?? 0)
            withUnsafeBytes(of: count) { hasher.update(bufferPointer: $0) }
        }
        return ProjectDigest(value: Data(hasher.finalize()))
    }
}

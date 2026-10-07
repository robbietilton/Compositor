import Foundation

/// The folders exports write their files to, for the share sheet to offer, in the app's temporary folder: one for each
/// file, so that exports from several windows, of projects of the same name, never write over one another's file, nor
/// one finishing late over a file still offered. A folder goes once its file's share sheet is done, as the next export
/// writes its own; any left from before go then too.
enum ExportFolders {
    /// Where the folders are.
    static let root = FileManager.default.temporaryDirectory.appending(path: "Exports", directoryHint: .isDirectory)
    /// The folders whose files a share sheet still offers.
    private static var offered: Set<String> = []

    /// `data` as a file named `name`, in a folder of its own, which is offered from then on. The folders whose files are
    /// no longer offered are taken away first.
    static func write(_ data: Data, named name: String) throws -> URL {
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
        for old in folders where !offered.contains(old) { try? FileManager.default.removeItem(at: root.appending(path: old)) }
        let folder = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try Timing.measure("Write export", Timing.bytes(data.count)) { try data.write(to: url, options: .atomic) }
        offered.insert(folder.lastPathComponent)
        return url
    }

    /// `file` is no longer offered: its folder goes as the next export writes its file.
    static func release(_ file: URL) {
        offered.remove(file.deletingLastPathComponent().lastPathComponent)
    }
}

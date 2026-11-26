import AppKit
import AVFoundation
import Testing
@testable import Compositor

@MainActor
struct MovieFrameTests {
    private final class BundleToken {}

    @Test func linkedMovieRoundTripsWithItsStill() async throws {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "frame-picker-portrait", withExtension: "mov"))
        let session = EditorSession()
        await session.importImages([url])
        let original = try #require(session.activeLayer)
        let link = try #require(original.movie)
        let snapshot = try #require(session.projectSnapshot())
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".comp")
        defer { try? FileManager.default.removeItem(at: file) }
        try await ProjectStore.shared.save(snapshot, to: file)
        let reopened = try await ProjectStore.shared.load(from: file)
        let restored = try #require(reopened.documentLayers.first)
        #expect(restored.movie == link)
        #expect(restored.asset?.image.width == 48)
    }

    /// A two-second movie, red then blue at two frames per second, with a portrait rotation tag.
    @Test func capturesTheSelectedFrameUprightIncludingAtTheEnd() async throws {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "frame-picker-portrait", withExtension: "mov"))
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try #require(tracks.first)
        let range = try await track.load(.timeRange)
        for (seconds, red) in [(0.99, true), (1.0, false), (2.0, false)] {
            let time = CMTime(seconds: seconds, preferredTimescale: 60000)
            let frame = try await MovieFramePicker.frame(in: asset, at: time, range: range,
                                                        name: "Portrait", remainingPixels: 80 * 48)
            #expect(frame.image.width == 48 && frame.image.height == 80)
            let pixel = try #require(NSBitmapImageRep(cgImage: frame.image).colorAt(x: 10, y: 10)?.usingColorSpace(.sRGB))
            #expect((pixel.redComponent > pixel.blueComponent) == red)
        }
    }
}

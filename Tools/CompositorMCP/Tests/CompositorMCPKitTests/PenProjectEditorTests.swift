import Foundation
import ImageIO
import XCTest
@testable import CompositorMCPKit

final class PenProjectEditorTests: XCTestCase {
    private var projectURL: URL!

    override func setUpWithError() throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompositorMCP-\(UUID()).comp", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL.appendingPathComponent("images"),
                                                withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "format": "com.compositor.project",
            "version": 14,
            "colorSpace": "sRGB",
            "documentID": UUID().uuidString,
            "width": 640,
            "height": 480,
            "resolution": 72,
            "activeLayerID": NSNull(),
            "layers": []
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: projectURL.appendingPathComponent("manifest.json"))
    }

    override func tearDownWithError() throws {
        if projectURL != nil { try? FileManager.default.removeItem(at: projectURL) }
    }

    func testCreateUpdateSampleListAndDeleteRoundTrip() throws {
        let editor = PenProjectEditor()
        let line = try editor.createPath(in: projectURL, request: CreatePenPathRequest(
            name: "AI Curve",
            mode: .line,
            color: PenColor(red: 0.2, green: 0.4, blue: 0.8),
            lineWidth: 12,
            nodes: [
                PenPathNode(anchor: PenPoint(x: 20, y: 40)),
                PenPathNode(anchor: PenPoint(x: 220, y: 40),
                            inHandle: PenPoint(x: 150, y: 120), outHandle: PenPoint(x: 220, y: 40))
            ]
        ))
        XCTAssertEqual(line.name, "AI Curve")
        XCTAssertEqual(line.mode, .line)
        XCTAssertEqual(line.nodes.first?.anchor, PenPoint(x: 20, y: 40))
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            projectURL.appendingPathComponent("images/\(line.id.uuidString).png").path))
        let imageData = try Data(contentsOf: projectURL.appendingPathComponent("images/\(line.id.uuidString).png"))
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(imageData as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                                              bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                                CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertTrue(stride(from: 3, to: context.bytesPerRow * image.height, by: 4)
            .allSatisfy { pixels[$0] == 0 })
        XCTAssertEqual(try editor.listPaths(in: projectURL), [line])

        let shapeNodes = [
            PenPathNode(anchor: PenPoint(x: 50, y: 60)),
            PenPathNode(anchor: PenPoint(x: 260, y: 80)),
            PenPathNode(anchor: PenPoint(x: 160, y: 220))
        ]
        let shape = try editor.updatePath(in: projectURL, id: line.id,
                                          request: UpdatePenPathRequest(name: "Triangle", mode: .shape,
                                                                        nodes: shapeNodes, isVisible: false))
        XCTAssertEqual(shape.mode, .shape)
        XCTAssertTrue(shape.closed)
        XCTAssertFalse(shape.isVisible)
        XCTAssertEqual(shape.nodes, shapeNodes)

        let samples = try editor.samples(for: shape, at: [0, 0.5, 1])
        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(samples[0].position.x, samples[2].position.x, accuracy: 0.01)
        XCTAssertEqual(samples[0].position.y, samples[2].position.y, accuracy: 0.01)

        try editor.deletePath(in: projectURL, id: line.id)
        XCTAssertTrue(try editor.listPaths(in: projectURL).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            projectURL.appendingPathComponent("images/\(line.id.uuidString).png").path))
    }

    func testMCPAdvertisesAndCreatesPenPath() throws {
        let server = MCPServer()
        let initialized = try XCTUnwrap(server.handle([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18"]
        ]))
        let initializedResult = try XCTUnwrap(initialized["result"] as? [String: Any])
        XCTAssertEqual(initializedResult["protocolVersion"] as? String, "2025-06-18")

        let listed = try XCTUnwrap(server.handle([
            "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:]
        ]))
        let listResult = try XCTUnwrap(listed["result"] as? [String: Any])
        XCTAssertEqual((listResult["tools"] as? [[String: Any]])?.count, 5)

        let created = try XCTUnwrap(server.handle([
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": [
                "name": "compositor_create_pen_path",
                "arguments": [
                    "project_path": projectURL.path,
                    "mode": "Line",
                    "line_width": 6,
                    "nodes": [
                        ["anchor": ["x": 10, "y": 20]],
                        ["anchor": ["x": 200, "y": 120], "in_handle": ["x": 120, "y": 30]]
                    ]
                ]
            ]
        ]))
        let callResult = try XCTUnwrap(created["result"] as? [String: Any])
        XCTAssertEqual(callResult["isError"] as? Bool, false)
        XCTAssertEqual(try PenProjectEditor().listPaths(in: projectURL).count, 1)
    }

    func testRejectsInvalidPathWithoutChangingProject() throws {
        let editor = PenProjectEditor()
        XCTAssertThrowsError(try editor.createPath(in: projectURL, request: CreatePenPathRequest(
            mode: .shape,
            color: PenColor(red: 0, green: 0, blue: 0),
            nodes: [PenPathNode(anchor: PenPoint(x: 1, y: 1)), PenPathNode(anchor: PenPoint(x: 2, y: 2))]
        )))
        XCTAssertTrue(try editor.listPaths(in: projectURL).isEmpty)
    }

    func testRenamingKeepsAPaintedPathAndShapeEditsAreRefused() throws {
        let editor = PenProjectEditor()
        let line = try editor.createPath(in: projectURL, request: CreatePenPathRequest(
            mode: .line,
            color: PenColor(red: 0, green: 0, blue: 0),
            nodes: [PenPathNode(anchor: PenPoint(x: 10, y: 10)), PenPathNode(anchor: PenPoint(x: 100, y: 40))]
        ))
        let manifestURL = projectURL.appendingPathComponent("manifest.json")
        func manifest() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        }
        var written = try manifest()
        XCTAssertEqual((written["version"] as? NSNumber)?.intValue, PenProjectEditor.currentProjectVersion)
        var layers = try XCTUnwrap(written["layers"] as? [[String: Any]])
        var style = try XCTUnwrap(layers[0]["vectorPath"] as? [String: Any])
        style["brushStroke"] = ["red": 0, "green": 0, "blue": 0, "diameter": 8, "hardness": 1, "opacity": 1]
        layers[0]["vectorPath"] = style
        written["layers"] = layers
        try JSONSerialization.data(withJSONObject: written).write(to: manifestURL)

        let renamed = try editor.updatePath(in: projectURL, id: line.id, request: UpdatePenPathRequest(name: "Renamed"))
        XCTAssertEqual(renamed.name, "Renamed")
        let kept = try XCTUnwrap((try manifest()["layers"] as? [[String: Any]])?.first?["vectorPath"] as? [String: Any])
        XCTAssertNotNil(kept["brushStroke"])
        XCTAssertThrowsError(try editor.updatePath(in: projectURL, id: line.id,
                                                   request: UpdatePenPathRequest(lineWidth: 20)))
    }
}

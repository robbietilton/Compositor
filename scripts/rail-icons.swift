// Draws the Mac rail's own icons, the ones SF Symbols has nothing to match, into the iPad rail's assets in
// CompositorPad/RailIcons.xcassets: vector PDFs, each the size that looks as large as the symbols beside it, which the
// rail shows as they are. Run it again when one of them changes:
//
//     swiftc -parse-as-library -o /tmp/rail-icons scripts/rail-icons.swift Compositor/UI/ToolIcons.swift && /tmp/rail-icons
import SwiftUI

@main enum RailIcons {
    enum Icon { case cloneStamp, gradient, polygonalLasso, objectSelection }

    /// Each icon's name in the catalog, and its size in points: a little larger than the Mac's 18, as the rail's
    /// symbols are, and more for the stamp and the gradient, which look small at that size beside them.
    static let icons: [(name: String, icon: Icon, side: CGFloat)] = [
        ("cloneStamp", .cloneStamp, 25.2),
        ("gradient", .gradient, 23.76),
        ("lasso.polygonal", .polygonalLasso, 20),
        ("wand.object", .objectSelection, 22),
    ]

    @MainActor static func main() throws {
        let catalog = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "CompositorPad/RailIcons.xcassets")
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        try json(["info": ["author": "xcode", "version": 1]]).write(to: catalog.appending(path: "Contents.json"))
        for (name, icon, side) in icons {
            let set = catalog.appending(path: "rail.\(name).imageset")
            try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
            try pdf(view(icon), side: side).write(to: set.appending(path: "\(name).pdf"))
            try json([
                "images": [["filename": "\(name).pdf", "idiom": "universal"]],
                "info": ["author": "xcode", "version": 1],
                // Drawn from the vectors at any scale, and tinted as the rail's symbols are.
                "properties": ["preserves-vector-representation": true, "template-rendering-intent": "template"],
            ]).write(to: set.appending(path: "Contents.json"))
        }
        print("Wrote \(icons.count) icons to \(catalog.path)")
    }

    /// The icon, drawn as the Mac's rail draws it.
    @MainActor static func view(_ icon: Icon) -> some View {
        Canvas { context, size in
            switch icon {
            case .cloneStamp:
                context.fill(ToolIcons.cloneStamp(in: size), with: .foreground)
            case .gradient:
                let shape = ToolIcons.gradientFrame(in: size)
                context.clip(to: shape)
                context.fill(ToolIcons.gradientDots(in: size), with: .foreground)
                context.stroke(shape, with: .foreground, lineWidth: ToolIcons.gradientFrameWidth)
            case .polygonalLasso:
                let style = ToolIcons.polygonalLassoStyle(in: size)
                for part in ToolIcons.polygonalLasso(in: size) { context.stroke(part, with: .foreground, style: style) }
            case .objectSelection:
                let style = ToolIcons.objectSelectionStyle(in: size)
                for corner in ToolIcons.objectSelectionCorners(in: size) { context.stroke(corner, with: .foreground, style: style) }
                context.fill(ToolIcons.objectSelectionPointer(in: size), with: .foreground)
            }
        }
    }

    /// `content` in black, `side` points square, as one PDF page of vectors. Laid out at a fine scale, so a side
    /// between whole points isn't rounded to one.
    @MainActor static func pdf(_ content: some View, side: CGFloat) -> Data {
        let renderer = ImageRenderer(content: content.foregroundStyle(.black).frame(width: side, height: side)
            .environment(\.displayScale, 100))
        let data = NSMutableData()
        renderer.render { size, render in
            var box = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            context.beginPDFPage(nil)
            render(context)
            context.endPDFPage()
            context.closePDF()
        }
        return data as Data
    }

    static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}

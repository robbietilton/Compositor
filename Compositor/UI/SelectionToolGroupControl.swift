import AppKit
import SwiftUI

/// The Photoshop-style selection family displayed by one tool-rail button.
enum SelectionToolGroupChoice: String, CaseIterable {
    case magic, quickSelection, object, magneticLasso

    var tool: NavigationTool {
        switch self {
        case .magic, .object: return .wand
        case .quickSelection: return .quickSelection
        case .magneticLasso: return .magneticLasso
        }
    }

    var title: String {
        switch self {
        case .magic: return "Magic Wand"
        case .quickSelection: return "Quick Selection"
        case .object: return "Object Selection"
        case .magneticLasso: return "Magnetic Lasso"
        }
    }
}

struct SelectionToolGroupControl: NSViewRepresentable {
    let session: EditorSession

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> SelectionToolGroupButton {
        let button = SelectionToolGroupButton()
        button.onPrimary = { [weak coordinator = context.coordinator] in
            coordinator?.choose(coordinator?.currentChoice ?? .magic)
        }
        button.onOpenMenu = { [weak coordinator = context.coordinator] button in
            coordinator?.presentMenu(from: button)
        }
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ nsView: SelectionToolGroupButton, context: Context) {
        context.coordinator.session = session
        nsView.onOpenMenu = { [weak coordinator = context.coordinator] button in
            coordinator?.presentMenu(from: button)
        }
        nsView.update(choice: context.coordinator.currentChoice)
    }

    final class Coordinator: NSObject {
        weak var session: EditorSession?

        init(session: EditorSession) { self.session = session }

        var currentChoice: SelectionToolGroupChoice? {
            guard let session else { return nil }
            switch session.tool {
            case .quickSelection: return .quickSelection
            case .magneticLasso: return .magneticLasso
            case .wand: return session.wandMode == .object ? .object : .magic
            default: return nil
            }
        }

        func choose(_ choice: SelectionToolGroupChoice) {
            guard let session else { return }
            switch choice {
            case .magic:
                session.wandMode = .wand
                session.selectTool(.wand)
            case .quickSelection:
                session.selectTool(.quickSelection)
            case .object:
                session.wandMode = .object
                session.selectTool(.wand)
            case .magneticLasso:
                session.selectTool(.magneticLasso)
            }
        }

        func presentMenu(from button: SelectionToolGroupButton) {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for choice in SelectionToolGroupChoice.allCases {
                let item = NSMenuItem(title: choice.title, action: #selector(selectMenuItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = choice.rawValue
                item.state = currentChoice == choice ? .on : .off
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: CGPoint(x: button.bounds.maxX + 6, y: button.bounds.maxY - 8), in: button)
        }

        @objc private func selectMenuItem(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String,
                  let choice = SelectionToolGroupChoice(rawValue: raw) else { return }
            choose(choice)
        }
    }
}

final class SelectionToolGroupButton: NSButton {
    private let iconView = NSImageView(frame: .zero)
    private let iconSize = NSSize(width: 18, height: 18)
    private var holdTask: DispatchWorkItem?
    private var mouseIsDown = false
    private var menuWasShown = false
    private var displayedChoice: SelectionToolGroupChoice = .magic
    private var isSelected = false

    var onPrimary: (() -> Void)?
    var onOpenMenu: ((SelectionToolGroupButton) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isTransparent = true
        setButtonType(.momentaryPushIn)
        focusRingType = .none
        refusesFirstResponder = true
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: iconSize.width),
            iconView.heightAnchor.constraint(equalToConstant: iconSize.height)
        ])
        setAccessibilityIdentifier("selectionToolGroup")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(choice: SelectionToolGroupChoice?) {
        displayedChoice = choice ?? .magic
        isSelected = choice != nil
        iconView.image = Self.icon(for: displayedChoice)
        setAccessibilityLabel(choice?.title ?? "Selection Tools")
        setAccessibilityValue(choice?.rawValue)
        needsDisplay = true
    }

    private static func icon(for choice: SelectionToolGroupChoice) -> NSImage? {
        if choice == .magic {
            return NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil)
        }
        if choice == .quickSelection {
            return NSImage(systemSymbolName: "scope", accessibilityDescription: nil)
        }
        if choice == .object {
            return NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: nil)
        }
        return NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let loop = NSBezierPath()
            loop.move(to: CGPoint(x: 2, y: 9)); loop.curve(to: CGPoint(x: 5, y: 3), controlPoint1: CGPoint(x: 1, y: 3), controlPoint2: CGPoint(x: 9, y: 1))
            loop.curve(to: CGPoint(x: 15, y: 8), controlPoint1: CGPoint(x: 11, y: 2), controlPoint2: CGPoint(x: 17, y: 4))
            loop.curve(to: CGPoint(x: 10, y: 12), controlPoint1: CGPoint(x: 15, y: 13), controlPoint2: CGPoint(x: 12, y: 14))
            loop.line(to: CGPoint(x: 2, y: 9)); loop.lineCapStyle = .round; loop.lineJoinStyle = .round
            NSColor.labelColor.setStroke(); loop.lineWidth = 1.4; loop.stroke()
            let magnet = NSBezierPath()
            magnet.move(to: CGPoint(x: 12, y: 13)); magnet.line(to: CGPoint(x: 16, y: 17))
            magnet.move(to: CGPoint(x: 10.8, y: 14.2)); magnet.line(to: CGPoint(x: 14.8, y: 18))
            NSColor.systemRed.setStroke(); magnet.lineWidth = 1.5; magnet.lineCapStyle = .round; magnet.stroke()
            return true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected || isHighlighted {
            let rect = bounds.insetBy(dx: 1, dy: 1)
            (isSelected ? NSColor.white.withAlphaComponent(0.12) : NSColor.white.withAlphaComponent(0.08)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            if isSelected { NSColor.white.withAlphaComponent(0.14).setStroke(); NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).stroke() }
        }
        super.draw(dirtyRect)
    }

    override func performClick(_ sender: Any?) { onPrimary?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseIsDown = true; menuWasShown = false; isHighlighted = true; needsDisplay = true
        holdTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.mouseIsDown, !self.menuWasShown else { return }
            self.menuWasShown = true; self.onOpenMenu?(self)
        }
        holdTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: task)
    }

    override func mouseUp(with event: NSEvent) {
        holdTask?.cancel(); holdTask = nil; mouseIsDown = false; isHighlighted = false
        if !menuWasShown { onPrimary?() }
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        holdTask?.cancel(); mouseIsDown = false; menuWasShown = true
        onOpenMenu?(self)
    }
}

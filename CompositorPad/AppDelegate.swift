import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    /// The menu bar, with the Mac's File, Edit, Image, Layer, Select and View commands and their shortcuts. The commands
    /// go to the window in front (`EditorWindowController`), which enables the ones that apply.
    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }
        builder.remove(menu: .format)
        typealias Window = EditorWindowController
        let recent = UIMenu(title: "Open Recent", children: [UIDeferredMenuElement.uncached { completion in
            Task { @MainActor in
                let urls = PadRecentProjects.shared.urls
                completion(urls.isEmpty ? [UIAction(title: "No Recent Projects", attributes: .disabled) { _ in }] : urls.compactMap { url in
                    PadRecentProjects.reference(to: url).map {
                        UICommand(title: url.deletingPathExtension().lastPathComponent, action: #selector(Window.openRecentProject(_:)), propertyList: $0)
                    }
                })
            }
        }])
        let open = UIMenu(options: .displayInline, children: [
            UIKeyCommand(title: "New Canvas", action: #selector(Window.newCanvasTab(_:)), input: "n", modifierFlags: .command),
            UIKeyCommand(title: "Open Project…", action: #selector(Window.openProject(_:)), input: "o", modifierFlags: .command),
            recent,
            UICommand(title: "Import Images…", action: #selector(Window.importImages(_:))),
            UICommand(title: "Import from Photos…", action: #selector(Window.importPhotos(_:))),
        ])
        let save = UIMenu(options: .displayInline, children: [
            UIKeyCommand(title: "Save", action: #selector(Window.saveProject(_:)), input: "s", modifierFlags: .command),
            UIKeyCommand(title: "Duplicate", action: #selector(Window.duplicateProject(_:)), input: "s", modifierFlags: [.command, .shift]),
            UICommand(title: "Rename…", action: #selector(Window.renameProject(_:))),
            UIKeyCommand(title: "Export PNG…", action: #selector(Window.exportPNG(_:)), input: "e", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "Export JPEG…", action: #selector(Window.exportJPEG(_:)), input: "s", modifierFlags: [.command, .alternate, .shift]),
        ])
        builder.insertChild(save, atStartOfMenu: .file)
        builder.insertChild(open, atStartOfMenu: .file)
        // Cut, Copy and Paste are the system's own; Copy Merged follows them, then the fills, as on the Mac.
        let fills = UIMenu(identifier: UIMenu.Identifier("com.wonderassembly.compositor.fill"), options: .displayInline, children: [
            UIKeyCommand(title: "Fill with Foreground Color", action: #selector(Window.fillWithForeground(_:)),
                         input: UIKeyCommand.inputDelete, modifierFlags: .alternate),
            UIKeyCommand(title: "Fill with Background Color", action: #selector(Window.fillWithBackground(_:)),
                         input: UIKeyCommand.inputDelete, modifierFlags: .command),
            UICommand(title: "Clear Selection Pixels", action: #selector(Window.clearSelectionPixels(_:))),
        ])
        builder.insertSibling(fills, afterMenu: .standardEdit)
        builder.insertSibling(UIMenu(options: .displayInline, children: [
            UIKeyCommand(title: "Copy Merged", action: #selector(Window.copyMerged(_:)), input: "c", modifierFlags: [.command, .shift]),
        ]), afterMenu: .standardEdit)
        // The Mac's Image, Layer and Select menus, so far as the iPad has them. ⌘A is the system's Select All, in the Edit
        // menu. Adjustments without an editor on iPad yet are listed, dimmed.
        let image = UIMenu.Identifier("com.wonderassembly.compositor.image")
        builder.insertSibling(UIMenu(title: "Image", identifier: image, children: [
            UIKeyCommand(title: "Curves…", action: #selector(Window.curves(_:)), input: "m", modifierFlags: .command),
            UIKeyCommand(title: "Levels…", action: #selector(Window.levels(_:)), input: "l", modifierFlags: .command),
            UIKeyCommand(title: "Hue/Saturation…", action: #selector(Window.hueSaturation(_:)), input: "u", modifierFlags: .command),
            UIKeyCommand(title: "Invert", action: #selector(Window.invertPixels(_:)), input: "i", modifierFlags: .command),
            UIMenu(options: .displayInline, children: [
                UIKeyCommand(title: "Canvas Size…", action: #selector(Window.canvasSize(_:)), input: "c", modifierFlags: [.command, .alternate]),
                UIKeyCommand(title: "Image Size…", action: #selector(Window.imageSize(_:)), input: "i", modifierFlags: [.command, .alternate]),
            ]),
        ]), afterMenu: .edit)
        let layer = UIMenu.Identifier("com.wonderassembly.compositor.layer")
        builder.insertSibling(UIMenu(title: "Layer", identifier: layer, children: [
            UIMenu(title: "New Adjustment Layer", children: AdjustmentKind.allCases.map { kind in
                UICommand(title: kind.rawValue + (kind.isEditable ? "…" : ""), action: #selector(Window.newAdjustmentLayer(_:)),
                          propertyList: kind.rawValue)
            }),
            UICommand(title: "Edit Adjustment…", action: #selector(Window.editAdjustment(_:))),
            UIMenu(options: .displayInline, children: [
                UIKeyCommand(title: "Transform Layer", action: #selector(Window.transformLayer(_:)), input: "t", modifierFlags: .command),
                UIKeyCommand(title: "Duplicate Layer", action: #selector(Window.layerViaCopy(_:)), input: "j", modifierFlags: .command),
            ]),
        ]), afterMenu: image)
        builder.insertSibling(UIMenu(title: "Select", identifier: UIMenu.Identifier("com.wonderassembly.compositor.select"), children: [
            UIMenu(options: .displayInline, children: [
                UICommand(title: "All", action: #selector(Window.selectAll(_:))),
                UIKeyCommand(title: "Deselect", action: #selector(Window.deselect(_:)), input: "d", modifierFlags: .command),
                UIKeyCommand(title: "Inverse", action: #selector(Window.invertSelection(_:)), input: "i", modifierFlags: [.command, .shift]),
                UICommand(title: "Layer’s Pixels", action: #selector(Window.selectLayerPixels(_:))),
                UIKeyCommand(title: "Subject", action: #selector(Window.selectSubject(_:)), input: "a", modifierFlags: [.command, .alternate]),
                UICommand(title: "Mask’s Black Areas", action: #selector(Window.selectMaskBlackAreas(_:))),
            ]),
            UIMenu(options: .displayInline, children: [
                UICommand(title: "Expand…", action: #selector(Window.expandSelection(_:))),
                UICommand(title: "Contract…", action: #selector(Window.contractSelection(_:))),
                UICommand(title: "Feather…", action: #selector(Window.featherSelection(_:))),
            ]),
        ]), afterMenu: layer)
        builder.replace(menu: .close, with: UIMenu(options: .displayInline, children: [
            UIKeyCommand(title: "Close Tab", action: #selector(Window.closeTab(_:)), input: "w", modifierFlags: .command),
        ]))
        builder.insertChild(UIMenu(options: .displayInline, children: [
            UIKeyCommand(title: "Fit Canvas", action: #selector(Window.fitCanvas(_:)), input: "0", modifierFlags: .command),
            UIKeyCommand(title: "Actual Pixels", action: #selector(Window.actualPixels(_:)), input: "1", modifierFlags: .command),
            UIKeyCommand(title: "Zoom In", action: #selector(Window.zoomIn(_:)), input: "=", modifierFlags: .command),
            UIKeyCommand(title: "Zoom Out", action: #selector(Window.zoomOut(_:)), input: "-", modifierFlags: .command),
        ]), atStartOfMenu: .view)
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var editor: EditorWindowController? {
        (window?.rootViewController as? UINavigationController)?.viewControllers.first as? EditorWindowController
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        // A project or image opened from elsewhere comes into a window already open, as a tab, rather than a new
        // window, as the Mac's does.
        scene.activationConditions.canActivateForTargetContentIdentifierPredicate = NSPredicate(value: true)
        scene.activationConditions.prefersToActivateForTargetContentIdentifierPredicate = NSPredicate(value: true)
        // No smaller than the Mac's window may be, so the canvas keeps room between the tools and the Layers panel.
        scene.sizeRestrictions?.minimumSize = CGSize(width: 800, height: 520)
        let editor = EditorWindowController()
        let window = UIWindow(windowScene: scene)
        // The navigation bar is the window's toolbar; there's nothing to navigate to.
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        self.window = window
        editor.loadViewIfNeeded()
        if let activity = connectionOptions.userActivities.first ?? session.stateRestorationActivity { editor.restore(from: activity) }
        editor.open(connectionOptions.urlContexts.map(\.url))
    }

    /// Files and other apps hand projects and images over here: “Open in Compositor”, or a tap on a project in Files.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        editor?.open(URLContexts.map(\.url))
    }

    func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? { editor?.restorationActivity }

    func sceneDidEnterBackground(_ scene: UIScene) { editor?.saveAll() }

    func sceneDidDisconnect(_ scene: UIScene) { editor?.closeAll() }
}

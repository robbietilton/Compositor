import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Timing.launched(to: "the app's own code")
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    /// The menu bar, with the Mac's File, Edit, View, Select, Image, Filter and Layer commands, in the Mac's order, and their
    /// shortcuts. The commands go to the window in front (`EditorWindowController`), which enables the ones that apply.
    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }
        builder.remove(menu: .format)
        // The Mac has no Find: its ⌘G, ⇧⌘G and ⌘E are the Layer menu's.
        builder.remove(menu: .find)
        typealias Window = EditorWindowController
        let recent = UIMenu(title: "Open Recent", children: [UIDeferredMenuElement.uncached { completion in
            Task { @MainActor in completion(Self.recentItems(for: PadRecentProjects.shared.urls)) }
        }])
        let open = UIMenu(options: .displayInline, children: [
            UIKeyCommand(title: "New Canvas…", action: #selector(Window.newCanvasTab(_:)), input: "n", modifierFlags: .command),
            UIKeyCommand(title: "Open Project…", action: #selector(Window.openProject(_:)), input: "o", modifierFlags: .command),
            recent,
            UICommand(title: "Import Images…", action: #selector(Window.importImages(_:))),
            UICommand(title: "Import from Photos…", action: #selector(Window.importPhotos(_:))),
        ])
        let save = UIMenu(options: .displayInline, children: [
            UIKeyCommand(title: "Save", action: #selector(Window.saveProject(_:)), input: "s", modifierFlags: .command),
            UIKeyCommand(title: "Duplicate", action: #selector(Window.duplicateProject(_:)), input: "s", modifierFlags: [.command, .shift]),
            UICommand(title: "Rename…", action: #selector(Window.renameProject(_:))),
        ])
        // The exports in a group of their own, as on the Mac.
        let export = UIMenu(options: .displayInline, children: [
            UIKeyCommand(title: "Export PNG…", action: #selector(Window.exportPNG(_:)), input: "e", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "Export JPEG…", action: #selector(Window.exportJPEG(_:)), input: "s", modifierFlags: [.command, .alternate, .shift]),
        ])
        builder.insertChild(export, atStartOfMenu: .file)
        builder.insertChild(save, atStartOfMenu: .file)
        builder.insertChild(open, atStartOfMenu: .file)
        // The Mac's Cut, Copy, Copy Merged and Paste in place of the system's group, then the fills. A field being edited
        // takes Cut, Copy and Paste, and the canvas otherwise; Select All is Select › All.
        let pasteboard = UIMenu.Identifier("com.wonderassembly.compositor.pasteboard")
        builder.replace(menu: .standardEdit, with: UIMenu(identifier: pasteboard, options: .displayInline, children: [
            UIKeyCommand(title: "Cut", action: #selector(UIResponderStandardEditActions.cut(_:)), input: "x", modifierFlags: .command),
            UIKeyCommand(title: "Copy", action: #selector(UIResponderStandardEditActions.copy(_:)), input: "c", modifierFlags: .command),
            UIKeyCommand(title: "Copy Merged", action: #selector(Window.copyMerged(_:)), input: "c", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "Paste", action: #selector(UIResponderStandardEditActions.paste(_:)), input: "v", modifierFlags: .command),
        ]))
        let fills = UIMenu(identifier: UIMenu.Identifier("com.wonderassembly.compositor.fill"), options: .displayInline, children: [
            UIKeyCommand(title: "Fill with Foreground Color", action: #selector(Window.fillWithForeground(_:)),
                         input: UIKeyCommand.inputDelete, modifierFlags: .alternate),
            UIKeyCommand(title: "Fill with Background Color", action: #selector(Window.fillWithBackground(_:)),
                         input: UIKeyCommand.inputDelete, modifierFlags: .command),
            UICommand(title: "Clear Selection Pixels", action: #selector(Window.clearSelectionPixels(_:))),
            UIKeyCommand(title: "Content-Aware Fill…", action: #selector(Window.applyFilter(_:)), input: UIKeyCommand.inputDelete,
                         modifierFlags: .shift, propertyList: FilterKind.contentAwareFill.rawValue),
        ])
        builder.insertSibling(fills, afterMenu: pasteboard)
        // The Mac's Select, Image, Filter and Layer menus, after View as there. What the iPad has no editor or dialog for
        // yet is listed, dimmed.
        let select = UIMenu.Identifier("com.wonderassembly.compositor.select")
        builder.insertSibling(UIMenu(title: "Select", identifier: select, children: [
            UIMenu(options: .displayInline, children: [
                UIKeyCommand(title: "All", action: #selector(UIResponderStandardEditActions.selectAll(_:)), input: "a", modifierFlags: .command),
                UIKeyCommand(title: "Deselect", action: #selector(Window.deselect(_:)), input: "d", modifierFlags: .command),
                UIKeyCommand(title: "Inverse", action: #selector(Window.invertSelection(_:)), input: "i", modifierFlags: [.command, .shift]),
                UICommand(title: "Layer’s Pixels", action: #selector(Window.selectLayerPixels(_:))),
                UIKeyCommand(title: "Subject", action: #selector(Window.selectSubject(_:)), input: "a", modifierFlags: [.command, .alternate]),
                UIAction(title: "Color Range…", attributes: .disabled) { _ in },
                UICommand(title: "Mask’s Black Areas", action: #selector(Window.selectMaskBlackAreas(_:))),
            ]),
            UIMenu(options: .displayInline, children: [
                UICommand(title: "Expand…", action: #selector(Window.expandSelection(_:))),
                UICommand(title: "Contract…", action: #selector(Window.contractSelection(_:))),
                UICommand(title: "Feather…", action: #selector(Window.featherSelection(_:))),
            ]),
        ]), afterMenu: .view)
        let image = UIMenu.Identifier("com.wonderassembly.compositor.image")
        builder.insertSibling(UIMenu(title: "Image", identifier: image, children: [
            UIKeyCommand(title: "Curves…", action: #selector(Window.curves(_:)), input: "m", modifierFlags: .command),
            UIKeyCommand(title: "Levels…", action: #selector(Window.levels(_:)), input: "l", modifierFlags: .command),
            UIKeyCommand(title: "Hue/Saturation…", action: #selector(Window.hueSaturation(_:)), input: "u", modifierFlags: .command),
        ] + [FilterKind.blackWhite, .colorBalance, .exposure, .gradientMap, .grain].map { kind in
            UICommand(title: kind.rawValue + "…", action: #selector(Window.applyFilter(_:)), propertyList: kind.rawValue)
        } + [
            UIKeyCommand(title: "Invert", action: #selector(Window.invertPixels(_:)), input: "i", modifierFlags: .command),
            UIMenu(options: .displayInline, children: [
                UIKeyCommand(title: "Canvas Size…", action: #selector(Window.canvasSize(_:)), input: "c", modifierFlags: [.command, .alternate]),
                UIKeyCommand(title: "Image Size…", action: #selector(Window.imageSize(_:)), input: "i", modifierFlags: [.command, .alternate]),
                UIAction(title: "Trim…", attributes: .disabled) { _ in },
            ]),
            UIMenu(options: .displayInline, children: [
                UICommand(title: "Flip Canvas Horizontal", action: #selector(Window.flipCanvas(_:)), propertyList: true),
                UICommand(title: "Flip Canvas Vertical", action: #selector(Window.flipCanvas(_:)), propertyList: false),
            ]),
        ]), afterMenu: select)
        let filter = UIMenu.Identifier("com.wonderassembly.compositor.filter")
        builder.insertSibling(UIMenu(title: "Filter", identifier: filter, children: FilterKind.allCases.filter {
            $0 != .contentAwareFill && !$0.isImageAdjustment
        }.map { kind in
            UICommand(title: kind.rawValue + "…", action: #selector(Window.applyFilter(_:)), propertyList: kind.rawValue)
        }), afterMenu: image)
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
            UIMenu(options: .displayInline, children: [
                UIKeyCommand(title: "Create Clipping Mask", action: #selector(Window.toggleClippingMask(_:)), input: "g",
                             modifierFlags: [.command, .alternate]),
            ]),
            UIMenu(options: .displayInline, children: [
                UIKeyCommand(title: "Group Selected Layers", action: #selector(Window.groupLayers(_:)), input: "g", modifierFlags: .command),
                UIKeyCommand(title: "Ungroup Layers", action: #selector(Window.ungroupLayers(_:)), input: "g", modifierFlags: [.command, .shift]),
                UICommand(title: "Move Out of Folder", action: #selector(Window.moveOutOfFolder(_:))),
                UIKeyCommand(title: "New Blank Layer", action: #selector(Window.newBlankLayer(_:)), input: "n", modifierFlags: [.command, .shift]),
                UICommand(title: "Rename Layer…", action: #selector(Window.renameLayer(_:))),
                UICommand(title: "Hide Layer", action: #selector(Window.toggleLayerVisibility(_:))),
            ]),
            UIMenu(options: .displayInline, children: [
                UIKeyCommand(title: "Move Layer Up", action: #selector(Window.moveLayer(_:)), input: "]", modifierFlags: .command,
                             propertyList: 1),
                UIKeyCommand(title: "Move Layer Down", action: #selector(Window.moveLayer(_:)), input: "[", modifierFlags: .command,
                             propertyList: -1),
                UIKeyCommand(title: "Merge Down", action: #selector(Window.mergeLayers(_:)), input: "e", modifierFlags: .command),
            ]),
            UIMenu(options: .displayInline, children: [
                UICommand(title: "Flip Layer Horizontal", action: #selector(Window.flipLayers(_:)), propertyList: true),
                UICommand(title: "Flip Layer Vertical", action: #selector(Window.flipLayers(_:)), propertyList: false),
            ]),
            UIMenu(options: .displayInline, children: [
                UICommand(title: "Delete Layer", action: #selector(Window.deleteLayer(_:))),
            ]),
        ]), afterMenu: filter)
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

extension AppDelegate {
    /// Open Recent's items for `urls`, as the Mac's: the projects, newest first, then Clear Menu, dimmed when there are
    /// none.
    static func recentItems(for urls: [URL]) -> [UIMenuElement] {
        let projects: [UIMenuElement] = urls.compactMap { url in
            PadRecentProjects.reference(to: url).map {
                UICommand(title: url.deletingPathExtension().lastPathComponent,
                          action: #selector(EditorWindowController.openRecentProject(_:)), propertyList: $0)
            }
        }
        let clear = UICommand(title: "Clear Menu", action: #selector(EditorWindowController.clearRecentProjects(_:)),
                              attributes: projects.isEmpty ? .disabled : [])
        return projects.isEmpty ? [clear] : [UIMenu(options: .displayInline, children: projects), clear]
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    /// Whether the app's first window is still to come; its first frame ends the launch.
    private static var launching = true
    private var editor: EditorWindowController? {
        (window?.rootViewController as? UINavigationController)?.viewControllers.first as? EditorWindowController
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let launching = Self.launching
        Self.launching = false
        if launching { Timing.launched(to: "the window") }
        let settingUp = Timing.begin("Window setup")
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
        Timing.end(settingUp)
        if launching { editor.activeTab?.canvas.afterNextFrame { Timing.launched(to: "the first frame") } }
    }

    /// Files and other apps hand projects and images over here: “Open in Compositor”, or a tap on a project in Files.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        editor?.open(URLContexts.map(\.url))
    }

    func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? { editor?.restorationActivity }

    func sceneDidEnterBackground(_ scene: UIScene) { editor?.saveAll() }

    func sceneDidDisconnect(_ scene: UIScene) { editor?.closeAll() }
}

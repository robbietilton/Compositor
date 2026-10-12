import AppKit
import Sparkle

/// Sparkle's own windows for every step of an update but one: the update it finds is offered in a plain alert, the
/// same few lines and buttons as Sparkle's compact one, with what's new listed under them rather than in a web view.
/// The feed gives what's new in the item's `<changes>`, plain text, a line a change. Not its `<description>`: older
/// copies, on Sparkle's own alert, would show that in a large release-notes box.
@MainActor final class UpdateDriver: NSObject, SPUUserDriver {
    private let standard = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
    weak var updater: SPUUpdater?

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard !appcastItem.isInformationOnlyUpdate else {
            standard.showUpdateFound(with: appcastItem, state: state, reply: reply)
            return
        }
        // Closes Sparkle's Checking… window, which it would close itself when showing its own alert.
        standard.dismissUpdateInstallation()
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Compositor"
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let downloaded = state.stage != .notDownloaded
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = L10n.format("A new version of %@ is available!", name)
        alert.informativeText = downloaded
            ? L10n.format("%@ %@ is ready to install — you have %@.", name, appcastItem.displayVersionString, current)
            : L10n.format("%@ %@ is now available — you have %@. Would you like to download it now?", name, appcastItem.displayVersionString, current)
        let changes = Self.changes(in: appcastItem)
        if !changes.isEmpty { alert.accessoryView = Self.list(changes) }
        alert.addButton(withTitle: L10n.string(downloaded ? "Install and Relaunch" : "Install Update"))
        alert.addButton(withTitle: L10n.string("Remind Me Later"))
        alert.addButton(withTitle: L10n.string("Skip This Version"))
        if let updater, updater.allowsAutomaticUpdates {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = L10n.string("Automatically download and install updates in the future")
            alert.suppressionButton?.state = updater.automaticallyDownloadsUpdates ? .on : .off
        }
        alert.layout()
        Self.alignIconWithTitle(alert)
        NSApp.activate()
        // After Sparkle's call returns, so its updater isn't held up inside a modal run loop.
        DispatchQueue.main.async { [weak self] in
            let response = alert.runModal()
            if let button = alert.suppressionButton, alert.showsSuppressionButton {
                self?.updater?.automaticallyDownloadsUpdates = button.state == .on
            }
            switch response {
            case .alertFirstButtonReturn: reply(.install)
            case .alertThirdButtonReturn: reply(.skip)
            default: reply(.dismiss)
            }
        }
    }

    /// NSAlert starts its text well below the icon's top in this layout. Everything but the icon moves up to just
    /// under it, and the window loses the same height off its top, so the icon keeps its place and the margins stay.
    private static func alignIconWithTitle(_ alert: NSAlert) {
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        let window = alert.window
        guard let content = window.contentView else { return }
        let views = descendants(content)
        guard let icon = views.compactMap({ $0 as? NSImageView }).first, let holder = icon.superview, !holder.isFlipped,
              let title = views.compactMap({ $0 as? NSTextField }).first(where: { $0.stringValue == alert.messageText })
        else { return }
        // The title's top sits a little below the icon's, where the icon's artwork starts inside its transparent margin.
        let lift = icon.convert(icon.bounds, to: nil).maxY - title.convert(title.bounds, to: nil).maxY - 5
        guard lift > 0 else { return }
        // The views don't all follow the window's top as it shrinks, so each is put back where it should be after:
        // the same distance from the bottom, which brings it up by the lift, and the icon the same distance from the top.
        let frames = holder.subviews.map(\.frame)
        var frame = window.frame
        frame.size.height -= lift
        frame.origin.y += lift
        window.setFrame(frame, display: false)
        for (view, old) in zip(holder.subviews, frames) {
            view.frame = view === icon ? old.offsetBy(dx: 0, dy: -lift) : old
        }
    }

    /// The item's changes as a list: a line each, any leading bullet or dash taken off.
    private static func changes(in item: SUAppcastItem) -> [String] {
        guard let text = item.propertiesDictionary["changes"] as? String else { return [] }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "•-* ")) }
            .filter { !$0.isEmpty }
    }

    /// What's new, as text under the alert's message: no box, no scrolling, a bullet a line.
    private static func list(_ changes: [String]) -> NSView {
        let style = NSMutableParagraphStyle()
        style.headIndent = 12
        style.paragraphSpacing = 4
        style.tabStops = [NSTextTab(textAlignment: .left, location: 12)]
        let text = NSMutableAttributedString(string: "What’s new\n", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
        ])
        text.append(NSAttributedString(string: changes.map { "•\t\($0)" }.joined(separator: "\n"), attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
        ]))
        // NSAlert keeps its wide layout (icon beside the text, buttons in a row) only while the accessory view is narrow,
        // about 265 points; any wider and it stacks everything. So the view stays 260 wide, and the text runs on past it,
        // unclipped, across the alert's whole text column, 489 points.
        let label = NSTextField(labelWithAttributedString: text)
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 480
        label.frame = NSRect(origin: .zero, size: label.fittingSize)
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: label.frame.height))
        holder.clipsToBounds = false
        holder.addSubview(label)
        return holder
    }

    // Every other step, as Sparkle draws it.
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        standard.show(request, reply: reply)
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { standard.showUserInitiatedUpdateCheck(cancellation: cancellation) }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}
    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
    }
    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        standard.showUpdaterError(error, acknowledgement: acknowledgement)
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { standard.showDownloadInitiated(cancellation: cancellation) }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) { standard.showDownloadDidReceiveData(ofLength: length) }
    func showDownloadDidStartExtractingUpdate() { standard.showDownloadDidStartExtractingUpdate() }
    func showExtractionReceivedProgress(_ progress: Double) { standard.showExtractionReceivedProgress(progress) }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { standard.showReady(toInstallAndRelaunch: reply) }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        standard.showInstallingUpdate(withApplicationTerminated: applicationTerminated, retryTerminatingApplication: retryTerminatingApplication)
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
    }
    func showUpdateInFocus() { standard.showUpdateInFocus() }
    func dismissUpdateInstallation() { standard.dismissUpdateInstallation() }
}

/// In a debug build, `-UpdateFeedURL <url>` on the command line checks that feed instead, to try an update locally.
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "UpdateFeedURL")
        #else
        return nil
        #endif
    }
}

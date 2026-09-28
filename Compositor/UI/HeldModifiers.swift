import AppKit
import Observation

/// The modifier keys held down right now, for controls that show what a held key temporarily changes, as
/// Photoshop's options bar does: Command flips Auto Select, Shift flips the aspect-ratio lock.
/// Keys held while typing in a text field don't count — ⌘A there shouldn't flicker the options bar.
@MainActor @Observable final class HeldModifiers {
    static let shared = HeldModifiers()
    private(set) var flags: NSEvent.ModifierFlags = []
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown, .leftMouseUp]) { event in
            MainActor.assumeIsolated { HeldModifiers.shared.update(event.modifierFlags) }
            return event
        }
        // A key let go while another app is in front never reaches this one (⌘Tab is the usual way).
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { HeldModifiers.shared.update([]) }
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { HeldModifiers.shared.update(NSEvent.modifierFlags) }
            },
            // Nor does one let go while a menu is open.
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { HeldModifiers.shared.update(NSEvent.modifierFlags) }
            },
        ]
    }

    func update(_ raw: NSEvent.ModifierFlags) {
        let typing = NSApp.keyWindow?.firstResponder is NSText
        let held = typing ? [] : raw.intersection([.command, .shift, .option, .control])
        if held != flags { flags = held }
    }
}

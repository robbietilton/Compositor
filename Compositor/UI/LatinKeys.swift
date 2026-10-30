import AppKit
import Carbon.HIToolbox

/// Shortcuts are letters, matched by what a key types. On a layout that types no Latin letters (Russian, Greek,
/// Arabic, Hebrew…) none of them would match, so a key that types a non-ASCII character is read as what the same key
/// types on the person's Latin layout (the one macOS uses for ⌘ shortcuts): the B key still picks the Brush. Latin
/// layouts such as German or French are left as they are.
enum LatinKeys {
    static func event(_ event: NSEvent) -> NSEvent {
        guard event.type == .keyDown, let typed = event.charactersIgnoringModifiers, !typed.isEmpty,
              typed.unicodeScalars.contains(where: { !$0.isASCII }),
              let latin = character(for: event.keyCode, shift: event.modifierFlags.contains(.shift)),
              latin.unicodeScalars.allSatisfy(\.isASCII),
              let translated = NSEvent.keyEvent(with: event.type, location: event.locationInWindow, modifierFlags: event.modifierFlags,
                                                timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                                                characters: latin, charactersIgnoringModifiers: latin,
                                                isARepeat: event.isARepeat, keyCode: event.keyCode)
        else { return event }
        return translated
    }

    /// What `keyCode` types on the person's Latin keyboard layout, or nil when it types nothing there.
    static func character(for keyCode: UInt16, shift: Bool) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layout = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layout.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(base, keyCode, UInt16(kUCKeyActionDown), shift ? UInt32(shiftKey >> 8) & 0xff : 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeys, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}

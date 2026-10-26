import AppKit
import Carbon
import SopranoMixCore

/// 'SMix': the signature of Soprano Mix's Carbon hotkey.
private let panelHotkeySignature: OSType = 0x534D_6978
private let panelHotkeyID: UInt32 = 1

/// The global shortcut that toggles the panel, through Carbon's `RegisterEventHotKey`
/// (no Accessibility needed; fires even while the panel is key). Soprano Cast's
/// `CarbonHotkeys` reduced to one combo.
///
/// Named keys register their key code as is. Character keys resolve to a key code on the
/// current layout at registration, so the registration is redone when the selected input
/// source changes.
///
/// The event handler's user data is a retained reference to this object, released never:
/// it lives for the whole process, like the handler.
@MainActor
final class CarbonPanelHotkey: PanelHotkeyRegistering {
    private var hotkey: PanelHotkey?
    private var action: (@MainActor () -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false
    private var inputSourceObserver: NSObjectProtocol?

    init() {}

    @discardableResult
    func register(_ hotkey: PanelHotkey?, action: @escaping @MainActor () -> Void) -> Bool {
        unregisterCurrent()
        self.hotkey = hotkey
        self.action = action
        guard hotkey != nil else { return true }
        installHandlerIfNeeded()
        observeInputSourceIfNeeded()
        return registerCurrent()
    }

    // MARK: - Pure helpers

    /// Carbon modifier flags (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`); `fn`
    /// has no Carbon hotkey modifier and is dropped.
    static func carbonModifiers(_ modifiers: ModifierSet) -> UInt32 {
        var mask: UInt32 = 0
        if modifiers.contains(.command) { mask |= UInt32(cmdKey) }
        if modifiers.contains(.option) { mask |= UInt32(optionKey) }
        if modifiers.contains(.control) { mask |= UInt32(controlKey) }
        if modifiers.contains(.shift) { mask |= UInt32(shiftKey) }
        return mask
    }

    /// The key code a named key registers with (its first code: Return, not keypad Enter).
    static func keyCode(forNamed key: NamedKey) -> UInt16 {
        key.keyCodes[0]
    }

    // MARK: - Registration

    private func registerCurrent() -> Bool {
        unregisterCurrent()
        guard let hotkey else { return true }
        let keyCode: UInt16
        switch hotkey.key {
        case .named(let named):
            keyCode = Self.keyCode(forNamed: named)
        case .character(let character):
            guard let code = Self.keyCode(forCharacter: character) else { return false }
            keyCode = code
        }
        let hotKeyID = EventHotKeyID(signature: panelHotkeySignature, id: panelHotkeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode), Self.carbonModifiers(hotkey.modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else { return false }
        hotKeyRef = ref
        return true
    }

    private func unregisterCurrent() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    fileprivate func pressed(id: UInt32) {
        guard id == panelHotkeyID, hotKeyRef != nil else { return }
        action?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passRetained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), panelHotkeyHandler, 1, &eventType, userData, nil)
        if status == noErr {
            handlerInstalled = true
        } else {
            Unmanaged<CarbonPanelHotkey>.fromOpaque(userData).release()
        }
    }

    private func observeInputSourceIfNeeded() {
        guard inputSourceObserver == nil else { return }
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hotkey != nil else { return }
                _ = self.registerCurrent()
            }
        }
    }

    // MARK: - Keyboard layout

    /// The key code that types `character` (lowercased) with no modifiers on the current
    /// layout (UCKeyTranslate over codes 0…127), nil when none does. The lowest code wins,
    /// so "1" is the number row's key, not the keypad's.
    private static func keyCode(forCharacter character: Character) -> UInt16? {
        let wanted = String(character).lowercased()
        guard let layout = currentLayoutData() else { return nil }
        return layout.withUnsafeBytes { buffer -> UInt16? in
            guard let pointer = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }
            let keyboardType = UInt32(LMGetKbdType())
            for code in UInt16(0) ..< 128 {
                if let typed = translate(code, layout: pointer, keyboardType: keyboardType),
                   String(typed).lowercased() == wanted {
                    return code
                }
            }
            return nil
        }
    }

    /// The 'uchr' data of the current keyboard layout. Input methods without one (some
    /// CJK input sources) fall back to the ASCII-capable layout they type through.
    private static func currentLayoutData() -> Data? {
        let sources = [
            TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
        ]
        for case let source? in sources {
            if let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
                return Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
            }
        }
        return nil
    }

    /// What `keyCode` types with no modifiers, dead keys shown as their own character.
    /// Control characters and whitespace are nil.
    private static func translate(
        _ keyCode: UInt16,
        layout: UnsafePointer<UCKeyboardLayout>,
        keyboardType: UInt32
    ) -> Character? {
        var deadKeyState: UInt32 = 0
        var length = 0
        var units = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            layout,
            keyCode,
            UInt16(kUCKeyActionDisplay),
            0,
            keyboardType,
            OptionBits(kUCKeyTranslateNoDeadKeysMask),
            &deadKeyState,
            units.count,
            &length,
            &units
        )
        guard status == noErr, length > 0 else { return nil }
        let text = String(decoding: units.prefix(length), as: UTF16.self)
        guard text.count == 1, let character = text.first,
              !character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
              !character.isWhitespace else {
            return nil
        }
        return character
    }
}

/// The Carbon event handler. Carbon dispatches application-target events on the main
/// thread; only the hotkey id and the object's address cross into the main actor.
private func panelHotkeyHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == panelHotkeySignature else { return OSStatus(eventNotHandledErr) }
    let address = Int(bitPattern: userData)
    let id = hotKeyID.id
    MainActor.assumeIsolated {
        guard let pointer = UnsafeRawPointer(bitPattern: address) else { return }
        Unmanaged<CarbonPanelHotkey>.fromOpaque(pointer).takeUnretainedValue().pressed(id: id)
    }
    return noErr
}

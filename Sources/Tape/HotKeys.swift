import Carbon.HIToolbox
import Foundation

/// Global hot keys via the Carbon hot key API.
///
/// Deliberately not `NSEvent.addGlobalMonitorForEvents`: that requires the
/// Accessibility permission and cannot *consume* the keystroke, so every
/// shortcut would also type its character into whatever app has focus.
/// `RegisterEventHotKey` needs no permission and swallows the event, which is
/// exactly what a background recorder needs.
final class HotKeyCenter {
    typealias Handler = () -> Void

    private var refs: [EventHotKeyRef?] = []
    private var handlers: [UInt32: Handler] = [:]
    private var eventHandler: EventHandlerRef?

    /// 'TAB1'
    private static let signature: OSType = 0x5441_4231

    init() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            HotKeyCenter.callback,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    deinit {
        for ref in refs { if let ref { UnregisterEventHotKey(ref) } }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    @discardableResult
    func register(key: Int, modifiers: Int, id: UInt32, handler: @escaping Handler) -> Bool {
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: HotKeyCenter.signature, id: id)
        let status = RegisterEventHotKey(
            UInt32(key),
            UInt32(modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr else {
            log("hot key \(id) could not be registered (status \(status))")
            handlers[id] = nil
            return false
        }
        refs.append(ref)
        return true
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    fileprivate func log(_ message: String) {
        FileHandle.standardError.write(Data("tape: \(message)\n".utf8))
    }

    private static let callback: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return noErr }
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
        guard status == noErr else { return status }
        Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue().fire(hotKeyID.id)
        return noErr
    }
}

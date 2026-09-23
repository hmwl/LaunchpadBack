import AppKit
import Carbon.HIToolbox

enum HotKeyOption: String, CaseIterable {
    case none, f4, optionSpace, controlSpace, commandOptionL

    static var current: HotKeyOption {
        HotKeyOption(rawValue: UserDefaults.standard.string(forKey: "hotkey") ?? "") ?? .f4
    }

    var title: String {
        switch self {
        case .none: return L10n.t("无", "None")
        case .f4: return "F4"
        case .optionSpace: return "⌥ Space"
        case .controlSpace: return "⌃ Space"
        case .commandOptionL: return "⌥⌘ L"
        }
    }

    var key: (code: UInt32, mods: UInt32)? {
        switch self {
        case .none: return nil
        case .f4: return (UInt32(kVK_F4), 0)
        case .optionSpace: return (UInt32(kVK_Space), UInt32(optionKey))
        case .controlSpace: return (UInt32(kVK_Space), UInt32(controlKey))
        case .commandOptionL: return (UInt32(kVK_ANSI_L), UInt32(cmdKey | optionKey))
        }
    }
}

final class HotKeyManager: @unchecked Sendable {
    static let shared = HotKeyManager()

    @MainActor var onTrigger: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func apply(_ opt: HotKeyOption) {
        if let ref {
            UnregisterEventHotKey(ref)
            self.ref = nil
        }
        guard let key = opt.key else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
                Task { @MainActor in HotKeyManager.shared.onTrigger?() }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let hkID = EventHotKeyID(signature: OSType(0x4C50_4844), id: 1)
        RegisterEventHotKey(key.code, key.mods, hkID, GetApplicationEventTarget(), 0, &ref)
    }
}

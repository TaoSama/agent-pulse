import AppKit
import Carbon.HIToolbox
import Foundation

/// Reports the current registration state of a global hot key.
public enum HotKeyRegistrationState: Sendable, Equatable {
    /// The hot key has not been registered yet, or has been intentionally stopped.
    case inactive
    /// The hot key is registered and the handler is armed.
    case active
    /// Registration failed with a human-readable reason and an OSStatus code.
    case failed(reason: String, code: Int32)
}

/// Errors that can occur while registering a global hot key through the Carbon Event Manager.
public enum HotKeyServiceError: Error, CustomStringConvertible, Sendable {
    case eventHandlerInstallFailed(OSStatus)
    case hotKeyRegistrationFailed(OSStatus)

    public var description: String {
        switch self {
        case let .eventHandlerInstallFailed(status):
            return "Failed to install the Carbon event handler (OSStatus \(status))."
        case let .hotKeyRegistrationFailed(status):
            return "Failed to register the global hot key (OSStatus \(status))."
        }
    }
}

/// Manages a single global keyboard shortcut (default: Cmd+Option+V) using the Carbon
/// Event Manager's `RegisterEventHotKey` API.
///
/// This implementation deliberately avoids `CGEventTap` and the Accessibility permission
/// prompt: `RegisterEventHotKey` installs a system-wide hot key without requiring the user
/// to grant Accessibility access.
///
/// All lifecycle mutation and callback delivery happens on the main actor so callers can
/// safely touch UI state from the handler and observe ``state`` without extra synchronization.
@MainActor
public final class HotKeyService {
    /// Default shortcut: V (kVK_ANSI_V) with Command + Option.
    public static let defaultKeyCode = UInt32(kVK_ANSI_V)
    public static let defaultModifiers = UInt32(cmdKey | optionKey)

    /// Current registration state. Observe this to surface success/failure in the UI.
    public private(set) var state: HotKeyRegistrationState = .inactive {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    /// Invoked on the main actor each time the hot key is pressed.
    public var onTrigger: (() -> Void)?

    /// Invoked on the main actor whenever ``state`` changes. Use this to report
    /// registration failures explicitly instead of silently swallowing them.
    public var onStateChange: ((HotKeyRegistrationState) -> Void)?

    private let keyCode: UInt32
    private let modifiers: UInt32
    private let signature: FourCharCode
    private let hotKeyID: UInt32

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    /// A per-instance unique id lets multiple services coexist and lets the C callback route
    /// events back to the correct instance.
    private static var nextID: UInt32 = 1
    private static var registry: [UInt32: HotKeyService] = [:]

    /// Creates a service for the given shortcut. Call ``start()`` to actually register it.
    /// - Parameters:
    ///   - keyCode: A virtual key code (see `Carbon.HIToolbox` `kVK_*`). Defaults to `V`.
    ///   - modifiers: Carbon modifier flags (e.g. `cmdKey`, `optionKey`). Defaults to Cmd+Option.
    public init(
        keyCode: UInt32 = HotKeyService.defaultKeyCode,
        modifiers: UInt32 = HotKeyService.defaultModifiers
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        // "APHK" = AgentPulse Hot Key.
        self.signature = HotKeyService.fourCharCode("APHK")
        let id = HotKeyService.nextID
        HotKeyService.nextID &+= 1
        self.hotKeyID = id
    }

    /// Runs on the main actor (isolated deinit) so it can safely touch the actor-isolated
    /// Carbon refs and unregister the hot key before the instance goes away.
    isolated deinit {
        teardown()
    }

    /// Registers the global hot key. Safe to call repeatedly; a no-op when already active.
    /// On failure, ``state`` becomes `.failed(...)` and the returned Result carries the error.
    @discardableResult
    public func start() -> Result<Void, HotKeyServiceError> {
        if case .active = state { return .success(()) }

        // Ensure a clean slate before attempting registration.
        teardown()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            HotKeyService.eventHandler,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )

        guard installStatus == noErr else {
            let error = HotKeyServiceError.eventHandlerInstallFailed(installStatus)
            eventHandlerRef = nil
            state = .failed(reason: error.description, code: installStatus)
            return .failure(error)
        }

        let eventHotKeyID = EventHotKeyID(signature: signature, id: hotKeyID)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            eventHotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )

        guard registerStatus == noErr, hotKeyRef != nil else {
            let error = HotKeyServiceError.hotKeyRegistrationFailed(registerStatus)
            // Roll back the installed handler so we do not leak it on failure.
            teardown()
            state = .failed(reason: error.description, code: registerStatus)
            return .failure(error)
        }

        HotKeyService.registry[hotKeyID] = self
        state = .active
        return .success(())
    }

    /// Unregisters the hot key and removes the event handler. Safe to call repeatedly.
    public func stop() {
        teardown()
        state = .inactive
    }

    /// Routes a matching hot key press to ``onTrigger``. Called from the Carbon callback.
    fileprivate func handleHotKeyPressed() {
        onTrigger?()
    }

    private func teardown() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        HotKeyService.registry[hotKeyID] = nil
    }

    /// C-compatible Carbon callback. Extracts the hot key id and dispatches to the owning
    /// instance on the main actor.
    private static let eventHandler: EventHandlerUPP = { _, eventRef, _ -> OSStatus in
        guard let eventRef else { return OSStatus(eventNotHandledErr) }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr else { return status }

        let id = hotKeyID.id
        // Hop explicitly to the main actor for the registry lookup and the user handler.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                HotKeyService.registry[id]?.handleHotKeyPressed()
            }
        }
        return noErr
    }

    private static func fourCharCode(_ string: String) -> FourCharCode {
        var result: FourCharCode = 0
        for scalar in string.unicodeScalars.prefix(4) {
            result = (result << 8) + FourCharCode(scalar.value & 0xFF)
        }
        return result
    }
}

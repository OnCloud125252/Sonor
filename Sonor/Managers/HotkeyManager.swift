import Foundation
import AppKit
import AVFoundation
import os

/// Owns one event tap and the thread that runs its run loop.
///
/// The previous code stored the tap, run loop and source as plain fields on the manager and
/// started the thread without waiting. `startListening()` calls `stopListening()` first, so a
/// thread that had not been scheduled yet would wake up and call `CGEvent.tapEnable` on a mach
/// port that was already invalidated, which crashes with SIGSEGV inside SLEventTapEnable.
/// Keeping the state per session, and waiting for the thread to come up and go down, makes the
/// tap thread unable to outlive its own tap.
private final class EventTapSession {
    let tap: CFMachPort
    private let readySignal = DispatchSemaphore(value: 0)
    private let finishedSignal = DispatchSemaphore(value: 0)
    private var runLoop: CFRunLoop?
    private var runLoopSource: CFRunLoopSource?

    init(tap: CFMachPort) {
        self.tap = tap
    }

    func start() {
        let thread = Thread { [self] in
            let currentRunLoop = CFRunLoopGetCurrent()
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            runLoop = currentRunLoop
            runLoopSource = source
            if let source = source {
                CFRunLoopAddSource(currentRunLoop, source, .defaultMode)
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            // Signalled only after the fields above are stored, so `stop()` always sees them.
            readySignal.signal()
            if source != nil {
                CFRunLoopRun()
            }
            finishedSignal.signal()
        }
        thread.name = "SonorCGEventTapThread"
        thread.start()
        _ = readySignal.wait(timeout: .now() + 5.0)
    }

    func stop() {
        if let runLoop = runLoop, let source = runLoopSource {
            CFRunLoopRemoveSource(runLoop, source, .defaultMode)
            CFRunLoopStop(runLoop)
            _ = finishedSignal.wait(timeout: .now() + 5.0)
        }
        // Invalidated only once the thread has left its run loop, so nothing touches a dead port.
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
    }
}

/// One immutable snapshot of every configured shortcut.
/// Publishing the five shortcuts as separate fields let the tap thread read a half-updated set
/// while the settings screen rewrote them.
private struct HotkeyConfiguration {
    let main: HotkeyManager.HotkeyDef
    let cancel: HotkeyManager.HotkeyDef
    let pause: HotkeyManager.HotkeyDef
    let assistant: HotkeyManager.HotkeyDef
    let paste: HotkeyManager.HotkeyDef
    let skipRefine: HotkeyManager.HotkeyDef
    let mode: String
}


func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let result = HotkeyManager.shared.handleEvent(type: type, event: event)
    return result
}

class HotkeyManager {
    static let shared = HotkeyManager()
    var onHotkeyDown: ((Date) -> Void)?
    var onHotkeyUp: ((Date) -> Void)?
    var onCancelKeyDown: (() -> Void)?
    var onPauseKeyDown: (() -> Void)?
    var onAssistantKeyDown: (() -> Void)?
    var onPasteKeyDown: (() -> Void)?
    var onSkipRefineKeyDown: (() -> Void)?
    private let session = OSAllocatedUnfairLock<EventTapSession?>(initialState: nil)
    private let configuration = OSAllocatedUnfairLock<HotkeyConfiguration?>(initialState: nil)
    private var isKeyDown = false
    private var isCancelKeyDown = false
    private var isPauseKeyDown = false
    private var isAssistantKeyDown = false
    private var isPasteKeyDown = false
    private var isSkipRefineKeyDown = false
    private var activeIsHoldMode = false
    private var modifierOnlyHotkeyAborted = false
    private var capturedKeys: Set<Int> = []
    private var hasNotifiedMissingPermissions = false

    /// The recorder only stores Command, Shift, Option and Control, so only those are compared.
    /// Matching against every device-independent flag broke shortcuts that carry extra bits:
    /// function keys and arrow keys always report `.function`, and Caps Lock reports
    /// `.capsLock`, so an exact comparison could never succeed for them.
    static let recognizedModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    /// Keys that never produce a character. Binding one of these on its own is safe at any
    /// time, because swallowing it cannot stop the user from typing.
    static let nonTypingKeyCodes: Set<Int> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,  // F1 to F12
        105, 107, 113, 106, 64, 79, 80, 90,                      // F13 to F20
        123, 124, 125, 126,                                      // arrows
        115, 116, 119, 121,                                      // home, page up, end, page down
        114, 110, 63                                             // help, menu, fn
    ]

    /// A shortcut with no modifier that also types a character can only be safe while a
    /// dictation is in flight. At any other time the tap must let that key through.
    ///
    /// A dictation is in flight while the microphone runs and while the assistant rewrites the
    /// words after it. The rewrite has its own shortcut, so it has to arm bare keys too.
    private let dictationActive = OSAllocatedUnfairLock(initialState: false)

    func setDictationActive(_ active: Bool) {
        dictationActive.withLock { $0 = active }
    }
    
    private init() {
        self.checkPermissions()
        
        // Instead of polling every 2 seconds and locking up macOS TCCD (which lags the global keyboard),
        // we check permissions automatically whenever the app becomes active (gains focus).
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }
    
    @objc private func appDidBecomeActive(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           app.processIdentifier == NSRunningApplication.current.processIdentifier {
            self.checkPermissions()
        }
    }
    
    func checkPermissions() {
        let trusted = AXIsProcessTrusted()
        let hasMic = (AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
        let activeTap = session.withLock { $0?.tap }
        
        let allGranted = trusted && hasMic
        
        if allGranted {
            self.hasNotifiedMissingPermissions = false
            if activeTap == nil {
                self.startListening()
            } else if let tap = activeTap, !CGEvent.tapIsEnabled(tap: tap) {
                self.startListening()
            }
        } else {
            if activeTap != nil {
                self.stopListening()
            }
            
            
            if !self.hasNotifiedMissingPermissions {
                self.hasNotifiedMissingPermissions = true
                NotificationCenter.default.post(name: Notification.Name("PermissionsRevoked"), object: nil)
                
                DispatchQueue.main.async {
                    if !trusted {
                        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                        let _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
                    }
                    WindowManager.shared.openPermissionsWindow()
                }
            }
        }
    }
    
    func startListening() {
        self.stopListening()
        
        guard AXIsProcessTrusted() else {
            return
        }
        
        let snapshot = HotkeyConfiguration(
            main: HotkeyDef(.main),
            cancel: HotkeyDef(.cancel),
            pause: HotkeyDef(.pause),
            assistant: HotkeyDef(.assistant),
            paste: HotkeyDef(.paste),
            skipRefine: HotkeyDef(.skipRefine),
            mode: UserDefaults.standard.string(forKey: "hotkeyMode") ?? "Click"
        )
        configuration.withLock { $0 = snapshot }
        
        let eventMask = CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue))
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: nil
        ) else {
            return
        }

        let newSession = EventTapSession(tap: tap)
        session.withLock { $0 = newSession }
        newSession.start()
    }
    
    func stopListening() {
        let previous = session.withLock { current -> EventTapSession? in
            let existing = current
            current = nil
            return existing
        }
        previous?.stop()
    }
    
    struct HotkeyDef {
        let code: Int
        let modifiers: Int
        let targetModifiers: NSEvent.ModifierFlags
        let isOnlyModifier: Bool
        let stringKey: String?
        init(keyCodeKey: String, modifiersKey: String, stringKey: String? = nil, defaultCode: Int? = nil, defaultModifiers: Int? = nil) {
            self.stringKey = stringKey
            var userCode = UserDefaults.standard.object(forKey: keyCodeKey) as? Int
            if let sk = stringKey, UserDefaults.standard.string(forKey: sk) == "None" {
                userCode = -1
            }
            let userMods = UserDefaults.standard.object(forKey: modifiersKey) as? Int
            let finalCode = userCode ?? defaultCode ?? -1
            let finalMods = userMods ?? defaultModifiers ?? 0
            self.code = finalCode
            self.modifiers = finalMods
            var tm = NSEvent.ModifierFlags()
            if (finalMods & 0x0100) != 0 { tm.insert(.command) }
            if (finalMods & 0x0200) != 0 { tm.insert(.shift) }
            if (finalMods & 0x0800) != 0 { tm.insert(.option) }
            if (finalMods & 0x1000) != 0 { tm.insert(.control) }
            self.targetModifiers = tm
            self.isOnlyModifier = (finalCode >= 54 && finalCode <= 63)
        }

        /// Reads the shortcut the user saved for this action, or the one it ships with.
        init(_ type: RecordingHotkeyType) {
            self.init(
                keyCodeKey: type.keyCodeDefaultsKey,
                modifiersKey: type.modifiersDefaultsKey,
                stringKey: type.displayStringDefaultsKey,
                defaultCode: type.defaultKeyCode,
                defaultModifiers: type.defaultModifiers
            )
        }
    }
    
    func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passthrough = Unmanaged.passUnretained(event)
        
        // macOS disables a slow or interrupted tap and never re-enables it on its own.
        // Without this the hotkey stays dead until the app is focused again.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = session.withLock({ $0?.tap }) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return passthrough
        }

        // Reading the fields straight off the CGEvent avoids bridging an NSEvent for every
        // keystroke typed anywhere in the system, which this tap sees.
        let eventKeyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let eventModifiers = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            .intersection(HotkeyManager.recognizedModifiers)
        
        // One consistent snapshot per event, so a settings change cannot be seen half applied.
        guard let config = configuration.withLock({ $0 }) else {
            return passthrough
        }
        let mainHotkey = config.main
        let cancelHotkey = config.cancel
        let pauseHotkey = config.pause
        let assistantHotkey = config.assistant
        let pasteHotkey = config.paste
        let skipRefineHotkey = config.skipRefine

        if !self.isKeyDown {
            self.activeIsHoldMode = (config.mode == "Hold" || config.mode == "Automatic")
        }
        let isHoldMode = self.activeIsHoldMode
        
        var ignoredModifiers = NSEvent.ModifierFlags()
        if self.isKeyDown {
            if mainHotkey.isOnlyModifier {
                var mainTriggerFlag = NSEvent.ModifierFlags()
                switch mainHotkey.code {
                case 54, 55: mainTriggerFlag = .command
                case 56, 60: mainTriggerFlag = .shift
                case 58, 61: mainTriggerFlag = .option
                case 59, 62: mainTriggerFlag = .control
                default: break
                }
                ignoredModifiers = mainHotkey.targetModifiers.union(mainTriggerFlag)
            } else {
                ignoredModifiers = mainHotkey.targetModifiers
            }
        }
        
        func modifiersMatch(_ target: NSEvent.ModifierFlags, current: NSEvent.ModifierFlags) -> Bool {
            let extra = current.subtracting(target)
            return extra.isSubset(of: ignoredModifiers) && target.isSubset(of: current)
        }

        let isDictationActive = self.dictationActive.withLock { $0 }
        /// A bare character key is claimed only while a dictation is in flight. Claiming it all
        /// the time would swallow that character everywhere in the system.
        func isArmed(_ hotkey: HotkeyDef) -> Bool {
            if !hotkey.targetModifiers.isEmpty { return true }
            if HotkeyManager.nonTypingKeyCodes.contains(hotkey.code) { return true }
            return isDictationActive
        }
        
        if type == .flagsChanged {
            let code = eventKeyCode
            let modifiers = eventModifiers
            
            var changedFlag: NSEvent.ModifierFlags?
            switch code {
            case 54, 55: changedFlag = .command
            case 56, 60: changedFlag = .shift
            case 58, 61: changedFlag = .option
            case 59, 62: changedFlag = .control
            default: break
            }
            
            var isPressed = false
            if let flag = changedFlag {
                isPressed = modifiers.contains(flag)
            }
            
            // Main Hotkey
            if mainHotkey.isOnlyModifier {
                var mainTriggerFlag = NSEvent.ModifierFlags()
                switch mainHotkey.code {
                case 54, 55: mainTriggerFlag = .command
                case 56, 60: mainTriggerFlag = .shift
                case 58, 61: mainTriggerFlag = .option
                case 59, 62: mainTriggerFlag = .control
                default: break
                }
                
                if self.isKeyDown && isPressed && code != mainHotkey.code && (changedFlag == nil || !mainHotkey.targetModifiers.contains(changedFlag!)) {
                    self.modifierOnlyHotkeyAborted = true
                }
                
                if code == mainHotkey.code && isPressed {
                    let activeOthers = modifiers.subtracting(mainTriggerFlag)
                    if activeOthers == mainHotkey.targetModifiers {
                        if !self.isKeyDown {
                            self.isKeyDown = true
                            self.modifierOnlyHotkeyAborted = false
                            if isHoldMode {
                                let eventTime = Date()
                                DispatchQueue.main.async { self.onHotkeyDown?(eventTime) }
                            }
                        }
                    }
                } else if !isPressed && self.isKeyDown {
                    let releasedTrigger = (code == mainHotkey.code)
                    let releasedOtherRequired = (changedFlag != nil && mainHotkey.targetModifiers.contains(changedFlag!))
                    if releasedTrigger || releasedOtherRequired {
                        self.isKeyDown = false
                        let eventTime = Date()
                        if isHoldMode {
                            DispatchQueue.main.async { self.onHotkeyUp?(eventTime) }
                        } else {
                            if !self.modifierOnlyHotkeyAborted {
                                DispatchQueue.main.async { self.onHotkeyDown?(eventTime) }
                            }
                        }
                    }
                }
            }
            
            // Cancel Hotkey
            if cancelHotkey.isOnlyModifier {
                var cancelTriggerFlag = NSEvent.ModifierFlags()
                switch cancelHotkey.code {
                case 54, 55: cancelTriggerFlag = .command
                case 56, 60: cancelTriggerFlag = .shift
                case 58, 61: cancelTriggerFlag = .option
                case 59, 62: cancelTriggerFlag = .control
                default: break
                }
                
                if self.isCancelKeyDown && isPressed && code != cancelHotkey.code && (changedFlag == nil || !cancelHotkey.targetModifiers.contains(changedFlag!)) {
                    self.modifierOnlyHotkeyAborted = true
                }
                
                if code == cancelHotkey.code && isPressed {
                    let activeOthers = modifiers.subtracting(cancelTriggerFlag)
                    if modifiersMatch(cancelHotkey.targetModifiers, current: activeOthers) {
                        if !self.isCancelKeyDown {
                            self.isCancelKeyDown = true
                            self.modifierOnlyHotkeyAborted = false
                        }
                    }
                } else if !isPressed && self.isCancelKeyDown {
                    let releasedTrigger = (code == cancelHotkey.code)
                    let releasedOtherRequired = (changedFlag != nil && cancelHotkey.targetModifiers.contains(changedFlag!))
                    if releasedTrigger || releasedOtherRequired {
                        self.isCancelKeyDown = false
                        if !self.modifierOnlyHotkeyAborted {
                            DispatchQueue.main.async { self.onCancelKeyDown?() }
                        }
                    }
                }
            }
            
            // Pause Hotkey
            if pauseHotkey.isOnlyModifier {
                var pauseTriggerFlag = NSEvent.ModifierFlags()
                switch pauseHotkey.code {
                case 54, 55: pauseTriggerFlag = .command
                case 56, 60: pauseTriggerFlag = .shift
                case 58, 61: pauseTriggerFlag = .option
                case 59, 62: pauseTriggerFlag = .control
                default: break
                }
                
                if self.isPauseKeyDown && isPressed && code != pauseHotkey.code && (changedFlag == nil || !pauseHotkey.targetModifiers.contains(changedFlag!)) {
                    self.modifierOnlyHotkeyAborted = true
                }
                
                if code == pauseHotkey.code && isPressed {
                    let activeOthers = modifiers.subtracting(pauseTriggerFlag)
                    if modifiersMatch(pauseHotkey.targetModifiers, current: activeOthers) {
                        if !self.isPauseKeyDown {
                            self.isPauseKeyDown = true
                            self.modifierOnlyHotkeyAborted = false
                        }
                    }
                } else if !isPressed && self.isPauseKeyDown {
                    let releasedTrigger = (code == pauseHotkey.code)
                    let releasedOtherRequired = (changedFlag != nil && pauseHotkey.targetModifiers.contains(changedFlag!))
                    if releasedTrigger || releasedOtherRequired {
                        self.isPauseKeyDown = false
                        if !self.modifierOnlyHotkeyAborted {
                            DispatchQueue.main.async { self.onPauseKeyDown?() }
                        }
                    }
                }
            }
            
            // Assistant Hotkey
            if assistantHotkey.isOnlyModifier {
                var assistantTriggerFlag = NSEvent.ModifierFlags()
                switch assistantHotkey.code {
                case 54, 55: assistantTriggerFlag = .command
                case 56, 60: assistantTriggerFlag = .shift
                case 58, 61: assistantTriggerFlag = .option
                case 59, 62: assistantTriggerFlag = .control
                default: break
                }
                
                if self.isAssistantKeyDown && isPressed && code != assistantHotkey.code && (changedFlag == nil || !assistantHotkey.targetModifiers.contains(changedFlag!)) {
                    self.modifierOnlyHotkeyAborted = true
                }
                
                if code == assistantHotkey.code && isPressed {
                    let activeOthers = modifiers.subtracting(assistantTriggerFlag)
                    if modifiersMatch(assistantHotkey.targetModifiers, current: activeOthers) {
                        if !self.isAssistantKeyDown {
                            self.isAssistantKeyDown = true
                            self.modifierOnlyHotkeyAborted = false
                        }
                    }
                } else if !isPressed && self.isAssistantKeyDown {
                    let releasedTrigger = (code == assistantHotkey.code)
                    let releasedOtherRequired = (changedFlag != nil && assistantHotkey.targetModifiers.contains(changedFlag!))
                    if releasedTrigger || releasedOtherRequired {
                        self.isAssistantKeyDown = false
                        if !self.modifierOnlyHotkeyAborted {
                            DispatchQueue.main.async { self.onAssistantKeyDown?() }
                        }
                    }
                }
            }

            // Paste Hotkey
            if pasteHotkey.isOnlyModifier {
                var pasteTriggerFlag = NSEvent.ModifierFlags()
                switch pasteHotkey.code {
                case 54, 55: pasteTriggerFlag = .command
                case 56, 60: pasteTriggerFlag = .shift
                case 58, 61: pasteTriggerFlag = .option
                case 59, 62: pasteTriggerFlag = .control
                default: break
                }
                
                if self.isPasteKeyDown && isPressed && code != pasteHotkey.code && (changedFlag == nil || !pasteHotkey.targetModifiers.contains(changedFlag!)) {
                    self.modifierOnlyHotkeyAborted = true
                }
                
                if code == pasteHotkey.code && isPressed {
                    let activeOthers = modifiers.subtracting(pasteTriggerFlag)
                    if modifiersMatch(pasteHotkey.targetModifiers, current: activeOthers) {
                        if !self.isPasteKeyDown {
                            self.isPasteKeyDown = true
                            self.modifierOnlyHotkeyAborted = false
                        }
                    }
                } else if !isPressed && self.isPasteKeyDown {
                    let releasedTrigger = (code == pasteHotkey.code)
                    let releasedOtherRequired = (changedFlag != nil && pasteHotkey.targetModifiers.contains(changedFlag!))
                    if releasedTrigger || releasedOtherRequired {
                        self.isPasteKeyDown = false
                        if !self.modifierOnlyHotkeyAborted {
                            DispatchQueue.main.async { self.onPasteKeyDown?() }
                        }
                    }
                }
            }

            // Skip Refine Hotkey
            if skipRefineHotkey.isOnlyModifier {
                var skipRefineTriggerFlag = NSEvent.ModifierFlags()
                switch skipRefineHotkey.code {
                case 54, 55: skipRefineTriggerFlag = .command
                case 56, 60: skipRefineTriggerFlag = .shift
                case 58, 61: skipRefineTriggerFlag = .option
                case 59, 62: skipRefineTriggerFlag = .control
                default: break
                }

                if self.isSkipRefineKeyDown && isPressed && code != skipRefineHotkey.code && (changedFlag == nil || !skipRefineHotkey.targetModifiers.contains(changedFlag!)) {
                    self.modifierOnlyHotkeyAborted = true
                }

                if code == skipRefineHotkey.code && isPressed {
                    let activeOthers = modifiers.subtracting(skipRefineTriggerFlag)
                    if modifiersMatch(skipRefineHotkey.targetModifiers, current: activeOthers) {
                        if !self.isSkipRefineKeyDown {
                            self.isSkipRefineKeyDown = true
                            self.modifierOnlyHotkeyAborted = false
                        }
                    }
                } else if !isPressed && self.isSkipRefineKeyDown {
                    let releasedTrigger = (code == skipRefineHotkey.code)
                    let releasedOtherRequired = (changedFlag != nil && skipRefineHotkey.targetModifiers.contains(changedFlag!))
                    if releasedTrigger || releasedOtherRequired {
                        self.isSkipRefineKeyDown = false
                        if !self.modifierOnlyHotkeyAborted {
                            DispatchQueue.main.async { self.onSkipRefineKeyDown?() }
                        }
                    }
                }
            }
            
            return passthrough
        }
        
        if type == .keyDown {
            let code = eventKeyCode
            
            if self.isKeyDown && mainHotkey.isOnlyModifier {
                self.modifierOnlyHotkeyAborted = true
            }
            if self.isCancelKeyDown && cancelHotkey.isOnlyModifier {
                self.modifierOnlyHotkeyAborted = true
            }
            if self.isPauseKeyDown && pauseHotkey.isOnlyModifier {
                self.modifierOnlyHotkeyAborted = true
            }
            if self.isAssistantKeyDown && assistantHotkey.isOnlyModifier {
                self.modifierOnlyHotkeyAborted = true
            }
            if self.isPasteKeyDown && pasteHotkey.isOnlyModifier {
                self.modifierOnlyHotkeyAborted = true
            }
            if self.isSkipRefineKeyDown && skipRefineHotkey.isOnlyModifier {
                self.modifierOnlyHotkeyAborted = true
            }
            
            let modifiers = eventModifiers
            if !mainHotkey.isOnlyModifier && code == mainHotkey.code && modifiers == mainHotkey.targetModifiers && isArmed(mainHotkey) {
                if !isKeyDown {
                    isKeyDown = true
                    let eventTime = Date()
                    DispatchQueue.main.async { self.onHotkeyDown?(eventTime) }
                }
                capturedKeys.insert(code)
                return nil
            }
            
            if !cancelHotkey.isOnlyModifier && code == cancelHotkey.code && modifiersMatch(cancelHotkey.targetModifiers, current: modifiers) && isArmed(cancelHotkey) {
                DispatchQueue.main.async { self.onCancelKeyDown?() }
                capturedKeys.insert(code)
                return nil
            }
            if !pauseHotkey.isOnlyModifier && code == pauseHotkey.code && modifiersMatch(pauseHotkey.targetModifiers, current: modifiers) && isArmed(pauseHotkey) {
                DispatchQueue.main.async { self.onPauseKeyDown?() }
                capturedKeys.insert(code)
                return nil
            }
            if !assistantHotkey.isOnlyModifier && code == assistantHotkey.code && modifiersMatch(assistantHotkey.targetModifiers, current: modifiers) && isArmed(assistantHotkey) {
                DispatchQueue.main.async { self.onAssistantKeyDown?() }
                capturedKeys.insert(code)
                return nil
            }
            if !pasteHotkey.isOnlyModifier && code == pasteHotkey.code && modifiersMatch(pasteHotkey.targetModifiers, current: modifiers) && isArmed(pasteHotkey) {
                DispatchQueue.main.async { self.onPasteKeyDown?() }
                capturedKeys.insert(code)
                return nil
            }
            if !skipRefineHotkey.isOnlyModifier && code == skipRefineHotkey.code && modifiersMatch(skipRefineHotkey.targetModifiers, current: modifiers) && isArmed(skipRefineHotkey) {
                DispatchQueue.main.async { self.onSkipRefineKeyDown?() }
                capturedKeys.insert(code)
                return nil
            }
            return passthrough
        } else if type == .keyUp {
            let code = eventKeyCode
            if capturedKeys.contains(code) {
                capturedKeys.remove(code)
                if !mainHotkey.isOnlyModifier && code == mainHotkey.code {
                    if isKeyDown {
                        isKeyDown = false
                        if isHoldMode {
                            let eventTime = Date()
                            DispatchQueue.main.async { self.onHotkeyUp?(eventTime) }
                        }
                    }
                }
                return nil
            }
            return passthrough
        }
        
        return passthrough
    }
}

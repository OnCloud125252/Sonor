import Foundation
import AppKit
import ApplicationServices

class PasteManager {
    static let shared = PasteManager()
    private init() {}




    /// The Accessibility API returns an untyped CFTypeRef. A forced cast traps when an app
    /// hands back anything other than an AXUIElement, so the type is checked at runtime.
    private func asAXUIElement(_ value: AnyObject?) -> AXUIElement? {
        guard let value = value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func getFocusedAXElement(pid: pid_t) -> AXUIElement? {
        guard AXIsProcessTrusted() else {
            return nil
        }
        let appElement = AXUIElementCreateApplication(pid)
        var focusedElement: AnyObject?
        var focusResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        if focusResult == .success, let element = asAXUIElement(focusedElement) {
            return element
        }
        var focusedWindow: AnyObject?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
           let windowElement = asAXUIElement(focusedWindow) {
            focusResult = AXUIElementCopyAttributeValue(windowElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
            if focusResult == .success, let element = asAXUIElement(focusedElement) {
                return element
            }
        }
        var windowsList: AnyObject?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsList) == .success,
           let windows = windowsList as? [AXUIElement], let firstWindow = windows.first {
            focusResult = AXUIElementCopyAttributeValue(firstWindow, kAXFocusedUIElementAttribute as CFString, &focusedElement)
            if focusResult == .success, let element = asAXUIElement(focusedElement) {
                return element
            }
        }
        return nil
    }

    func isElementTextField(_ axElement: AXUIElement?) -> Bool {
        guard let element = axElement else { 
            return true 
        }
        
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String {
            // Twarde odrzucenie niemodyfikowalnych ról UI
            let invalidRoles = [
                "AXButton", "AXImage", "AXStaticText", "AXMenu", "AXMenuItem", "AXMenuBar", "AXMenuBarItem",
                "AXToolbar", "AXWindow", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXSlider",
                "AXTabGroup", "AXTable", "AXRow", "AXColumn", "AXCell", "AXList", "AXOutline", "AXBrowser",
                "AXScrollArea", "AXScrollBar", "AXSplitGroup", "AXValueIndicator", "AXColorWell", "AXSortButton",
                "AXLink", "AXHeading", "AXListMarker", "AXGroup"
            ]
            if invalidRoles.contains(role) {
                return false
            }
        }
        
        var isEditable: Bool? = nil
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success {
            isEditable = settable.boolValue
        }
        
        if let editable = isEditable, editable == false {
            return false
        }
        
        return true
    }

    func isTextFieldFocused(pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return true } 
        let element = getFocusedAXElement(pid: pid)
        
        if element == nil {
            if let app = NSRunningApplication(processIdentifier: pid),
               let bundleID = app.bundleIdentifier {
                if bundleID == "com.apple.finder" || bundleID == "com.apple.dock" {
                    return false
                }
            }
        }
        
        return isElementTextField(element)
    }

    func typeTextDirectly(text: String, targetPID: pid_t, forceFocusElement: AXUIElement? = nil) {
        guard AXIsProcessTrusted() else {
            return
        }
        guard targetPID > 0 else {
            return
        }

        guard let targetApp = NSRunningApplication(processIdentifier: targetPID) else {
            return
        }

        targetApp.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])

        var attempts = 0
        while !targetApp.isActive && attempts < 30 {
            Thread.sleep(forTimeInterval: 0.05)
            attempts += 1
        }
        Thread.sleep(forTimeInterval: 0.1)
        if let element = forceFocusElement {
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, true as CFTypeRef)
            Thread.sleep(forTimeInterval: 0.05)
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        
        let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        event?.flags = []
        let utf16Chars = Array(text.utf16)
        utf16Chars.withUnsafeBufferPointer { buffer in
            if let ptr = buffer.baseAddress {
                event?.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: ptr)
            }
        }
        event?.post(tap: .cghidEventTap)
    }


    func simulatePostPasteAction(action: String, targetPID: pid_t) {
        guard AXIsProcessTrusted(), targetPID > 0 else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        
        let virtualKey: CGKeyCode = 0x24 // Return
        
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        
        switch action {
        case "return":
            break
        case "shiftReturn":
            keyDown?.flags = .maskShift
            keyUp?.flags = .maskShift
        case "commandReturn":
            keyDown?.flags = .maskCommand
            keyUp?.flags = .maskCommand
        case "optionReturn":
            keyDown?.flags = .maskAlternate
            keyUp?.flags = .maskAlternate
        default:
            return
        }
        
        keyDown?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.02)
        keyUp?.post(tap: .cghidEventTap)
    }

    func printDiagnosticLog(phase: String, pid: pid_t, element: AXUIElement?) {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            print("[\(phase)] ❌ Błąd: Nie znaleziono aplikacji dla PID \(pid)")
            return
        }
        let appName = app.localizedName ?? "Nieznana"
        let isActive = app.isActive
        
        print("[\(phase)] =========================================")
        print("[\(phase)] 📱 Aplikacja: \(appName) (PID: \(pid)) - Aktywna: \(isActive)")
        
        if let el = element {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
            var description: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleDescriptionAttribute as CFString, &description)
            
            let qualifiesAsTextField = isElementTextField(el)
            let emoji = qualifiesAsTextField ? "✅" : "❌"
            
            print("[\(phase)] \(emoji) Kursor spoczywa na elemencie. Rola: \(role as? String ?? "Brak"), Opis: \(description as? String ?? "Brak")")
            print("[\(phase)] Czy system sklasyfikował ten element jako POLE TEKSTOWE DO PISANIA? -> \(qualifiesAsTextField)")
        } else {
            print("[\(phase)] ⚠️ Element (Pole): NIE WYKRYTO (nil).")
        }
        print("[\(phase)] =========================================")
    }
}

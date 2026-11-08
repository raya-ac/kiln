import AppKit
import ApplicationServices
import ScreenCaptureKit

@MainActor
enum ComputerPlatform {
    static var screenAllowed: Bool { CGPreflightScreenCaptureAccess() }
    static var inputAllowed: Bool { AXIsProcessTrusted() }

    static func targets() async throws -> [ComputerTarget] {
        guard screenAllowed else { throw ComputerUseError.permissions }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let blocked = ["com.apple.systempreferences", "com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.CoreServicesUIAgent"]
        return content.windows.compactMap { window in
            guard let app = window.owningApplication, app.processID != ProcessInfo.processInfo.processIdentifier,
                  !blocked.contains(app.bundleIdentifier), window.windowLayer == 0,
                  window.frame.width >= 100, window.frame.height >= 80 else { return nil }
            return ComputerTarget(id: window.windowID, pid: app.processID, app: app.applicationName,
                title: window.title ?? "", frame: window.frame)
        }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    static func capture(_ target: ComputerTarget) async throws -> ComputerCapture {
        guard screenAllowed else { throw ComputerUseError.permissions }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == target.id && $0.owningApplication?.processID == target.pid }) else {
            throw ComputerUseError.targetGone
        }
        let scale = min(1, 1280 / window.frame.width, 960 / window.frame.height)
        let config = SCStreamConfiguration()
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = true
        config.ignoreShadowsSingleWindow = true
        if #available(macOS 14.2, *) { config.includeChildWindows = false }
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8]),
              data.count <= 4 * 1024 * 1024 else { throw ComputerUseError.invalidAction }
        let current = ComputerTarget(id: target.id, pid: target.pid, app: target.app, title: window.title ?? "", frame: window.frame)
        return ComputerCapture(id: UUID().uuidString, target: current, width: image.width, height: image.height, timestamp: .now, jpeg: data)
    }

    static func current(_ target: ComputerTarget) throws -> ComputerTarget {
        guard let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
              let window = windows.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == target.id }),
              window[kCGWindowOwnerPID as String] as? Int32 == target.pid,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              frame.width > 0, frame.height > 0 else { throw ComputerUseError.targetGone }
        let current = ComputerTarget(id: target.id, pid: target.pid, app: target.app, title: target.title, frame: frame)
        let candidates: [ComputerTarget] = windows.compactMap { row in
            guard let pid = row[kCGWindowOwnerPID as String] as? Int32, pid == target.pid,
                  row[kCGWindowLayer as String] as? Int == 0,
                  let id = row[kCGWindowNumber as String] as? UInt32,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return ComputerTarget(id: id, pid: pid, app: target.app, title: "", frame: frame)
        }
        guard current.uniquelyIdentifies(candidates) else { throw ComputerUseError.targetGone }
        return current
    }

    static func perform(_ action: ComputerAction, capture: ComputerCapture, isActive: @MainActor () -> Bool) async throws {
        guard isActive() else { throw ComputerUseError.inactive }
        guard inputAllowed, screenAllowed else { throw ComputerUseError.permissions }
        let target = try current(capture.target)
        let point = try capture.point(x: action.x, y: action.y, current: target)
        let app = AXUIElementCreateApplication(target.pid)
        let element = try focusWindow(app: app, target: target)
        guard NSRunningApplication(processIdentifier: target.pid)?.activate(options: []) == true else {
            throw ComputerUseError.targetGone
        }
        AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, element)
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid { break }
            try await Task.sleep(for: .milliseconds(25))
            guard isActive() else { throw ComputerUseError.inactive }
        }
        guard isActive() else { throw ComputerUseError.inactive }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else { throw ComputerUseError.targetGone }
        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
              let focusedWindow, CFEqual(focusedWindow, element) else { throw ComputerUseError.targetGone }
        _ = try capture.point(x: action.x, y: action.y, current: current(target))
        let source = CGEventSource(stateID: .combinedSessionState)
        func validateDispatch() throws {
            guard isActive() else { throw ComputerUseError.inactive }
            guard inputAllowed, screenAllowed else { throw ComputerUseError.permissions }
        }
        func key(_ code: CGKeyCode, flags: CGEventFlags = []) throws {
            try validateDispatch()
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
                event?.flags = flags
                event?.postToPid(target.pid)
            }
        }
        switch action.kind {
        case .click:
            try validatePointer(point, target: target, window: element)
            try validateDispatch()
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.postToPid(target.pid)
            }
        case .type_text:
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                  let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { throw ComputerUseError.secureField }
            let input = unsafeBitCast(focused, to: AXUIElement.self)
            var inputWindow: CFTypeRef?
            guard AXUIElementCopyAttributeValue(input, kAXWindowAttribute as CFString, &inputWindow) == .success,
                  let inputWindow, CFEqual(inputWindow, element) else { throw ComputerUseError.secureField }
            let role = string(input, kAXRoleAttribute)
            guard ["AXTextField", "AXTextArea", "AXComboBox"].contains(role),
                  knownNonSecure(input) else { throw ComputerUseError.secureField }
            let units = Array(action.text.utf16)
            var start = 0
            while start < units.count {
                var end = min(start + 20, units.count)
                if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]) { end -= 1 }
                let chunk = Array(units[start..<end])
                try validateDispatch()
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                    chunk.withUnsafeBufferPointer { event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                    event?.postToPid(target.pid)
                }
                start = end
            }
        case .press_key:
            var focused: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
                  let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { throw ComputerUseError.secureField }
            let input = unsafeBitCast(focused, to: AXUIElement.self)
            var inputWindow: CFTypeRef?
            guard knownNonSecure(input),
                  AXUIElementCopyAttributeValue(input, kAXWindowAttribute as CFString, &inputWindow) == .success,
                  let inputWindow, CFEqual(inputWindow, element) else { throw ComputerUseError.secureField }
            let keys: [String: CGKeyCode] = ["Enter": 36, "Escape": 53, "Tab": 48, "Backspace": 51, "Delete": 117,
                "ArrowLeft": 123, "ArrowRight": 124, "ArrowUp": 126, "ArrowDown": 125, "Home": 115, "End": 119,
                "PageUp": 116, "PageDown": 121, "cmd+a": 0, "cmd+f": 3, "cmd+l": 37, "cmd+z": 6, "cmd+shift+z": 6]
            guard let code = keys[action.key] else { throw ComputerUseError.invalidAction }
            var flags: CGEventFlags = action.key.hasPrefix("cmd+") ? [.maskCommand] : []
            if action.key.contains("shift+") { flags.insert(.maskShift) }
            try key(code, flags: flags)
        case .scroll:
            try validatePointer(point, target: target, window: element)
            let vertical = action.direction == "up" ? action.amount : action.direction == "down" ? -action.amount : 0
            let horizontal = action.direction == "left" ? action.amount : action.direction == "right" ? -action.amount : 0
            let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: Int32(vertical), wheel2: Int32(horizontal), wheel3: 0)
            event?.location = point
            try validateDispatch()
            event?.postToPid(target.pid)
        }
    }

    private static func validatePointer(_ point: CGPoint, target: ComputerTarget, window: AXUIElement) throws {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw ComputerUseError.targetGone
        }
        var windows: [ComputerTarget] = []
        for row in rows {
            if let alpha = row[kCGWindowAlpha as String] as? Double, alpha <= 0 { continue }
            guard let id = row[kCGWindowNumber as String] as? UInt32,
                  let pid = row[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { throw ComputerUseError.targetGone }
            windows.append(ComputerTarget(id: id, pid: pid, app: "", title: "", frame: frame))
        }
        guard target.isTopmost(at: point, windowsFrontToBack: windows) else { throw ComputerUseError.targetGone }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              let hit else { throw ComputerUseError.targetGone }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success, pid == target.pid else { throw ComputerUseError.targetGone }
        if CFEqual(hit, window) { return }
        var hitWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(hit, kAXWindowAttribute as CFString, &hitWindow) == .success,
              let hitWindow, CFEqual(hitWindow, window) else { throw ComputerUseError.targetGone }
    }

    private static func focusWindow(app: AXUIElement, target: ComputerTarget) throws -> AXUIElement {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { throw ComputerUseError.targetGone }
        var matches: [AXUIElement] = []
        for window in windows {
            var position: CFTypeRef?
            var size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
                  AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
                  let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { continue }
            var point = CGPoint.zero
            var dimensions = CGSize.zero
            AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point)
            AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions)
            if CGRect(origin: point, size: dimensions) == target.frame,
               target.title.isEmpty || string(window, kAXTitleAttribute) == target.title {
                matches.append(window)
            }
        }
        guard matches.count == 1, let window = matches.first,
              AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else { throw ComputerUseError.targetGone }
        return window
    }

    private static func knownNonSecure(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success,
              let subrole = value as? String, !subrole.isEmpty else { return false }
        return subrole != "AXSecureTextField"
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return value as? String ?? ""
    }
}

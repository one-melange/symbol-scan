import AppKit
import Carbon
import os

class EventTap {
    enum Trigger {
        case at      // @ — Claude Code
        case hash    // # — Codex
        case cmdShiftO

        var prefix: String {
            switch self {
            case .at: return "@"
            case .hash: return "#"
            case .cmdShiftO: return ""
            }
        }
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let onTrigger: (Trigger) -> Void

    init(onTrigger: @escaping (Trigger) -> Void) {
        self.onTrigger = onTrigger
    }

    func start() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        // We need to bridge self into the C callback
        let selfPtr = Unmanaged.passRetained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let eventTap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
                return eventTap.handle(proxy: proxy, type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            Log.input.error("Failed to create CGEventTap. Check Accessibility permissions.")
            return
        }

        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes) }
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .keyDown else { return Unmanaged.passRetained(event) }

        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        let cmd   = flags.contains(.maskCommand)
        let shift = flags.contains(.maskShift)
        let ctrl  = flags.contains(.maskControl)

        // Cmd+Shift+O — IDE-style open symbol picker
        if cmd && shift && keyCode == kVK_ANSI_O {
            DispatchQueue.main.async { self.onTrigger(.cmdShiftO) }
            return nil // suppress
        }

        // Ctrl+@ or just @ typed
        if keyCode == kVK_ANSI_2 && shift && !cmd {
            // @ is shift+2
            DispatchQueue.main.async { self.onTrigger(.at) }
            return Unmanaged.passRetained(event) // let it through so Claude Code sees it
        }

        // Ctrl+# or # typed
        if keyCode == kVK_ANSI_3 && shift && !cmd {
            // # is shift+3
            DispatchQueue.main.async { self.onTrigger(.hash) }
            return Unmanaged.passRetained(event)
        }

        // Ctrl+@ explicit modifier variant
        if ctrl && keyCode == kVK_ANSI_2 {
            DispatchQueue.main.async { self.onTrigger(.at) }
            return nil
        }

        // Ctrl+# explicit modifier variant
        if ctrl && keyCode == kVK_ANSI_3 {
            DispatchQueue.main.async { self.onTrigger(.hash) }
            return nil
        }

        return Unmanaged.passRetained(event)
    }

    deinit { stop() }
}

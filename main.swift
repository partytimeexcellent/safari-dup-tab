// SafariDupTab — in Safari, makes ⌘T duplicate the current tab, placed right next to it.
// Every other app (and every other shortcut) is passed through untouched.
import Cocoa
import ApplicationServices

let safariID = "com.apple.Safari"
let kVK_T: Int64 = 17

let duplicateScript = NSAppleScript(source: """
tell application "Safari"
    if (count of windows) is 0 then
        make new document
        return
    end if
    tell front window
        set i to index of current tab
        set u to URL of current tab
        if u is missing value or u is "" then
            set t to make new tab at after tab i
        else
            set t to make new tab at after tab i with properties {URL:u}
        end if
        set current tab to t
    end tell
end tell
""")!

func duplicateTab() {
    var err: NSDictionary?
    duplicateScript.executeAndReturnError(&err)
    if let err = err { NSLog("SafariDupTab AppleScript error: \(err)") }
}

var tap: CFMachPort?

let callback: CGEventTapCallBack = { _, type, event, _ in
    // macOS disables slow/idle taps; turn it back on.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown,
          event.getIntegerValueField(.keyboardEventKeycode) == kVK_T,
          event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
          NSWorkspace.shared.frontmostApplication?.bundleIdentifier == safariID
    else { return Unmanaged.passUnretained(event) }

    // Exactly ⌘ — no Shift/Option/Control (so ⌘⇧T "reopen closed tab" still works).
    let mods = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
    guard mods == .maskCommand else { return Unmanaged.passUnretained(event) }

    DispatchQueue.main.async { duplicateTab() }
    return nil // swallow the original ⌘T
}

// Accessibility permission is needed to intercept keys. A running process may not see a
// newly granted permission, so if we don't have it, prompt once and exit; launchd
// (KeepAlive) relaunches us every ~10s, and a fresh launch picks up the grant.
if !AXIsProcessTrusted() {
    let defaults = UserDefaults.standard
    if !defaults.bool(forKey: "prompted") {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        defaults.set(true, forKey: "prompted")
    }
    NSLog("SafariDupTab: no Accessibility permission yet (Privacy & Security → Device Control and Data Access); will retry")
    Thread.sleep(forTimeInterval: 5)
    exit(0)
}

guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                options: .defaultTap,
                                eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                                callback: callback, userInfo: nil) else {
    NSLog("SafariDupTab: could not create event tap"); exit(1)
}
tap = t
let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
CGEvent.tapEnable(tap: t, enable: true)
NSLog("SafariDupTab running")

let app = NSApplication.shared
app.setActivationPolicy(.prohibited) // no Dock icon, no menu bar
app.run()

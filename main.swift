// SafariDupTab — in Safari, makes ⌘T duplicate the current tab, placed right next to it.
// Every other app (and every other shortcut) is passed through untouched.
//
// Safety rules (a filtering event tap sits in the path of ALL keyboard input):
//  1. The tap callback never blocks: AppleScript runs on a background queue.
//  2. If Accessibility permission is revoked while running, macOS keeps the tap in place
//     but stops servicing it, which freezes input system-wide. A watchdog checks the
//     permission every second and removes the tap and quits the moment it is gone.
//  3. If macOS disables the tap for being slow, we only re-enable it a few times;
//     after that we quit rather than risk stalling input.
import Cocoa
import ApplicationServices

let safariID = "com.apple.Safari"
let kVK_T: Int64 = 17

// ---- Permission check before doing anything ----
// A running process may not see a newly granted permission, so if we don't have it,
// prompt once and exit; launchd (KeepAlive) relaunches us and a fresh launch sees the grant.
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

// ---- Duplicating the tab (off the main thread) ----
let scriptQueue = DispatchQueue(label: "safariduptab.applescript")
let scriptSource = """
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
"""
var duplicateScript: NSAppleScript? // only touched on scriptQueue
var scriptBusy = false               // only touched on main thread

func duplicateTab() {
    guard !scriptBusy else { return } // drop extra presses while Safari is still working
    scriptBusy = true
    scriptQueue.async {
        if duplicateScript == nil { duplicateScript = NSAppleScript(source: scriptSource) }
        var err: NSDictionary?
        duplicateScript?.executeAndReturnError(&err)
        if let err = err { NSLog("SafariDupTab AppleScript error: \(err)") }
        DispatchQueue.main.async { scriptBusy = false }
    }
}

// ---- Event tap ----
var tap: CFMachPort?
var timeoutCount = 0

func shutDown(_ reason: String) -> Never {
    if let tap = tap {
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
    }
    NSLog("SafariDupTab: \(reason); removed key tap and quitting")
    exit(0)
}

let callback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout {
        timeoutCount += 1
        if timeoutCount > 3 || !AXIsProcessTrusted() {
            DispatchQueue.main.async { shutDown("tap timed out repeatedly or permission lost") }
        } else if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }
    if type == .tapDisabledByUserInput {
        DispatchQueue.main.async { shutDown("tap disabled by the system") }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown,
          event.getIntegerValueField(.keyboardEventKeycode) == kVK_T,
          event.getIntegerValueField(.keyboardEventAutorepeat) == 0
    else { return Unmanaged.passUnretained(event) }

    // Exactly ⌘ — no Shift/Option/Control (so ⌘⇧T "reopen closed tab" still works).
    let mods = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
    guard mods == .maskCommand,
          NSWorkspace.shared.frontmostApplication?.bundleIdentifier == safariID
    else { return Unmanaged.passUnretained(event) }

    DispatchQueue.main.async { duplicateTab() }
    return nil // swallow the original ⌘T
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

// ---- Watchdog: quit the instant permission is revoked ----
let watchdog = Timer(timeInterval: 1.0, repeats: true) { _ in
    if !AXIsProcessTrusted() { shutDown("Accessibility permission was removed") }
}
RunLoop.main.add(watchdog, forMode: .common)

signal(SIGTERM) { _ in exit(0) }
NSLog("SafariDupTab running")

let app = NSApplication.shared
app.setActivationPolicy(.prohibited) // no Dock icon, no menu bar
app.run()

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
//
// Two ways to run:
//  - Homebrew service (launchd, KeepAlive): the formula sets SAFARIDUPTAB_LAUNCHD=1.
//  - Standalone app (downloaded .app, opened by the user, then a login item).
import Cocoa
import ApplicationServices
import ServiceManagement

let safariID = "com.apple.Safari"
let underLaunchd = ProcessInfo.processInfo.environment["SAFARIDUPTAB_LAUNCHD"] == "1"

// Helper mode: a fresh process reports whether the permission is granted. Used because a
// long-running process may not notice a newly granted permission.
if CommandLine.arguments.contains("--check-trust") { exit(AXIsProcessTrusted() ? 0 : 1) }

// ---- Single instance (e.g. Homebrew service and a downloaded copy both installed) ----
let lockPath = NSTemporaryDirectory() + "safari-dup-tab.lock"
let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o600)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    NSLog("SafariDupTab: another copy is already running; exiting")
    if underLaunchd { Thread.sleep(forTimeInterval: 30) } // don't let launchd spin
    exit(0)
}

// ---- Permission check before doing anything ----
func freshProcessIsTrusted() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    p.arguments = ["--check-trust"]
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

func promptForPermission() {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
}

if !AXIsProcessTrusted() {
    NSLog("SafariDupTab: no Accessibility permission yet (Privacy & Security → Device Control and Data Access); will retry")
    if underLaunchd {
        // Prompt once, then exit; launchd relaunches us and a fresh launch sees the grant.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "prompted") { promptForPermission(); defaults.set(true, forKey: "prompted") }
        Thread.sleep(forTimeInterval: 5)
        exit(0)
    }
    // Standalone: prompt, then wait until the permission is granted.
    promptForPermission()
    while true {
        Thread.sleep(forTimeInterval: 3)
        if AXIsProcessTrusted() { break }          // this process sees it: carry on
        if freshProcessIsTrusted() {               // only a fresh process sees it: relaunch
            let sh = Process()
            sh.executableURL = URL(fileURLWithPath: "/bin/sh")
            sh.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
            try? sh.run()
            exit(0)
        }
    }
}

// Standalone: start at login from now on (once; the user can turn it off in Login Items).
if !underLaunchd, #available(macOS 13.0, *) {
    let defaults = UserDefaults.standard
    if !defaults.bool(forKey: "loginItemRegistered") {
        do { try SMAppService.mainApp.register(); defaults.set(true, forKey: "loginItemRegistered") }
        catch { NSLog("SafariDupTab: could not add login item: \(error)") }
    }
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
          event.getIntegerValueField(.keyboardEventAutorepeat) == 0
    else { return Unmanaged.passUnretained(event) }

    // Exactly ⌘ — no Shift/Option/Control (so ⌘⇧T "reopen closed tab" still works).
    let mods = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
    guard mods == .maskCommand else { return Unmanaged.passUnretained(event) }

    // Match the letter the current keyboard layout types with ⌘ held (works for Dvorak,
    // AZERTY, "Dvorak – QWERTY ⌘", etc.), not a fixed physical key.
    guard NSEvent(cgEvent: event)?.characters?.lowercased() == "t",
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

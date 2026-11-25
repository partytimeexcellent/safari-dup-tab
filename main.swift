// SafariDupTab — in Safari, makes ⌘T duplicate the current tab, placed right next to it.
// Every other app (and every other shortcut) is passed through untouched.
//
// SAFETY. A filtering event tap sits in the path of ALL keyboard input, and if macOS stops
// servicing it (for example when its Accessibility permission is removed while it runs),
// input freezes system-wide until the process exits. So:
//  1. The tap runs on its own thread, and its callback does no IPC and never blocks:
//     no permission checks, no NSWorkspace calls, AppleScript on a separate queue.
//  2. A watchdog thread exits the process (which removes the tap) if ANY of these is true:
//     a) AXIsProcessTrusted() says the permission is gone;
//     b) a fresh child process says the permission is gone (the long-running process's
//        answer can be stale after the entry is removed in System Settings);
//     c) the tap is starved: the system saw a key press that never reached our tap;
//     d) a check itself hangs for more than a few seconds (a separate guard thread).
//  3. If macOS disables the tap for being slow, we re-enable it at most 3 times, then exit.
//
// Two ways to run:
//  - Homebrew service (launchd, KeepAlive): the formula sets SAFARIDUPTAB_LAUNCHD=1.
//  - Standalone app (downloaded .app, opened by the user, then a login item).
import Cocoa
import ApplicationServices
import ServiceManagement
import Carbon

let safariID = "com.apple.Safari"
let env = ProcessInfo.processInfo.environment
let underLaunchd = env["SAFARIDUPTAB_LAUNCHD"] == "1"
let debug = env["SAFARIDUPTAB_DEBUG"] == "1"

func log(_ s: String) {
    let ts = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                         formatOptions: [.withFullDate, .withFullTime, .withFractionalSeconds])
    fputs("\(ts) SafariDupTab[\(getpid())]: \(s)\n", stderr)
}

// Helper mode: a fresh process reports whether the permission is granted.
if CommandLine.arguments.contains("--check-trust") { exit(AXIsProcessTrusted() ? 0 : 1) }

// ---- Single instance (e.g. Homebrew service and a downloaded copy both installed) ----
let lockPath = NSTemporaryDirectory() + "safari-dup-tab.lock"
let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o600)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    log("another copy is already running; exiting")
    if underLaunchd { Thread.sleep(forTimeInterval: 30) } // don't let launchd spin
    exit(0)
}

func relaunchSelfSoon() {
    let sh = Process()
    sh.executableURL = URL(fileURLWithPath: "/bin/sh")
    sh.arguments = ["-c", "sleep 2; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
    try? sh.run()
}

/// Runs a fresh copy of ourselves to check the permission. Returns nil if it can't run.
func freshProcessIsTrusted() -> Bool? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    p.arguments = ["--check-trust"]
    guard (try? p.run()) != nil else { return nil }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

// ---- Wait for permission before installing anything ----
if !AXIsProcessTrusted() {
    log("no Accessibility permission yet (Privacy & Security → Device Control and Data Access); will retry")
    let promptOpts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    if underLaunchd {
        // Prompt once, then exit; launchd relaunches us and a fresh launch sees the grant.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "prompted") { _ = AXIsProcessTrustedWithOptions(promptOpts); defaults.set(true, forKey: "prompted") }
        Thread.sleep(forTimeInterval: 5)
        exit(0)
    }
    _ = AXIsProcessTrustedWithOptions(promptOpts)
    while true {
        Thread.sleep(forTimeInterval: 3)
        if AXIsProcessTrusted() { break }
        if freshProcessIsTrusted() == true { relaunchSelfSoon(); exit(0) }
    }
}

// Standalone: start at login from now on (once; the user can turn it off in Login Items).
if !underLaunchd, env["SAFARIDUPTAB_NO_LOGIN_ITEM"] != "1", #available(macOS 13.0, *) {
    let defaults = UserDefaults.standard
    if !defaults.bool(forKey: "loginItemRegistered") {
        do { try SMAppService.mainApp.register(); defaults.set(true, forKey: "loginItemRegistered") }
        catch { log("could not add login item: \(error)") }
    }
}

// ---- Shared state (touched from several threads) ----
final class Shared: @unchecked Sendable {
    private let lock = NSLock()
    private var _safariFront = false
    private var _lastTapKeyDown: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var _checkStarted: CFAbsoluteTime = 0 // 0 = no check in progress
    var safariFront: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _safariFront }
        set { lock.lock(); _safariFront = newValue; lock.unlock() }
    }
    var lastTapKeyDown: CFAbsoluteTime {
        get { lock.lock(); defer { lock.unlock() }; return _lastTapKeyDown }
        set { lock.lock(); _lastTapKeyDown = newValue; lock.unlock() }
    }
    var checkStarted: CFAbsoluteTime {
        get { lock.lock(); defer { lock.unlock() }; return _checkStarted }
        set { lock.lock(); _checkStarted = newValue; lock.unlock() }
    }
}
let shared = Shared()
var tap: CFMachPort?
var timeoutCount = 0 // tap thread only

/// Removes the tap and exits. Safe to call from any thread.
func shutDown(_ reason: String, relaunch: Bool) -> Never {
    if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
    log("\(reason); removed key tap and quitting")
    if relaunch && !underLaunchd { relaunchSelfSoon() } // launchd relaunches us anyway
    exit(0)
}

// ---- Which app is in front (tracked on the main thread, read by the tap thread) ----
shared.safariFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == safariID
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
    let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    shared.safariFront = app?.bundleIdentifier == safariID
}

// ---- Duplicating the tab (off the tap thread) ----
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
var duplicateScript: NSAppleScript? // scriptQueue only
var scriptBusy = false               // main thread only

func duplicateTab() {
    guard !scriptBusy else { return } // drop extra presses while Safari is still working
    scriptBusy = true
    scriptQueue.async {
        if duplicateScript == nil { duplicateScript = NSAppleScript(source: scriptSource) }
        var err: NSDictionary?
        duplicateScript?.executeAndReturnError(&err)
        if let err = err { log("AppleScript error: \(err)") }
        DispatchQueue.main.async { scriptBusy = false }
    }
}

// ---- Event tap (own thread; callback is pure computation) ----
let callback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout {
        timeoutCount += 1
        if timeoutCount > 3 { shutDown("tap timed out repeatedly", relaunch: true) }
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if type == .tapDisabledByUserInput { shutDown("tap disabled by the system", relaunch: false) }
    guard type == .keyDown else { return Unmanaged.passUnretained(event) }
    shared.lastTapKeyDown = CFAbsoluteTimeGetCurrent()

    guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return Unmanaged.passUnretained(event) }
    // Exactly ⌘ — no Shift/Option/Control (so ⌘⇧T "reopen closed tab" still works).
    let mods = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
    guard mods == .maskCommand, shared.safariFront else { return Unmanaged.passUnretained(event) }
    // Match the letter the current layout types with ⌘ held (Dvorak, AZERTY, … all work).
    var len = 0
    var buf = [UniChar](repeating: 0, count: 4)
    event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &buf)
    guard len == 1, buf[0] == 0x74 /* t */ || buf[0] == 0x54 /* T */ else { return Unmanaged.passUnretained(event) }

    DispatchQueue.main.async { duplicateTab() }
    return nil // swallow the original ⌘T
}

let tapReady = DispatchSemaphore(value: 0)
let tapThread = Thread {
    tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                            callback: callback, userInfo: nil)
    guard let t = tap else { log("could not create event tap"); exit(1) }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0), .commonModes)
    CGEvent.tapEnable(tap: t, enable: true)
    tapReady.signal()
    CFRunLoopRun()
}
tapThread.name = "event tap"
tapThread.qualityOfService = .userInteractive
tapThread.start()
tapReady.wait()

// ---- Watchdog thread ----
let watchdog = Thread {
    var tick = 0
    var starvedTicks = 0
    while true {
        Thread.sleep(forTimeInterval: 1)
        tick += 1
        shared.checkStarted = CFAbsoluteTimeGetCurrent()

        // a) in-process permission check
        if !AXIsProcessTrusted() { shutDown("Accessibility permission was removed", relaunch: false) }

        // b) fresh-process permission check, every 3 seconds
        if tick % 3 == 0, freshProcessIsTrusted() == false {
            shutDown("Accessibility permission was removed (fresh check)", relaunch: false)
        }

        // c) starvation: a key went down >0.5s ago that our tap never saw
        let now = CFAbsoluteTimeGetCurrent()
        let sinceKey = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
        let lastSystemKey = now - sinceKey
        let starved = sinceKey > 0.5 && sinceKey < 30 && lastSystemKey > shared.lastTapKeyDown + 0.2
            && !IsSecureEventInputEnabled() // taps don't see keys typed into password fields
        starvedTicks = starved ? starvedTicks + 1 : 0
        if starvedTicks >= 2 { shutDown("key presses are not reaching the tap", relaunch: true) }

        if debug { log("tick \(tick): trusted, sinceKey=\(String(format: "%.2f", sinceKey)) starved=\(starved)") }
        shared.checkStarted = 0
    }
}
watchdog.name = "watchdog"
watchdog.start()

// ---- Guard thread: if a watchdog check hangs, exit anyway ----
let hangGuard = Thread {
    while true {
        Thread.sleep(forTimeInterval: 0.5)
        let started = shared.checkStarted
        if started != 0 && CFAbsoluteTimeGetCurrent() - started > 3 {
            shutDown("a permission check hung", relaunch: true)
        }
    }
}
hangGuard.name = "hang guard"
hangGuard.start()

signal(SIGTERM) { _ in exit(0) }
log("running")

let app = NSApplication.shared
app.setActivationPolicy(.prohibited) // no Dock icon, no menu bar
app.run()

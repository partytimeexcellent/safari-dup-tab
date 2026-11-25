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
        if !duplicateViaContextMenu() {
            // Fallback: new tab with the same URL (no back/forward history).
            if duplicateScript == nil { duplicateScript = NSAppleScript(source: scriptSource) }
            var err: NSDictionary?
            duplicateScript?.executeAndReturnError(&err)
            if let err = err { log("AppleScript error: \(err)") }
        }
        DispatchQueue.main.async { scriptBusy = false }
    }
}

// ---- Safari's own "Duplicate Tab" (keeps back/forward history) via Accessibility ----
// Safari only offers Duplicate Tab in a tab's right-click menu, so we find the selected tab
// in the tab bar, open its menu, and press the item. Runs on scriptQueue, never the tap thread.

/// "Duplicate Tab" in the user's language, read from Safari's own strings.
let duplicateTitles: Set<String> = {
    var titles: Set<String> = ["Duplicate Tab"]
    for path in ["/System/Library/PrivateFrameworks/Safari.framework",
                 "/System/Volumes/Preboot/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework"] {
        guard let b = Bundle(path: path) else { continue }
        for key in ["Duplicate Tab (menu item)", "Duplicate Tab"] {
            let s = b.localizedString(forKey: key, value: nil, table: nil)
            if s != key || key == "Duplicate Tab" { titles.insert(s) }
        }
    }
    return titles
}()

func ax(_ e: AXUIElement, _ attr: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success ? v : nil
}
func axString(_ e: AXUIElement, _ attr: String) -> String? { ax(e, attr) as? String }
func axChildren(_ e: AXUIElement) -> [AXUIElement] { (ax(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func axIsOn(_ e: AXUIElement) -> Bool {
    if let n = ax(e, kAXValueAttribute) as? NSNumber { return n.intValue == 1 }
    if let b = ax(e, kAXSelectedAttribute) as? NSNumber { return b.boolValue }
    return false
}
func describe(_ e: AXUIElement) -> String {
    let parts = [axString(e, kAXRoleAttribute), axString(e, kAXSubroleAttribute),
                 axString(e, kAXTitleAttribute).map { "title=\"\($0.prefix(40))\"" },
                 axString(e, kAXDescriptionAttribute).map { "desc=\"\($0.prefix(40))\"" },
                 (ax(e, kAXValueAttribute) as? NSNumber).map { "value=\($0)" }]
    return parts.compactMap { $0 }.joined(separator: " ")
}

/// Breadth-first search of the window (skipping web page content) for the selected tab.
func findSelectedTab(in window: AXUIElement) -> AXUIElement? {
    var queue: [(AXUIElement, Int, Bool)] = [(window, 0, false)] // element, depth, inside a tab group
    var visited = 0
    var dump: [String] = []
    while !queue.isEmpty && visited < 3000 {
        let (e, depth, inTabs) = queue.removeFirst()
        visited += 1
        let role = axString(e, kAXRoleAttribute) ?? ""
        if debug && depth <= 7 { dump.append(String(repeating: "  ", count: depth) + describe(e)) }
        if role == "AXWebArea" { continue } // never crawl the web page itself
        // Safari 26+: tabs are AXRadioButton/AXTabButton inside an "AXOpaqueProviderList" tab bar.
        // Older layouts: radio buttons inside an AXTabGroup.
        let isTabButton = axString(e, kAXSubroleAttribute) == "AXTabButton"
        if (isTabButton || (inTabs && (role == kAXRadioButtonRole as String || role == "AXTab"))) && axIsOn(e) {
            if debug { log("found selected tab: \(describe(e))") }
            return e
        }
        let nowInTabs = inTabs || role == kAXTabGroupRole as String
            || axString(e, kAXSubroleAttribute) == "AXOpaqueProviderList"
        for c in axChildren(e) { queue.append((c, depth + 1, nowInTabs)) }
    }
    if debug { log("no selected tab found (visited \(visited)). Window tree:\n" + dump.joined(separator: "\n")) }
    return nil
}

/// Searches Safari's whole menu bar, including hidden/alternate items, for "Duplicate Tab".
func findMenuBarItem(app: AXUIElement) -> AXUIElement? {
    guard let mb = ax(app, kAXMenuBarAttribute) else { if debug { log("no menu bar") }; return nil }
    var queue: [(AXUIElement, String)] = [(mb as! AXUIElement, "")]
    var visited = 0
    var seen: [String] = []
    while !queue.isEmpty && visited < 3000 {
        let (e, path) = queue.removeFirst()
        visited += 1
        let title = axString(e, kAXTitleAttribute) ?? ""
        let here = title.isEmpty ? path : (path.isEmpty ? title : "\(path) > \(title)")
        if title.localizedCaseInsensitiveContains("duplicate") { seen.append(here) }
        if axString(e, kAXRoleAttribute) == kAXMenuItemRole as String, duplicateTitles.contains(title) {
            let enabled = (ax(e, kAXEnabledAttribute) as? NSNumber)?.boolValue ?? false
            if debug { log("menu bar item found: \(here) enabled=\(enabled)") }
            if enabled { return e }
        }
        for c in axChildren(e) { queue.append((c, here)) }
    }
    if debug { log("menu bar search (visited \(visited)); items mentioning duplicate: \(seen.isEmpty ? "none" : seen.joined(separator: " | "))") }
    return nil
}

func findMenu(near tab: AXUIElement, app: AXUIElement) -> AXUIElement? {
    var candidates = axChildren(tab) + axChildren(app)
    if let w = ax(app, kAXFocusedWindowAttribute) { candidates += axChildren(w as! AXUIElement) }
    return candidates.first { axString($0, kAXRoleAttribute) == kAXMenuRole as String }
}

func duplicateViaContextMenu() -> Bool {
    guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: safariID).first?.processIdentifier
    else { return false }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1.0)
    guard let w = ax(app, kAXFocusedWindowAttribute) else { if debug { log("no focused Safari window") }; return false }
    let window = w as! AXUIElement

    // Best case: a (possibly hidden) "Duplicate Tab" item in Safari's menu bar. Pressing it
    // through Accessibility doesn't draw any menu.
    if let item = findMenuBarItem(app: app) {
        let r = AXUIElementPerformAction(item, kAXPressAction as CFString)
        if debug { log("pressed menu bar Duplicate Tab: \(r.rawValue)") }
        if r == .success { return true }
    }

    guard let tab = findSelectedTab(in: window) else { return false }
    AXUIElementSetMessagingTimeout(tab, 0.5)

    // Best case: the tab offers "Duplicate Tab" as an accessibility action (no menu shown).
    var names: CFArray?
    if AXUIElementCopyActionNames(tab, &names) == .success, let names = names as? [String] {
        if debug {
            let described = names.map { n -> String in
                var d: CFString?
                AXUIElementCopyActionDescription(tab, n as CFString, &d)
                return "\(n.replacingOccurrences(of: "\n", with: " / ")) (\((d as String?) ?? ""))"
            }
            log("tab actions: " + described.joined(separator: " ; "))
        }
        if let action = names.first(where: { n in duplicateTitles.contains { n.contains($0) } }) {
            let r = AXUIElementPerformAction(tab, action as CFString)
            if debug { log("performed tab action directly: \(r.rawValue)") }
            if r == .success { return true }
        }
    }

    // Otherwise open the tab's right-click menu and press the item.
    // Opening a menu can block until the menu closes; the short timeout lets us carry on.
    let showResult = AXUIElementPerformAction(tab, kAXShowMenuAction as CFString)
    if debug { log("show menu result: \(showResult.rawValue)") }

    var menu: AXUIElement?
    for _ in 0..<10 {
        if let m = findMenu(near: tab, app: app) { menu = m; break }
        Thread.sleep(forTimeInterval: 0.05)
    }
    guard let menu = menu else { if debug { log("context menu not found") }; return false }

    let items = axChildren(menu)
    if let item = items.first(where: { duplicateTitles.contains(axString($0, kAXTitleAttribute) ?? "") }) {
        let r = AXUIElementPerformAction(item, kAXPressAction as CFString)
        if debug { log("pressed Duplicate Tab: \(r.rawValue)") }
        if r == .success { return true }
    } else if debug {
        log("Duplicate Tab not in menu. Items: " + items.compactMap { axString($0, kAXTitleAttribute) }.joined(separator: " | "))
    }
    AXUIElementPerformAction(menu, kAXCancelAction as CFString) // close the menu before falling back
    return false
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

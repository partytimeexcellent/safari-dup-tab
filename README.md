<img src="assets/icon.png" width="128" alt="SafariDupTab icon">

# SafariDupTab

Makes **⌘T in Safari duplicate the current tab** using Safari's own Duplicate Tab, so the copy opens right next to it and keeps its back/forward history.

It's a tiny background app with no window, no Dock icon and no menu bar icon. It uses about 20 MB of memory and no CPU when idle. It only acts when Safari is the front app and you press exactly ⌘T. Every other app and shortcut is left alone, including ⌘⇧T (reopen closed tab).

## Requirements

- macOS 13 Ventura or later. Tested on macOS 27.2 on Apple Silicon. The download is a universal app, so Intel Macs (macOS 13–26) should work, but that hasn't been tested.
- Safari only. Safari Technology Preview is ignored.
- Any keyboard layout. It matches the letter T as your layout types it with ⌘, so Dvorak, AZERTY and similar layouts work too.

## Install

### Option 1: Homebrew (recommended)

```bash
brew install partytimeexcellent/tap/safari-dup-tab
brew services start safari-dup-tab
```

Homebrew builds the app from source on your Mac, so macOS doesn't show an "unidentified developer" warning. It also starts the app at login. Building needs Apple's Command Line Tools; if you don't have them, run `xcode-select --install`.

### Option 2: Download the app

1. Download `SafariDupTab.dmg` from the [latest release](https://github.com/partytimeexcellent/safari-dup-tab/releases/latest) and open it.
2. In the window that appears, **drag SafariDupTab onto the Applications folder**. Don't open it from the disk image; it needs to live in Applications. Then eject the disk image.
3. Open SafariDupTab from your Applications folder. The app isn't signed by an identified Apple developer, so macOS will block it the first time:
   - Click **Done** (not Move to Trash) in the warning.
   - Go to System Settings → Privacy & Security, scroll down to the message about SafariDupTab, and click **Open Anyway**.
   - Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/SafariDupTab.app`, then open it.
4. Once it's running, it adds itself to Login Items so it starts at login.

Use one option, not both. If both are installed, only one copy runs.

### Switching from the download to Homebrew

Homebrew doesn't remove the downloaded app, and `--force` doesn't either. Remove it yourself first:

1. Turn SafariDupTab off in System Settings → General → Login Items & Extensions.
2. Quit SafariDupTab in Activity Monitor.
3. Remove SafariDupTab from Privacy & Security → Device Control and Data Access.
4. Drag `/Applications/SafariDupTab.app` to the Trash.
5. Install with Homebrew (Option 1), then grant the permission again for the Homebrew copy.

## Permissions (one time)

1. **Accessibility:** go to System Settings → Privacy & Security → **Device Control and Data Access** (called **Accessibility** on macOS 26 and earlier) and turn on **SafariDupTab**. If it isn't listed, click **+**, press ⌘⇧G and enter the app's location:
   - Homebrew: `/opt/homebrew/opt/safari-dup-tab/SafariDupTab.app` (Intel: `/usr/local/opt/...`)
   - Download: `/Applications/SafariDupTab.app`

   The app notices the permission within about 10 seconds.
2. **Automation:** the first time you press ⌘T in Safari, macOS asks whether SafariDupTab can control Safari. Click **Allow**.

> After an upgrade, macOS sees a new app, so you may need to remove SafariDupTab from that list and add it again.

## Uninstall

**Homebrew:**

```bash
brew services stop safari-dup-tab
brew uninstall safari-dup-tab
```

**Download:** turn SafariDupTab off in System Settings → General → Login Items & Extensions, quit it in Activity Monitor, and drag it from Applications to the Trash.

Either way, you can then remove SafariDupTab from Device Control and Data Access, and from Privacy & Security → Automation.

## How it works

- A keyboard event tap watches for ⌘T while Safari is in front, and blocks Safari's usual New Tab.
- It then runs Safari's own **Duplicate Tab**, which keeps the tab's back/forward history. Safari has this as a hidden item in its Window menu (it never appears on screen, which is also why a System Settings keyboard shortcut can't reach it). SafariDupTab presses it through Accessibility, so no menu is shown.
- If a future Safari removes that hidden item, it opens the tab's right-click menu and chooses Duplicate Tab instead (you may see the menu flash briefly).
- If that fails too, it falls back to opening the same URL in a new tab next to the current one (without history). If no Safari window is open, ⌘T opens a new window.

**Safety:** the app quits if its permission is removed or switched off, if key presses stop reaching it, or if a permission check hangs. Typing may lag for a few seconds while it notices. Key handling runs on its own thread and never waits on anything else.

Logs (Homebrew): `$(brew --prefix)/var/log/safari-dup-tab.log`

## Build it yourself

```bash
./build.sh      # produces build/SafariDupTab.app (universal)
./make-dmg.sh   # packages it as build/SafariDupTab.dmg
```

## License

MIT

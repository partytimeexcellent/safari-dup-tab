# SafariDupTab

Makes **⌘T in Safari duplicate the current tab**, opening the copy right next to it instead of a blank tab at the end.

It's a tiny background app with no window, no Dock icon and no menu bar icon. It uses about 20 MB of memory and no CPU when idle. It only acts when Safari is the front app and you press exactly ⌘T. Every other app and shortcut is left alone, including ⌘⇧T (reopen closed tab).

## Requirements

- macOS 13 Ventura or later. Tested on macOS 27.2 on Apple Silicon. The download is a universal app, so Intel Macs (macOS 13–26) should work, but that hasn't been tested.
- Safari only. Safari Technology Preview is ignored.
- Any keyboard layout. It matches the letter T as your layout types it with ⌘, so Dvorak, AZERTY and similar layouts work too.

## ⚠️ Upgrade from 1.0.0–1.0.2

Versions 1.0.0–1.0.2 can freeze keyboard and mouse input system-wide if the permission is removed while they are running. If you have one of them, stop it before removing the permission (`brew services stop safari-dup-tab`, or quit it in Activity Monitor), then upgrade. In 1.0.3 and later, removing the permission causes a few seconds of keyboard lag at most, then the app quits.

## Install

### Option 1: Homebrew (recommended)

```bash
brew install partytimeexcellent/tap/safari-dup-tab
brew services start safari-dup-tab
```

Homebrew builds the app from source on your Mac, so macOS doesn't show an "unidentified developer" warning. It also starts the app at login. Building needs Apple's Command Line Tools; if you don't have them, run `xcode-select --install`.

### Option 2: Download the app

1. Download `SafariDupTab.zip` from the [latest release](https://github.com/partytimeexcellent/safari-dup-tab/releases/latest), unzip it, and move **SafariDupTab.app** to your **Applications** folder.
2. Open it. The app isn't signed by an identified Apple developer, so macOS will block it the first time:
   - Click **Done** (not Move to Trash) in the warning.
   - Go to System Settings → Privacy & Security, scroll down to the message about SafariDupTab, and click **Open Anyway**.
   - Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/SafariDupTab.app`, then open it.
3. Once it's running, it adds itself to Login Items so it starts at login.

Use one option, not both. If both are installed, only one copy runs.

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
- It then tells Safari, through AppleScript, to open a tab with the same URL right after the current one, and switches to it.
- If no Safari window is open, ⌘T opens a new window. On a blank tab, it opens another blank tab next to it.

**Safety:** the app quits if its permission is removed or switched off, if key presses stop reaching it, or if a permission check hangs. Typing may lag for a few seconds while it notices. Key handling runs on its own thread and never waits on anything else.

**Limitation:** the new tab loads the same URL fresh. It doesn't copy the original tab's back/forward history or scroll position, unlike right-click → Duplicate Tab.

Logs (Homebrew): `$(brew --prefix)/var/log/safari-dup-tab.log`

## Build it yourself

```bash
./build.sh   # produces build/SafariDupTab.app (universal)
```

## License

MIT

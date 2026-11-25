# SafariDupTab

Makes **⌘T in Safari duplicate the current tab**, opening the copy right next to it instead of a blank tab at the end.

It's a tiny background app (about 80 lines of Swift) with no window, no Dock icon and no menu bar icon. It only acts when Safari is the front app and you press exactly ⌘T. Every other app and shortcut is left alone, including ⌘⇧T (reopen closed tab).

## Install

```bash
brew install partytimeexcellent/tap/safari-dup-tab
brew services start safari-dup-tab
```

Homebrew builds the app from source on your Mac. It also starts it at login.

### Permissions (one time)

1. **Accessibility:** go to System Settings → Privacy & Security → **Device Control and Data Access** (called **Accessibility** before macOS 27) and turn on **SafariDupTab**. If it isn't listed, click **+**, press ⌘⇧G and paste the path that `brew info safari-dup-tab` shows for `SafariDupTab.app`. The app picks up the permission within about 10 seconds.
2. **Automation:** the first time you press ⌘T in Safari, macOS asks whether SafariDupTab can control Safari. Click **Allow**.

> After `brew upgrade` or a reinstall, macOS sees a rebuilt app, so you may need to remove SafariDupTab from that list and add it again.

## Uninstall

```bash
brew services stop safari-dup-tab
brew uninstall safari-dup-tab
```

Then remove SafariDupTab from Device Control and Data Access, and from Privacy & Security → Automation, if you like.

## How it works

- A keyboard event tap watches for ⌘T while Safari is in front, and blocks Safari's usual New Tab.
- It then tells Safari, through AppleScript, to open a tab with the same URL right after the current one, and switches to it.
- If no Safari window is open, ⌘T opens a new window. On a blank tab, it opens another blank tab next to it.

**Limitation:** the new tab loads the same URL fresh. It doesn't copy the original tab's back/forward history or scroll position, unlike right-click → Duplicate Tab.

Logs: `$(brew --prefix)/var/log/safari-dup-tab.log`

## Build without Homebrew

```bash
./build.sh   # produces build/SafariDupTab.app
```

## License

MIT

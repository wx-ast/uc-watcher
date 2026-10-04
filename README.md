# Universal Control Watcher

**English** | [Русский](README.ru.md)

A macOS application that restores Universal Control when the connection to a
selected Mac becomes unavailable. It runs in the menu bar and reports confirmed
recovery through a system notification.

## Installation

Requires macOS 13 or later. Open `UC Watchdog.app` on the receiving Mac and click
**Install**. Choose a Mac from the discovered devices: the application shows its
name or model and IDS prefix. It then starts and enables launch at login.
Allow notifications for **UC Watchdog** when prompted on first launch.

The device list comes from the past 24 hours of Universal Control logs. If your
Mac is missing, enable Universal Control on both devices, try moving the pointer
to the other screen, and click **Refresh List**. macOS sometimes hides the name;
in that case, the model or prefix is shown. Canceling device selection installs
nothing.

To update, open the new copy and choose **Update**. History, logs, the selected
Mac, and the launch-at-login setting are retained. **Cancel** closes the copy
without installing it.

## Controls and language

Click the monitor icon in the menu bar:

- **Launch at Login** — enable or disable automatic startup.
- **Stop** — close the application and monitor; the login setting is retained.
- **Open Log** — view events and recovery attempts.
- **Uninstall App…** — disable automatic startup and remove the application;
  history and logs are retained.
- **Language → English / Русский** — choose the interface language.

English is the default, regardless of the macOS language. The choice persists
across launches and updates. Menus, dialogs, and new notifications use the
selected language immediately; commands and diagnostic logs remain in English.
In the Russian interface, the language menu is named **Язык**.

The menu also includes application information, a shortcut to Finder, and Login
Items settings. After stopping, you can reopen the application in Finder.

## How it works

- Restarts the current user's `sharingd` and Universal Control when the selected
  Mac reports `Device Unavailable`. A single `Device Lost` is insufficient.
- Makes one attempt per outage, with a 120-second cooldown and at most three
  attempts in 10 minutes. Rate-limit history persists across launches.
- Reports recovery only after `Connected` for the target Mac.

Restarting these services can briefly interrupt AirDrop and Handoff. The
application helps restore the connection but does not resolve the cause of the
outages. It cannot detect an outage if the system log is inaccessible.

## Build

Requires Xcode or Command Line Tools with Swift 5.9 or later.

```sh
swift build -c release
.build/release/uc-watchdog bundle --output ".build/UC Watchdog.app"
open ".build/UC Watchdog.app"
```

The `bundle` destination must not already exist. When transferring to another
Mac, copy the entire `.app` built for its architecture.

### Developer ID signing and Apple notarization

Use `Scripts/release.sh` for distribution. You need Xcode with `notarytool` and
`stapler`, Apple Developer Program membership, and a **Developer ID Application**
certificate with its private key in Keychain. List available signing identities:

```sh
security find-identity -v -p codesigning
```

If you do not have a certificate, create one for your team in Xcode → Settings →
Accounts → Manage Certificates or through Apple Developer. Install it together
with its private key in Keychain on the build Mac.

Store notarization credentials in Keychain once. This command interactively
asks for an Apple ID, Team ID, and app-specific password:

```sh
xcrun notarytool store-credentials "uc-watchdog-notary"
```

You can instead use an App Store Connect API key with
`store-credentials --key /path/AuthKey.p8 --key-id KEY_ID --issuer ISSUER_ID`
(an Individual API Key does not need `--issuer`). Do not commit passwords,
`.p12` files, or `.p8` files to the repository.

Build and submit for notarization:

```sh
export UC_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export UC_NOTARY_PROFILE='uc-watchdog-notary'
bash Scripts/release.sh
```

For persistent local configuration, copy `Scripts/release.env.example` to
`Scripts/release.local.env` and set the certificate and profile names. This file
is excluded from Git; environment variables override its values.

The script builds a universal application for Apple Silicon and Intel, runs
`self-test` and `check-processes`, signs with Hardened Runtime and a secure
timestamp, submits a ZIP to Apple, and waits for `Accepted`. It then staples the
ticket to the `.app` and validates it with `stapler`, verifies the signature with
`codesign`, and checks Gatekeeper assessment. The final
`UC-Watchdog-notarized.zip` is created **after** stapling the ticket. Each run
creates a separate `.build/distribution/release.*` directory containing the
`.app`, ZIP, SHA-256 checksum, signature details, and Apple's result/log.

To build with signing only, without submitting to Apple:

```sh
bash Scripts/release.sh --sign-only
```

This produces `UC-Watchdog-signed.zip` and does not confirm Gatekeeper approval.
If notarization fails, no final notarized ZIP is produced; diagnostics remain in
the build directory. If the request is still processing, use
`xcrun notarytool info ID --keychain-profile uc-watchdog-notary` or `wait`.
After receiving `Accepted`, run `stapler staple`, `stapler validate`, and
`spctl --assess --type execute`, then repackage the `.app` using `ditto`.

Installation and updates from a `.app` copy the entire bundle without signing it
again, preserving the signature and ticket. The bundle ID remains
`local.uc-watchdog`; configuration, recovery history, and logs are stored
separately. The build script does not install the application or change launch
at login.

If `codesign` reports `errSecInternalComponent`, run the build in a regular macOS
Terminal, unlock the Keychain containing the certificate, and approve the system
prompt granting `codesign` access to the private key. That prompt may be
unavailable in a background session. Signing diagnostics are saved in
`signing.log`.

See [Apple's notarization workflow documentation](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

<details>
<summary>Checks and diagnostics</summary>

```sh
.build/release/uc-watchdog self-test
.build/release/uc-watchdog check-processes
bash Scripts/check-bundle-copy.sh
.build/release/uc-watchdog peers
.build/release/uc-watchdog monitor --dry-run --duration 30
".build/UC Watchdog.app/Contents/MacOS/uc-watchdog" menu-self-test
".build/UC Watchdog.app/Contents/MacOS/uc-watchdog" preview-notification
```

Checks and `--dry-run` do not restart services. `preview-notification` sends a
test notification without disconnecting Universal Control.

The application is installed at
`~/Library/Application Support/UCWatchdog/UC Watchdog.app`.
Logs, configuration, and recovery history are stored in
`~/Library/Logs/UCWatchdog/`. The language choice is stored in the
`local.uc-watchdog` user preferences domain. The main log is `watchdog.log`,
rotated across up to four files of roughly 1 MB each.

</details>

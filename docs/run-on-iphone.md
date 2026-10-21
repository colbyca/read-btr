# Running ReadBTR on your iPhone

These steps use a free Apple ID ("Personal Team"). A paid developer account works the same way, and its builds don't expire after 7 days.

## 1. Generate the project

```bash
brew install xcodegen
cd ~/mystuff/read-btr
xcodegen generate
open ReadBTR.xcodeproj
```

Run `xcodegen generate` again whenever you pull changes to `project.yml`. Any signing changes you make in Xcode are overwritten each time, so see step 3 to make them stick.

## 2. Add your Apple ID to Xcode

1. Go to **Xcode → Settings → Accounts**.
2. Click **+**, choose **Apple ID** and sign in.
3. Your team appears as **"Your Name (Personal Team)"**.

## 3. Set up signing

1. In the project navigator, select **ReadBTR** (the blue project icon), then the **ReadBTR** target, then the **Signing & Capabilities** tab.
2. Turn on **Automatically manage signing**.
3. Pick your team from the **Team** menu.
4. If Xcode reports that the bundle ID `com.colbycarter.readbtr` isn't available, change it to something unique, such as `com.<yourname>.readbtr`.

To keep this setting when you regenerate the project, put your team ID in `project.yml` under `targets → ReadBTR → settings → base`:

```yaml
DEVELOPMENT_TEAM: ABCDE12345
CODE_SIGN_STYLE: Automatic
```

Your team ID is the 10-character code shown in Xcode → Settings → Accounts → your team, or in the signing section after you select the team. The test targets don't need it to run the app.

## 4. Connect and trust the iPhone

1. Plug the iPhone in with a cable. After the first pairing, Wi-Fi works too.
2. Unlock the phone. When it asks **"Trust This Computer?"**, tap **Trust** and enter your passcode.
3. In Xcode, open **Window → Devices and Simulators**. Wait while the phone shows "Preparing…" or "Copying shared cache". The first time takes a few minutes.

## 5. Turn on Developer Mode (iOS 16 and later)

1. On the phone, go to **Settings → Privacy & Security → Developer Mode**. The option only appears after Xcode has seen the phone at least once.
2. Turn it on and tap **Restart**.
3. After the restart, tap **Turn On** and enter your passcode.

## 6. Pick the iPhone and run

1. In the Xcode toolbar, set the scheme to **ReadBTR** and set the run destination to your iPhone by name (not "Any iOS Device").
2. Press **⌘R**.

## 7. Trust the developer certificate on the phone (first run only)

If the app installs but won't open and says **"Untrusted Developer"**:

1. Go to **Settings → General → VPN & Device Management**.
2. Under **Developer App**, tap your Apple ID and then **Trust**.
3. Run again from Xcode, or tap the app icon.

## Things to know

- **The 7-day limit**: with a free Personal Team, the app stops launching after 7 days. Press ⌘R again to re-sign it. Your app data stays on the phone.
- **The 3-app limit**: a free team can have at most 3 sideloaded apps on a device at once.
- **"Failed to register bundle identifier"**: change the bundle ID (step 3.4).
- **"Device is busy" or "Waiting to reconnect"**: unlock the phone and keep it unlocked until the app launches.
- **"iOS version not installed" or "Developer disk image" errors**: your phone's iOS is newer than Xcode supports. Update Xcode.

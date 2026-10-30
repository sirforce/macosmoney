# Releasing

`tools/release/release.sh` turns the source into a signed, notarized app and disk image, then installs it in `/Applications`. Because the app is signed with your Developer ID and notarized by Apple, it opens on any Mac without Gatekeeper warnings.

```sh
tools/release/release.sh                 # tests → archive → sign → notarize → staple → DMG → install
tools/release/release.sh --skip-tests    # skip the test run
tools/release/release.sh --no-notarize   # signed only (fine for your own Mac)
tools/release/release.sh --no-install    # build the DMG but leave /Applications alone
tools/release/release.sh --no-dmg        # notarize and install the app only (no disk image)
```

Output goes to `App/build/release/MacMoney-<version>-<build>/`: `MacMoney.app`, `MacMoney-<version>.dmg` and the notarization log.

## Why not the Mac App Store?

Mac App Store apps must run in the App Sandbox. MacMoney runs `java` to read `.mny` files, which the sandbox doesn't allow. Developer ID signing plus notarization is Apple's supported route for apps distributed outside the store.

## One-time setup

1. **A Developer ID Application certificate** in your login keychain. Create it in Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates, or at developer.apple.com. Check with:

   ```sh
   security find-identity -v -p codesigning
   ```

2. **Local configuration.** Copy the example and fill in your team ID (the 10 characters in parentheses after the certificate name). `release.env` is git-ignored.

   ```sh
   cp tools/release/release.env.example tools/release/release.env
   ```

3. **Notarization credentials**, saved in your keychain under a profile name. Either use your Apple ID with an app-specific password (create one at account.apple.com ▸ Sign-In and Security ▸ App-Specific Passwords):

   ```sh
   xcrun notarytool store-credentials "MacMoney-notary" --apple-id you@example.com --team-id XXXXXXXXXX
   ```

   or an App Store Connect API key (App Store Connect ▸ Users and Access ▸ Integrations ▸ Team Keys, role *Developer*):

   ```sh
   xcrun notarytool store-credentials "MacMoney-notary" --key AuthKey_ABC123.p8 --key-id ABC123 --issuer <issuer-uuid>
   ```

## What the script does

1. Reads the version from `MARKETING_VERSION` in `App/project.yml`. The build number is the commit count (`git rev-list --count HEAD`), so every commit gets a higher one.
2. Regenerates the Xcode project and runs the tests.
3. Archives the Release configuration with manual signing, the hardened runtime and secure timestamps.
4. Verifies the signature, zips the app, submits it to Apple's notary service, waits, then staples the ticket to the app.
5. Builds a compressed DMG with an Applications shortcut, then signs, notarizes and staples it as well.
6. Quits MacMoney if it's running (it takes its automatic backup on the way out), replaces `/Applications/MacMoney.app`, checks it with `spctl` and opens it.

If notarization is rejected, the script prints the command to fetch Apple's log.

## Versioning

- Change `MARKETING_VERSION` in `App/project.yml` for a new version (for example `0.9` → `1.0`).
- The build number comes from git automatically. Local debug builds show build `1`.

## App icon

The icon is drawn in code by `tools/icon/AppIcon.swift`. After changing it, regenerate every size into the asset catalog:

```sh
tools/icon/make-icons.sh
```

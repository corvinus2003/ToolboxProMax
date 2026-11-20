# Mac App Store edition

The same source code builds two editions:

| | Full edition | App Store edition |
| --- | --- | --- |
| Built with | `scripts/build-app.sh` | this folder (Xcode project) |
| Download node (yt-dlp) | yes | no: the App Store doesn't allow downloading from YouTube or running downloaded programs |
| Sandbox | no | yes, with security-scoped bookmarks so saved graphs reopen their files |
| Bundle ID | `app.toolboxpromax` | `io.github.corvinus2003.toolbox` (can never change once published) |
| Name | Toolbox Pro Max | Toolbox Studio |
| Distributed | GitHub releases, free | Mac App Store |

The difference is the `APPSTORE` compilation flag (see `Sources/ToolboxProMax/App/Edition.swift`).
Nothing in this folder affects the full edition.

## Build

```sh
brew install xcodegen                         # once
xcodegen generate --spec AppStore/project.yml # creates AppStore/ToolboxAppStore.xcodeproj
open AppStore/ToolboxAppStore.xcodeproj
```

The display name is the `APP_DISPLAY_NAME` setting in `project.yml`; the version is `MARKETING_VERSION`.
Archive with the "Any Mac" destination to get a universal (Apple Silicon + Intel) build.

## Store page

- Texts to paste: [metadata/en-US.md](metadata/en-US.md)
- Screenshots (2880×1800, no alpha): [screenshots/](screenshots/), remade with `scripts/appstore-shots/`
- Privacy policy: [docs/privacy.md](../docs/privacy.md)

## Publishing checklist

In Xcode
- [ ] Xcode ▸ Settings ▸ Accounts: sign in with the Apple ID of the developer account
- [ ] Set the team (`DEVELOPMENT_TEAM` in `project.yml`, or in the target's Signing & Capabilities)
- [ ] Product ▸ Archive, then Distribute App ▸ App Store Connect

In App Store Connect (only the account holder can do these)
- [ ] Agreements: accept the Paid Applications Agreement
- [ ] Banking and tax forms
- [ ] Optional: enroll in the App Store Small Business Program (15% commission instead of 30%)
- [ ] New macOS app: name "Toolbox Studio", bundle ID `io.github.corvinus2003.toolbox`, SKU
- [ ] Price: USD 9.99
- [ ] Description, keywords, screenshots (2880×1800 or 1440×900), support URL, privacy policy URL
- [ ] App Privacy: "Data Not Collected"; category Photo & Video; age rating 4+
- [ ] Pick the uploaded build and submit for review

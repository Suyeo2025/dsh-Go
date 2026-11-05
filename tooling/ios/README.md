# iOS build (remote client only)

The iOS app is a remote client: no local engine/PRoot. Builds run on the Mac build host
(`ssh macstudio`); the source of truth is this checkout, including `app/ios`.

| File | Runs on | What |
|---|---|---|
| `local.env` | both | account values, not in git (see below); template `local.env.example` |
| `sync-to-mac.sh` | whole | rsync this tree → `macstudio:~/Workspace/dsh-go/src` (honours `.gitignore`, copies `local.env` separately); `--pull-ios` brings `app/ios` back |
| `env.sh` | Mac | shared paths/IDs, loads and checks `local.env`; pins Flutter `~/sdk/flutter-3.47.7` (never the homebrew one) |
| `build-nocodesign.sh` | Mac | compile check: `flutter build ios --release --no-codesign` → `logs/build-<mode>.log` |
| `make-app-icon.sh` | Mac | renders `AppIcon.appiconset` (1024: light opaque, dark, tinted) from `app/assets/brand/tile.svg` |
| `tf-release.sh` | Mac | preflight → keychain → profile → archive → export → altool upload → `testflight.mjs`; log `logs/tf-<build>.log` (`tf-latest.log`); `--validate` checks without uploading |
| `profile.mjs` | Mac | ASC API: bundle ID `com.colex.dshgo` + push capability, App Store profile `dg com.colex.dshgo` and development profile `dg dev com.colex.dshgo`, installs them |
| `testflight.mjs` | Mac | waits for processing, export compliance fallback, internal group `内部测试` + testers, adds build, reads back (`--status` read-only) |
| `asc.mjs` | Mac | App Store Connect API client (ES256 JWT from `~/.appstoreconnect/private_keys`) |
| `Signing.xcconfig`, `ExportOptions.plist` | Mac | manual App Store signing |
| `sim-smoke.sh` → `sim-smoke-mac.zsh` | whole → Mac | `app/integration_test/ios_smoke_test.dart` on a throwaway simulator (`--ipad`, `--offline`) → `logs/sim-smoke[-ipad]/` |

## local.env

Everything tied to one developer account stays out of git in `tooling/ios/local.env`
(`tooling/ios/.gitignore`). Start from the template and fill it in:

```bash
cp tooling/ios/local.env.example tooling/ios/local.env && chmod 600 tooling/ios/local.env
```

| Key | Used by | What |
|---|---|---|
| `ASC_KEY_ID`, `ASC_ISSUER` | `asc.mjs`, `tf-release.sh` (altool) | App Store Connect API key; the `.p8` is `~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8` on the Mac |
| `DG_CERT_ID`, `DG_DEV_CERT_ID` | `profile.mjs` | Apple Distribution / Apple Development certificate ids (`GET /v1/certificates`) |
| `DG_KC`, `DG_KC_PASS_FILE` | `tf-release.sh` | keychain with the distribution key, and the file holding its password (read, never printed) |
| `DG_TF_TESTERS` | `testflight.mjs` | internal testers, comma-separated (must be App Store Connect users who can see the app) |
| `SMOKE_URL` | `sim-smoke.sh` | a `dsh web` over https; its launch token is read from `~/.dsh/run/stdout.log` |

Lines are plain `KEY=VALUE` (`$HOME` allowed). `sync-to-mac.sh` copies the file to the Mac (0600);
a missing file or key stops the scripts with the key's name. The team id (`4JV8BHB2KW`) and the
bundle id stay in the project: both are visible in every signed build anyway.

## Typical run

```bash
tooling/ios/sync-to-mac.sh
ssh macstudio 'zsh ~/Workspace/dsh-go/src/tooling/ios/build-nocodesign.sh release'     # compile check
tooling/ios/sim-smoke.sh && tooling/ios/sim-smoke.sh --no-sync --ipad                    # simulator smoke
ssh macstudio 'nohup zsh ~/Workspace/dsh-go/src/tooling/ios/tf-release.sh </dev/null >/dev/null 2>&1 &'
ssh macstudio 'tail -f ~/Workspace/dsh-go/logs/tf-latest.log'                           # ends with TF_RC=0
ssh macstudio 'cd ~/Workspace/dsh-go/src/tooling/ios && node testflight.mjs --status'    # build states
```

Build number = `yyyyMMddHHmm` (Mac local time); version name = `pubspec.yaml` (`--build-name` to override).

## Notes / pitfalls

- Never run `flutter create` in the real tree: it re-resolves `pubspec.lock` (downgrades) and rewrites
  `analysis_options.yaml`/`.metadata`. Generate in a scratch copy and take only `ios/`.
- Plugins are all Swift Package Manager (Flutter 3.47 default) — no Podfile/Pods. Minimum iOS 15.0
  (image_picker_ios); if CocoaPods is ever needed, use `platform :ios, '15.0'`.
- Signing is manual: `-allowProvisioningUpdates` with an API key fails auth. The Apple Distribution key
  sits in a dedicated keychain (`DG_KC`, used read-only) so codesign never waits on a SecurityAgent
  prompt; `tf-release.sh` keeps it in the search list and unlocks it. Works over plain ssh.
- No bundled asset may start with `#!` (App Store rejects it as unsigned code, ITMS-90035):
  `tf-release.sh` checks before archiving.
- ATS: only `NSAllowsArbitraryLoads` (hosts are user-configured, often plain http). Adding
  `NSAllowsLocalNetworking` would make iOS ignore `NSAllowsArbitraryLoads`.
- Export compliance: `ITSAppUsesNonExemptEncryption=false` in Info.plist (standard TLS/Noise/AES only);
  `testflight.mjs` sets `usesNonExemptEncryption=false` via API if a build still lacks an answer.
- Push: `aps-environment` development (Debug) / production (Release). Time Sensitive Notifications
  can't be enabled through the API: tick it on the App ID in the developer portal before adding
  `com.apple.developer.usernotifications.time-sensitive` back to the entitlements.
- Internal TestFlight only: no external groups, no beta review.

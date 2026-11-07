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
| `tf-release.sh` | Mac | preflight → keychain → profile → archive → export → altool upload → `testflight.mjs`; log `logs/tf-<build>.log` (`tf-latest.log`); `--validate` checks without uploading; `--share`/`--no-share` (default: the share extension only when the profiles carry the App Group) |
| `profile.mjs` | Mac | ASC API: bundle IDs `com.colex.dshgo` (push, App Groups) and `com.colex.dshgo.share` (App Groups), App Store and development profiles for both, installs them, reports their App Groups |
| `testflight.mjs` | Mac | waits for processing, export compliance fallback, internal group `内部测试` + testers, adds build, reads back (`--status` read-only) |
| `asc.mjs` | Mac | App Store Connect API client (ES256 JWT from `~/.appstoreconnect/private_keys`) |
| `Signing.xcconfig`, `ExportOptions.plist` | Mac | manual App Store signing |
| `sim-smoke.sh` → `sim-smoke-mac.zsh` | whole → Mac | `app/integration_test/ios_smoke_test.dart` on a throwaway simulator (`--ipad`, `--offline`) → `logs/sim-smoke[-ipad]/`; `--links`: a debug simulator build on its own — a share dropped in the App Group inbox must open a new conversation, then `dshgo://` links warm and cold → `logs/sim-links/` (no host needed) |
| `sim-islands.sh` → `sim-islands-mac.zsh` | whole → Mac | `app/integration_test/ios_islands_test.dart` (= `sim-smoke.sh --islands`): every plugin seat of the real host at page size — island / web fallback / native — plus `dsh/islands device` and a warm `dshgo://open/settings` → `logs/sim-islands/islands.json` + shots |

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

## Share extension signing (done)

`app/ios/ShareExtension` (bundle id `com.colex.dshgo.share`, 「分享 › DSH Go」) hands shares to the app
through the App Group `group.com.colex.dshgo` (both targets' entitlements). Set up 2026-11-05:

- Portal (no API for it): App Group `group.com.colex.dshgo` ("DSH Go Group") registered and assigned to
  both App IDs, `com.colex.dshgo` and `com.colex.dshgo.share`.
- `profile.mjs` keeps the rest: both bundle IDs, their capabilities, all four profiles
  (`dg [dev ]com.colex.dshgo[.share]`), and prints `APP_GROUPS <profile> <groups|none>` for each.

`tf-release.sh` (default `--share` auto) embeds the extension when both App Store profiles carry the
group, as they do now. Should a profile ever lose it (a group unassigned in the portal), the archive
goes out **without** the extension: it is left out of that one archive (the project file is edited
for it and restored) and the app is signed without the App Group entitlement. `--share` insists on it
(stops instead), `--no-share` leaves it out. Any App ID capability change invalidates the profiles:
`node tooling/ios/profile.mjs --renew`.

## Live Activity 「鲸游」(WhaleWakeActivity)

- Target `WhaleWakeActivity` (widget extension, `com.colex.dshgo.activity`, iOS 16.2+), embedded next to
  the share extension. Attributes, views, intents, copy and samples live in `app/ios/Runner/WhaleWakeShared/`
  and are compiled into both Runner and the extension; pixel frames in `WhaleWakeActivity/Assets.xcassets`
  (40 PNGs from `plan/design/live-activity-a/assets/`, drawn at their own size, nearest neighbour).
- Runner side: `LiveActivityChannel.swift` (`dsh/live_activity`, contract in `plan/wave2-reports/la-dart.md`),
  `LiveActivityDecision.swift` (Allow / Deny: unlock required, Face ID again for high risk, bridge
  `POST /v1/approvals/<id>/decision`, otherwise the App opens; never allows on its own).
- Signing: no capability. `profile.mjs` registers the bundle id and keeps `dg [dev ]com.colex.dshgo.activity`
  (optional: a failure prints `PROFILE_FAILED` and the rest goes on). `tf-release.sh --activity / --no-activity`,
  default: embedded when that App Store profile is ACTIVE, else left out of that archive only.
- Check on the Mac: `zsh tooling/ios/la-sim-mac.zsh` → `logs/live-activity/`: `RunnerTests/WhaleWakeTests`,
  rendered boards of every state (`boards/la-*.png`), and every sample Activity started on a throwaway
  simulator (`-DSHGOLADemo <sample>`, simulator builds only). The Dynamic Island itself can't be shot here:
  a simulator without Simulator.app suppresses it, and simctl can't long-press or lock.
- v2 (`plan/design/live-activity-v2-contract.md`): option keys (`AnswerIntent`), todo buoys, the
  conclusion line, two-tap 「停止」 (`StopIntent`; the five-second check is `WhaleWakeStopGate`), the
  minimal as a progress ring, the iOS 27 width-limited compact. Its boards land in `logs/live-activity/v2/`.

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
- `simctl openurl dshgo://…` always stops at iOS's 「在"DSH Go"中打开？」 prompt (iOS 27 simulator), which
  nothing here can press: `--links` shoots the cold link at that prompt; the islands test checks a warm
  link by having the app open it itself.
- An island WebView hidden with `Opacity(0)` is never composited on iOS (0×0 WKWebView, DSH Web lays out
  for nothing, every island times out): `island_view.dart` hides with the least visible alpha there.
- ATS: only `NSAllowsArbitraryLoads` (hosts are user-configured, often plain http). Adding
  `NSAllowsLocalNetworking` would make iOS ignore `NSAllowsArbitraryLoads`.
- Export compliance: `ITSAppUsesNonExemptEncryption=false` in Info.plist (standard TLS/Noise/AES only);
  `testflight.mjs` sets `usesNonExemptEncryption=false` via API if a build still lacks an answer.
- Push: `aps-environment` development (Debug) / production (Release), plus
  `com.apple.developer.usernotifications.time-sensitive` in both entitlements. Time Sensitive
  Notifications (USERNOTIFICATIONS_TIMESENSITIVE) was ticked on `com.colex.dshgo` in the portal
  (done 2026-11-05); `profile.mjs` prints `time-sensitive=` per profile.
- Internal TestFlight only: no external groups, no beta review.

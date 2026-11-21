# Crowdography phone apps

Owned by HUXY, LLC. Built on the Chronum API (chronumapi.com).

- `ios/`: the iPhone app (Swift). `project.yml` is turned into the Xcode project by XcodeGen on the build machine.
- `android/`: the Android app (Kotlin). Coming next.

## Rules the apps follow

- Only genuine phones film: Apple App Attest on iPhone, Google key attestation on Android. Chronum checks both itself.
- The filming key lives in the phone's security chip and never leaves it. No keys or secrets are stored in the app.
- Originals are uploaded byte for byte. Location and device details are kept, never stripped.
- Video is at most 4K; pieces are at most 15 minutes and chain automatically.

## Builds

GitHub Actions compiles and tests every push. Pushes to `main` also go to TestFlight once these repository
secrets exist: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (an App Store Connect API key with Admin access).

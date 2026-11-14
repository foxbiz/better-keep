# iOS image-share UI acceptance

Run this manual gate after changing the extension UI or app handoff and before an
iOS release. `npm test image-share` remains the fast Dart/native/signing suite;
these UI tests require Xcode, Flutter, the iOS Simulator, and Ruby's `xcodeproj`
gem (installed with CocoaPods).

Use a **fresh disposable simulator**. The fixture uses Better Keep's real bundle
ID and local database; never install it over an app with user data or on a phone.
It disables cloud sync and uses a public, test-only encryption key below.

From the repository root, generate the test host project:

```sh
ruby test/ios_image_share_ui/create_project.rb
xcrun simctl list devices available
```

Create and boot a fresh simulator in Xcode, then assign its UUID to `SIMULATOR_ID`.
Build the fixture in a subshell so the normal app's generated Flutter build
configuration is restored even if the build fails:

```sh
(
  set -eu
  fixture_backup=$(mktemp -d)
  cp ios/Flutter/Generated.xcconfig "$fixture_backup/Generated.xcconfig"
  cp ios/Flutter/flutter_export_environment.sh "$fixture_backup/flutter_export_environment.sh"
  trap 'cp "$fixture_backup/Generated.xcconfig" ios/Flutter/Generated.xcconfig; cp "$fixture_backup/flutter_export_environment.sh" ios/Flutter/flutter_export_environment.sh' EXIT
  flutter build ios --simulator --debug --no-pub \
    -t integration_test/image_share_test_app.dart \
    --dart-define=LOCAL_DATA_KEY=0000000000000000000000000000000000000000000000000000000000000000
)
xcrun simctl install "$SIMULATOR_ID" build/ios/iphonesimulator/Runner.app
xcodebuild test \
  -project build/image-share-ui/ShareQA.xcodeproj \
  -scheme ShareSender \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath build/image-share-ui/DerivedData \
  -resultBundlePath "build/image-share-ui/results-$(date +%s).xcresult" \
  CODE_SIGNING_ALLOWED=NO
```

Use an English simulator for the UI label assertions. Three tests cover:

- Preview waits for confirmation; cancelling creates no note.
- Cold single-image and warm multiple-image shares open the real editor, leave
  one home route, persist across restart, and do not reopen an acknowledged share.
- An oversized image shows `Try again` and does not create a note.

The fixture fails at startup without `LOCAL_DATA_KEY`. Its verified-note counter
advances only after reading persisted attachments, decrypting and decoding them,
and asserting that their on-disk copies are encrypted. Its JSON report lives at
`Library/Application Support/image-share-verification.json` inside the app's
simulator data container. Screenshots and results remain under ignored `build/`.

This gate does not cover actual app-open failure, physical-device memory limits,
locked-device behavior, distribution provisioning, cloud sync, or App Review.
The responder-chain app launch remains an unsupported iOS mechanism; displaying
a confirmation button does not change that limitation.

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Where Are You is an open-source, Find My–style SwiftUI app (iPhone + iPad, iOS 18.0+) for sharing live locations with friends. It uses Firebase as the backend, with locations and profiles end-to-end encrypted on device, Sign in with Apple, and an iMessage extension for invites. It covers sign-in, keys, profiles and account deletion; friends (invites, key pinning, security codes); location sharing (per friend, one active device, background updates); and arrive/leave alerts with end-to-end encrypted push notifications.

The repo is public and isn't tied to a Firebase project. Never commit `GoogleService-Info.plist` or `Config/Local.xcconfig`.

User-facing docs:
- `README.md`: features, encryption design, the "what the server can see" table, architecture, setup (emulators, signing, connecting a Firebase project), testing, known limitations.
- `CONTRIBUTING.md` and `SECURITY.md`.
- `LICENSE` (MIT).

Keep the README's server-visibility table and limitations accurate whenever the data model or crypto changes.

## Commands

The Xcode project uses Swift Package Manager only (no CocoaPods). Build the `.xcodeproj` directly.

```sh
# Build
xcodebuild -project where-are-you.xcodeproj -scheme where-are-you \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.4' build

# All tests (unit + UI)
xcodebuild -project where-are-you.xcodeproj -scheme where-are-you \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.4' test

# Compile everything (app, Messages extension, tests) without a simulator or signing
xcodebuild -project where-are-you.xcodeproj -scheme where-are-you \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build-for-testing

# Unit tests only / one Swift Testing test (Target/Suite/function())
... test -only-testing:where-are-youTests
... test -only-testing:'where-are-youTests/LocationServiceTests/stopEndsTheStream()'
```

CI (`.github/workflows/ci.yml`) runs three jobs:
- `swift test` on macos-15.
- An app build plus unit tests on the iPhone 16 simulator (UI tests are local only).
- Firebase type-checks, functions unit tests, and the rules and functions emulator tests, on Ubuntu with Node 22 and Java 21.

Always pass `OS=` in `-destination`: without it, xcodebuild assumes the newest installed runtime and fails if that simulator name doesn't exist there. See `xcrun simctl list devices available`. The shared scheme lives in `xcshareddata`. There is no linter or formatter.

```sh
# Crypto, payloads and invites (WAYCore): fast, runs on the Mac
cd Packages/WhereAreYouKit && swift test
swift test --filter SealingTests

# Firebase backend (needs the Firebase CLI and Java; tests run in the emulators)
cd firebase && npm install && npm test             # Firestore rules tests
cd firebase/functions && npm install && npm test   # Cloud Functions tests (emulator)
cd firebase/functions && npm run test:unit         # pure helpers, no emulator (*.unit.test.ts)
npm run typecheck                                  # in either folder; no emulator needed
cd firebase && firebase emulators:start            # local backend for the app
```

## Project configuration

- `Config/Shared.xcconfig` is the project-level base config. It holds `BUNDLE_ID_PREFIX`, the deployment target and `SWIFT_VERSION = 6.0`. It includes the optional `Local.xcconfig`, then derives `KEYCHAIN_ACCESS_GROUP` and `APP_ATTEST_ENVIRONMENT` from those values.
- `Config/Local.xcconfig` is gitignored and holds per-developer `DEVELOPMENT_TEAM` and bundle-ID overrides (see `Local.xcconfig.example`). Never set the team in Xcode's Signing tab: Xcode writes it into the tracked `project.pbxproj`, and a target-level value overrides the xcconfig.
- Don't put `IPHONEOS_DEPLOYMENT_TARGET`, `SWIFT_VERSION` or `DEVELOPMENT_TEAM` in the pbxproj. Project-level pbxproj settings override the xcconfig.
- Targets use synchronized folders (`PBXFileSystemSynchronizedRootGroup`, objectVersion 77), so new files join their target automatically. Non-Swift files become bundle resources. That's why entitlements and partial Info.plists live in `Config/`.
  - App: `where-are-you/`.
  - Messages extension: `WhereAreYouMessages/`.
  - Both app and extension: `Shared/`.
  - Tests: `where-are-youTests/` and `where-are-youUITests/`.
- The `WhereAreYouNotificationService` target (`WhereAreYouNotificationService/`, `Config/NotificationService-Info.plist`) decrypts alert pushes. It links only WAYCore: no Firebase or network. It reads the identity key and the friend directory from the shared Keychain group.
- The `WhereAreYouMessages` target is an iMessage app extension, embedded in the app.
  - Bundle ID `$(BUNDLE_ID_PREFIX).where-are-you.messages`; its `NSExtension` keys are in `Config/Messages-Info.plist`.
  - It shares `KEYCHAIN_ACCESS_GROUP` with the app, so both see the same identity key, pinned keys and Firebase sign-in.
  - It reads the containing app's `GoogleService-Info.plist`, via `BackendConfiguration.containingAppConfigFile()`.
- Info.plist is generated. Standard keys go in as `INFOPLIST_KEY_*` build settings, in both Debug and Release.
  - Custom keys go in `Config/App-Info.plist`, which is merged in:
    - `WAYKeychainAccessGroup` and `WAYInviteLandingURL` (from `INVITE_LANDING_URL` in Shared.xcconfig).
    - The `whereareyou://` URL scheme.
    - `UIBackgroundModes` (location, fetch) and `BGTaskSchedulerPermittedIdentifiers` (`<bundle id>.heartbeat`, which must match `SharingService.refreshTaskIdentifier`).
    - `FirebaseAppDelegateProxyEnabled = NO`: the AppDelegate hands FCM the APNs token itself.
  - The entitlements use `$(APS_ENVIRONMENT)` and `$(APP_ATTEST_ENVIRONMENT)`, which are `development` in Debug and `production` in Release.
- `where-are-you/Preview Content/` is in `DEVELOPMENT_ASSET_PATHS`, so it is left out of archives. `friends.json` there is the fixture data. Its timestamps are relative (`updated_minutes_ago`).
- `where-are-you/Resources/Localizable.xcstrings` is the app's string catalog (English source). Xcode fills it in when building in the IDE; `xcodebuild` doesn't. The extensions don't have catalogs yet.
- Swift 6 language mode with complete concurrency checking. Code must also compile with Xcode 16 (Swift 6.0). Guard iOS 26-only APIs with `#if compiler(>=6.2)` plus `if #available(iOS 26, *)` (see `AddressLookup.swift` and `FriendDetailView.swift`).
- Firebase comes from SPM (`firebase-ios-sdk`, 12.x, pinned in `project.xcworkspace/xcshareddata/swiftpm/Package.resolved`).

## Backend configuration

`BackendConfiguration` (in WAYFirebase, shared with the extension) decides which backend is used:
- **Debug build, no `GoogleService-Info.plist`:** the local emulators (`firebase emulators:start` in `firebase/`), so the app runs straight from a clone.
- **Plist present:** the real Firebase project. Drop the plist into `where-are-you/`; it's gitignored.
- **Overrides:** `USE_FIREBASE_EMULATOR=1` forces the emulators, and `FIREBASE_EMULATOR_HOST` points a device at your Mac.
- **Release build, no plist:** a "Not Configured" screen.

In emulator mode, Sign-in shows a "Sign In with Emulator Test Account" button, which sends the Auth emulator an unsigned JSON ID token, and account deletion skips the Apple steps.

## Architecture

**`Packages/WhereAreYouKit`** is a local Swift package. Its `WAYCore` library has no Firebase dependency, so the app, its future extensions and the test fakes can all use it. It contains:
- **Sealing:** `Sealing.seal` and `Sealing.open` do HPKE in auth mode (X25519, SHA-256, ChaCha20-Poly1305).
  - The associated data binds the payload kind, both uids and both key IDs, so a box can't be moved to another document or opened as another kind.
  - Plaintext is padded to 64-byte blocks so ciphertext size doesn't reveal content length.
  - `open` validates the decrypted payload, because it comes from another person's device.
- **Payloads:** `Profile`, `SharedLocation`, `AlertRequest` and `AlertEvent` conform to `SealablePayload` (a `kind` plus `validate()`). The app uses `Avatar` and `SharedLocation` directly as its model types; app-only helpers such as `coordinate` and `isStale` are extensions in `Models/Friend.swift`.
- **Keys:** `IdentityKey` is the private key; `PublicIdentity` is the public key plus its `keyId` (16 bytes of SHA-256, base64url).
- **Key storage:** `KeyStore` has a `KeychainKeyStore` implementation (synchronizable, `AfterFirstUnlock`, optional shared access group) and an `InMemoryKeyStore`. Keychain behaviour is tested in the app's hosted tests, because `swift test` on macOS has no Keychain entitlements.
- **Invites:** `InviteLink` (token, inviter key ID and optional name in the URL fragment, plus a `<token>.<keyId>` code form).
- **Security codes:** `SecurityCode.digits` produces 60 digits to compare in person.
- **Backend protocols:** `Backend.swift` defines `AuthBackend`, `AccountBackend` and `AppleCredential`. `Friends.swift` defines `FriendsBackend`, `Account`, `ShareDocument`, `InviteDocument` and `InviteError`.
- **Friends logic** (all Mac-testable, against `Tests/WAYCoreTests/TestBackend.swift`):
  - `InviteFlow` creates and accepts invites. Accepting checks the inviter's published key against the invite's key ID before calling the backend, then pins the inviter's key and shares the profile.
  - `ProfileSharing` seals the profile for a friend, and decides when it needs re-sealing.
  - `FriendAssembler` turns friendships, shares, keys and pins into `FriendRecord`s.
  - `AccountLoader` loads an already set-up account, for the extension.
  - `PinnedKeyStore` (Keychain or in-memory) holds each friend's pinned key with a trust level: firstUse, invite or compared.
- **Sharing** (`Sharing.swift`):
  - `SharingSettings` lives at `users/{uid}/private/sharing`: the master switch, friend UIDs, and `activeDeviceId`.
  - `UploadPolicy` throttles uploads: at least 25 m and 30 s apart, plus a 15-minute heartbeat.
  - `LocationSharer` builds `OutgoingShare`s, each carrying a fresh profile so whole-document writes are always valid.
- **Alerts** (`Alerts.swift`):
  - `AlertRequestDocument` has a `requesterCopy` sealed to the requester, so they can list what they set.
  - `AlertPreferences` lives at `private/prefs`. The function enforces receiving; the watched device enforces allowing.
  - `AlertPlanner`:
    - `plan` decrypts and filters requests, then caps them at 20 regions, oldest first.
    - `shouldNotify` fires only on real outside→inside or inside→outside transitions, never on the first state seen.
    - It also seals events and builds request documents.
- **Push** (`PushContent.swift`): `PushContent.text` decrypts push payloads (`kind`, `fromUid`, `toUid`, `box` JSON). `FriendDirectory` and its store hold friends' names and public keys on the device (Keychain, not synced) for the notification extension.

Changing anything bound into the AAD, the HPKE `info` or the padding format breaks every existing ciphertext. Treat these as a wire format and bump `SealedBox.currentVersion` if they change.

**`Packages/WhereAreYouFirebase`** (the `WAYFirebase` library) is the Firebase implementation of those protocols. It's a separate package so `swift test` in WhereAreYouKit never builds Firebase. It contains:
- `FirebaseBootstrap.configure`: App Check (App Attest, DeviceCheck fallback, debug provider in the simulator), the emulator wiring, and the shared Keychain group for Auth.
- `FirebaseAuthBackend`.
- `FirebaseAccountBackend`, covering `users/{uid}` and `users/{uid}/private/profile`, plus the `deleteAccount` callable.
- `FirebaseFriendsBackend`: snapshot listeners on `friendships` and `inboxes/{uid}/shares`, invites, and the `acceptInvite` / `removeFriend` callables. It maps callable failures to `InviteError`.
- `FirebaseSharingBackend` and `FirebaseAlertsBackend`, sharing the snapshot listener helpers in `Listening.swift`.
- `FirebasePushBackend`: FCM token registration, stored at `users/{uid}/devices/{deviceId}`. It uses the token APIs, which Firebase 12 deprecates in favour of an opt-in installation-ID model; that switch is a known follow-up.
- `BackendConfiguration`.

**`firebase/`** holds the backend:
- **Rules:** `firestore.rules` is the source of truth for the data model and who may read or write each path. Content is always a `SealedBox` map, so the rules only check its shape.
- **Functions:** `functions/src` has:
  - `acceptInvite`: a transaction that checks expiry and own invites, caps friends at 100, creates the friendship and uses up the invite.
  - `removeFriend` (`removeFriendship`).
  - `deleteAccount` (`deleteUserData`).
  - `onNotificationEvent` relays a sealed alert event to the requester's devices, if they're still friends and the requester's preferences allow it, then deletes the event.
  - `onAlertRequestCreated` tells the watched person, whatever their preferences.
  - Push construction lives in `pushMessages.ts`, as pure helpers with unit tests. The fallback text in each push must never contain private details.
  - The callables are all safe to retry.
- **Project:** `.firebaserc` points at `demo-where-are-you`, an emulator-only project ID. Forks run `firebase use --add` for their own project.

**App:**
- **App-lifetime services:** iOS can relaunch the app in the background, with no UI, for significant location changes, CLMonitor region events and background refresh. So these services are created in `AppDependencies` at launch, not by views:
  - `AccountProvider` hands the account to services: `SessionModel.onAccountChange` sets it, and `load()` loads it directly when no UI has run.
  - `SharingService` uploads location from the active device. Its sources are `LocationService.onLocation` (foreground), `SignificantChangeMonitor` (background) and `.backgroundTask(.appRefresh)` (heartbeat). A UserDefaults flag restarts monitoring at launch.
  - `AlertService` turns alert requests into `GeofenceMonitoring` regions (`CoreLocationGeofences` wraps one `CLMonitor`). Regions and their last states are kept in UserDefaults; a fired alert posts a sealed `notificationEvent`.
  - `PushService` handles notification permission and the FCM token. `SessionModel.willSignOut` unregisters the device before sign-out. In emulator mode there's no registrar.
- **Session:** `SessionModel` (`@MainActor @Observable`) drives `RootView`: loading → signedOut → settingUp → keyMissing / needsProfile / failed → ready. `signOut()` is async.
  - Setup compares the Keychain key with the published one. With neither, it creates and publishes a key. When the published key isn't on this device, it shows `KeyMissingView` (Try Again, or Create New Key); it never overwrites the published key on its own.
  - It then decrypts the user's own profile, which is sealed to their own key.
  - User actions report failures through `actionError`, shown by `.sessionErrorAlert()`. Attach that alert to only one visible view at a time.
- **Account deletion:** Apple re-authentication (`SystemAppleReauthenticator`), then revoking the Apple token, then the `deleteAccount` function, then removing the local key and signing out.
- **Dependencies:** `App/AppDependencies.swift` builds the services and `.dependencies(_:)` puts them into the environment. Unit tests host the app, so `make()` uses fakes when `XCTestConfigurationFilePath` is set.
- **Fakes:** `Debug/FakeServices.swift` (DEBUG only) has `FakeBackend`, which wires a `FakeAuthBackend`, a `FakeAccountBackend` (an actor, holding the fixture friends' keys) and an `InMemoryKeyStore` together. It also has `InMemorySharingAndAlerts`, `FixtureFriendsBackend`, `InMemoryGeofences`, `NoBackgroundLocation`, and the fake location and address services. UI tests select them with `UITEST_FAKE_SERVICES=1`. `UITEST_SESSION` (signedOut, newUser or ready) and `UITEST_LOCATION_AUTH` pick the state. `UITEST_RESET_STATE=1` wipes the app's UserDefaults, so `@AppStorage` flags such as the location primer don't leak between runs. UI tests repeat these strings because they run in another process.
- **Location:** `LocationService` owns permission state and the user's position through the `LocationProvider` protocol (`CoreLocationProvider` in the app, `FakeLocationProvider` in tests).
  - `start()` never prompts. `requestPermission()` is called from `LocationPrimerView` (shown once, before the first map) or from the map banner's Allow button.
  - `MapScreen` starts and stops it from `scenePhase`.
- **Friends:** `FriendsRepository` (`@MainActor`) streams `[Friend]` and carries the friend actions.
  - `LiveFriendsRepository` combines both listeners and saves the `FriendDirectory` for the notification extension. It loads each friend's key (and reloads it when their share's `senderKeyId` changes), pins first-use keys, and re-seals the user's profile for friends when either key changes. It keeps sharing with a changed key; `keyStatus == .changed` drives the warning.
  - `FixtureFriendsRepository` is in-memory and editable, for previews and UI tests. Ethan's key in the fixture is "changed".
  - `FriendsStore` is created per account in `RootView`'s `SignedInView` (rebuilt for a different account via `.id(account.uid)`), not in `AppDependencies`.
- **Invites in the app:**
  - `AddFriendView` invites with a Messages bubble (`MessageComposeView` with an `MSMessage` built by `Shared/InviteMessage.swift`), creates a copy-paste code, or accepts a code.
  - `whereareyou://invite#…` links (from the extension's "Open Where Are You") go through `.onOpenURL` to `AcceptInviteView`. A pending invite waits for sign-in.
- **Messages extension:** `MessagesViewController` hosts `MessagesRootView`. `MessagesModel` loads the existing account and sends or accepts invite bubbles with `InviteFlow`. Signing in and setup only happen in the app.
- **UI:** on iPhone, `MapScreen` puts `PeopleView` in a persistent bottom sheet; on iPad it's a side panel. Settings opens from the avatar button in `PeopleView`'s toolbar. The map's `selection` and `PeopleView`'s `navigationDestination(item:)` share one `selectedFriendID` binding. Pure map math lives in `MapGeometry`.
- **Logging:** use the `Logger` categories in `App/Logging.swift`. Never log coordinates, names or other personal data.

## Conventions

- File names are PascalCase and match their main type. Each file starts with the Xcode-style header comment (file name, target).
- Unit tests use Swift Testing (`@Test`, `#expect`) with `@testable import where_are_you`. Async state uses the `eventually` helper.
- UI tests use XCTest and find elements by accessibility identifiers such as `friendRow.<id>`, `locationBanner`, `settingsButton`, `profileNameField`, `addFriendButton`, `inviteCodeField`, `securityCode`, `keyChangedNotice`, `shareWithFriendToggle`, `addLocationAlert`, `alertPlaceName` and `shareMyLocationToggle`. Tap SwiftUI toggles at their right edge (the switch), not their center. Rows below the People sheet's peek height need the sheet dragged up (via the "Sheet Grabber" button) before they can be tapped. Query buttons with `app.buttons[...]`, because an identifier on a button also matches its children. `LabeledContent` rows read as a single "Label, value" static text.
- The original build plan (phases 1–7, all implemented) is at `~/.claude/plans/the-premise-behind-this-glowing-scott.md`, on the author's machine only. The README is the public source of truth.

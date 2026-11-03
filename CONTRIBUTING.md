# Contributing

Thanks for helping out! Bug reports, fixes and improvements are all welcome.

## Getting set up

Follow [Getting started](README.md#getting-started). The quickest loop is the Firebase emulators plus the simulator: no Firebase project or Apple Developer account needed.

## Before opening a pull request

- **Run the tests that cover your change.** All of them are listed in [Testing](README.md#testing). CI runs the package tests, the app's unit tests, and the Firebase rules and functions tests.
- **Swift 6 language mode is on**, with complete concurrency checking. Please don't add warnings.
- **Match the surrounding code:** PascalCase file names that match their main type, the Xcode header comment, and Swift Testing (`@Test`, `#expect`) for unit tests.
- **Keep secrets and personal settings out of commits.** Never commit `GoogleService-Info.plist` or `Config/Local.xcconfig`. Don't set a team in Xcode's Signing tab: it writes your team ID into `project.pbxproj`.
- **Never log personal data:** no coordinates, names or place names. Use the `Logger` categories in `where-are-you/App/Logging.swift`.

## Changing the encryption or data model

- **The wire format.** Everything bound into a sealed box is a wire format: the HPKE `info`, the associated data, the padding and the payload fields. Changing any of it breaks existing data. Bump `SealedBox.currentVersion` and handle the old version, or explain in the PR why that isn't needed.
- **New Firestore fields or documents** need matching changes in `firebase/firestore.rules`, plus rules tests in `firebase/tests/`.
- **Anything new the server can see** belongs in the "What the server can and can't see" table in the README.

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org/): `type(scope): description`, for example `fix(sharing): skip friends without a published key`.

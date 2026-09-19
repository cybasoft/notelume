# Building and Releasing NoteLume

This document explains how to build and test NoteLume locally and describes the project's official release process.

Contributors can build and test NoteLume without Apple signing credentials. Official releases are prepared by project maintainers and distributed through GitHub Releases.

## Prerequisites

- macOS 14 or later.
- A full Xcode installation with Swift 6 or newer.
- Xcode Command Line Tools.
- [Homebrew](https://brew.sh/).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen).
- [GitHub CLI](https://cli.github.com/) if you intend to interact with GitHub from the command line.

Install the required tools:

```bash
brew install xcodegen gh
```

Select the full Xcode installation if necessary:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Verify your development environment:

```bash
xcodebuild -version
swift --version
xcodegen --version
```

## Build and Test

Run commands from the repository root.

### Run the Core tests

```bash
swift test --package-path Core
```

### Build the application

```bash
bash scripts/build.sh
```

The debug build quits any running NoteLume instance and launches the newly
built app. To open that app again:

```bash
open build/DerivedData/Build/Products/Debug/NoteLume.app
```

### Build a release configuration

```bash
bash scripts/build.sh Release 1.0.0
```

The build script uses XcodeGen to generate the Xcode project from `App/project.yml`. Generated project files and build artifacts should remain untracked unless the repository explicitly requires otherwise.

By default, builds are unsigned. Set `SIGNING_IDENTITY` to a certificate's full
name and `TEAM_ID` to its Apple Developer team ID to request a signed build.

The application targets macOS 14 and later and is intended to support both Apple Silicon and Intel Macs. Verify the architecture of the resulting binaries when making changes to the build configuration.

## Signing and Notarization

The release script signs official macOS releases with an Apple Developer ID
Application certificate and submits them to Apple's notarization service.

These operations require appropriate Apple Developer credentials and a valid signing configuration. They are not required to run the automated tests or build an unsigned development version.

Signing identities, private keys, passwords, API keys, and notarization credentials must never be committed to the repository.

Install a Developer ID Application certificate and its private key in your
Keychain. The release script supplies the maintainer's default team ID and
`notelume-notary` profile, so normal releases do not require repeated exports.
To configure credentials for a different team or profile, use:

```bash
export TEAM_ID=YOUR_APPLE_TEAM_ID
export NOTARY_PROFILE=notelume-notary
xcrun notarytool store-credentials "$NOTARY_PROFILE" \
  --apple-id YOUR_APPLE_ID --team-id "$TEAM_ID"
```

Replace the placeholders and enter the app-specific password directly at the
prompt. The credentials stay in Keychain. Team IDs identify an Apple Developer
team; they are not passwords or signing credentials. Set `TEAM_ID` or
`NOTARY_PROFILE` to override the script's defaults. The script selects a
Developer ID identity for the chosen team; set `SIGNING_IDENTITY` to its full
certificate name if you need to select a specific identity.

## Continuous Integration

GitHub Actions runs automated checks and unsigned builds for supported pushes and pull requests.

CI builds do not require maintainers' Apple signing credentials. A successful CI build verifies the checks implemented by the workflow, but does not by itself establish that a release is signed, notarized, or ready for distribution.

## Official Releases

Official releases are published on the project's GitHub Releases page.

Release versions use semantic version tags, such as `v1.0.0`. Prerelease tags are not supported by the current release process.

Published release artifacts may include:

- A disk image (`.dmg`) for installation.
- A ZIP archive containing the application.
- A `SHA256SUMS.txt` file for artifact integrity verification.

Use the GitHub Releases page to obtain the official distribution. Verify downloaded artifacts against the published checksums when available.

Do not treat locally generated or unsigned builds as official releases.

From a clean, committed working tree, build and notarize a release locally:

```bash
bash scripts/release.sh v1.0.0
```

Artifacts are written to `build/release/v1.0.0/`. The app and DMG are notarized
and stapled; the ZIP contains the stapled app. The script refuses to overwrite
an existing artifact directory. Test the resulting DMG before publishing.

Adding `--publish` builds the release, pushes the current source commit and tag,
and creates a GitHub release. It requires an authenticated GitHub CLI, a public
repository, and the repository's default branch. It does not publish artifacts
from an earlier local build; move the existing directory aside to rebuild, or
publish the tested artifacts manually with their exact source commit.

## Licensing and Third-Party Notices

The community edition of NoteLume is licensed under **GPL-3.0-only**. See the [LICENSE](../LICENSE) file for the complete license terms.

Third-party dependencies retain their respective licenses. These may include:

- Yams: MIT.
- GRDB.swift: MIT.
- Swift Markdown: Apache-2.0 with Swift exceptions.
- Swift cmark: Apache-2.0 with Swift exceptions and additional BSD-licensed code.

This list is informational, not a substitute for reviewing the licenses and notices applicable to the exact dependency versions distributed with a release.

Preserve required copyright notices, license texts, and attribution when redistributing dependencies or application binaries.

For contribution requirements, see [CONTRIBUTING.md](../CONTRIBUTING.md).

### Before Publishing Binaries

- Include the GPL license and required third-party license texts and notices
  with the distributed app. The build bundles NoteLume's `LICENSE`; dependency
  notices still need to be assembled and checked for the exact shipped versions.
- Provide free access to the exact corresponding source, build scripts, and
  required dependency source. Put an explicit source link beside the binary
  downloads. GitHub's automatic source archive does not include dependency
  checkouts; provide them or an equivalent compliant source distribution.
- Verify signing, notarization, fresh installation, upgrades, folder access,
  editing, reminders, and backup/recovery on the release artifacts.
- Confirm contributor rights and recorded CLA acknowledgments. Obtain legal
  review of the CLA before relying on it for alternative licensing.

## Troubleshooting

### Xcode or Swift version errors

Confirm that the full Xcode installation is selected:

```bash
xcode-select -p
xcodebuild -version
swift --version
```

### Generated project or build errors

Ensure XcodeGen is installed and that `App/project.yml` is valid. Review the build output for configuration or dependency errors.

### Signing or Gatekeeper errors

Unsigned development builds may trigger macOS security warnings. Official distribution builds should use the project's documented signing and notarization process.

If a downloaded official release fails verification, do not bypass the warning
without first checking the artifact's source and integrity. Report ordinary
release problems through [GitHub Issues](https://github.com/cybasoft/notelume/issues).
For security-sensitive details, first ask the maintainers for a private contact
channel without posting the vulnerability or private data publicly.

## Contributing

Contributions are welcome in accordance with the project's contribution guidelines.

Before submitting a change, run the available tests and ensure that generated files, credentials, personal information, and unrelated local changes are not included in your commit.

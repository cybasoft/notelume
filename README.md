# NoteLume (macOS, SwiftUI)

Markdown sticky notes stored as plain `.md` files. macOS 14 or newer.

## Install

Download a signed, notarized DMG from [GitHub Releases](https://github.com/cybasoft/notelume/releases)
when a release is available, then drag NoteLume into Applications.

- `Core/` – Swift package `NoteLumeCore` (format, repository, index, reconciler, sessions, reminders). Run `swift test --package-path Core` from the repository root.
- `App/` – macOS app (XcodeGen). `cd App && xcodegen generate && open NoteLume.xcodeproj`. macOS 14+, sandboxed.
- `docs/` – FORMAT.md, BACKUP_RECOVERY.md.

Core has no AppKit dependency apart from the FSEvents watcher (`#if os(macOS)`), so an iOS target can reuse it.

## Editing Notes

In **Settings > Notes > Open notes in**, choose **App window** to edit notes
beside a selectable sidebar list. Sticky notes appear first in that list.
The same editor, labels, colors, reminders, version history, and recovery
controls are available in both modes. Choose **Separate windows** to return
to individual note windows. This preference is saved only on this Mac.

## Generating debug app

```bash
bash scripts/build.sh
open build/DerivedData/Build/Products/Debug/NoteLume.app
```

Requires Xcode (Swift 6+) and XcodeGen (`brew install xcodegen`). The default
debug build quits any running NoteLume instance and launches the newly built app.

## Releases

Maintainers must configure Developer ID signing and Keychain notarization
credentials as described in [the release guide](docs/RELEASING.md) before using:

```bash
bash scripts/release.sh v1.0.0 --publish
```

See [the release guide](docs/RELEASING.md) for Developer ID signing, Keychain
notarization setup, local builds, and GitHub publishing. GitHub Actions tests the
core package and builds the universal macOS app on pushes to `main` and pull requests.

## Contributing

Issues and pull requests are welcome. Run `swift test --package-path Core` and
`bash scripts/build.sh Release` before submitting changes. Read the
[contribution policy](CONTRIBUTING.md) before submitting code; external code
contributions are submitted under [the CLA](CLA.md), with agreement confirmed
in the pull request. Storage and recovery
behavior is documented in [docs/FORMAT.md](docs/FORMAT.md) and
[docs/BACKUP_RECOVERY.md](docs/BACKUP_RECOVERY.md).

## License

Copyright (c) 2026 NoteLume contributors.

NoteLume's community edition is free software licensed under the
[GNU General Public License, version 3 only](LICENSE) (`GPL-3.0-only`). You may
use, modify, and redistribute it, including commercially, under those terms.
Distributed derivatives must comply with GPLv3's source-sharing requirements.
NoteLume is provided without warranty; see the license for details.

The community edition is free to use. Paid services and support may be offered
separately. A future proprietary edition would require separate licensing rights
for all included code; the [contribution policy](CONTRIBUTING.md) preserves that
option without changing recipients' rights to existing GPL releases.

Third-party dependencies retain their own licenses. Your notes and other user
data are not licensed under GPL merely because you create them with NoteLume.

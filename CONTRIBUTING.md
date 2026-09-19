# Contributing to NoteLume

## Community Edition

NoteLume's community edition is licensed under the
[GNU General Public License, version 3 only](LICENSE) (`GPL-3.0-only`). It is
free to use, and paid services or support may be offered separately. Commercial
use and GPL-compliant redistribution are allowed; GPLv3 is not a noncommercial
license.

## Getting Started

Bug reports, suggestions, documentation improvements, and pull requests are
welcome. Small fixes can go straight to a pull request. For substantial changes,
open an issue first so we can agree on the direction before you invest time.

When reporting a bug, include steps to reproduce, the expected and actual
behavior, and your macOS and NoteLume versions. Do not share private note content.

## Contributor License Agreement

Read [the CLA](CLA.md) before submitting a contribution. By intentionally
submitting a contribution, you agree to its terms. Confirm your agreement using
the pull request checkbox or the CLA's acknowledgment statement, with an
immutable link to the CLA revision you reviewed. Maintainers can supply this
link. No separate paperwork or signing service is required for individual
contributions. Contributions offered through other channels must have an
associated acknowledgment record before acceptance.

You retain your copyright. The CLA lets Cybasoft, LLC distribute your
contribution under GPLv3 and alternative licenses, including a possible future
proprietary edition. Existing GPL releases remain GPL, and no proprietary
license is granted to users by this repository.

Bug reports, questions, suggestions, and testing feedback do not require CLA
acceptance unless you intentionally offer code or other copyrightable material
for inclusion. If your employer or someone else owns the contribution, obtain
their authorization before submitting it. An authorized entity representative
must identify the entity and confirm their authority to accept the CLA; evidence
may be requested privately when necessary.

If a pull request contains work from multiple contributors, each must confirm
agreement in the pull request, identifying their contributions. You cannot
accept the CLA on someone else's behalf without authorization. Maintainers
verify all commit authors and co-authors before merging, including when using
squash merges. Record each contributor's GitHub identity, acknowledgment link
and timestamp, covered contributions, pull request, and exact CLA commit SHA.
Do not merge until every contributor is covered. This is a manual check, not
an automated merge gate; no CLA bot is installed. Collect additional identity
or authorization details only when needed, using a private channel.

Identify third-party material, including dependencies and assets, with its
source, license, and required notices. Disclose substantial AI-generated
material and known provenance or licensing restrictions; review and test it
like any other contribution. The CLA does not grant rights you do not own or
override third-party licenses. Maintainers may ask for clarification or decline
a contribution with unresolved rights. These requirements do not restrict
anyone's GPL rights to use, modify, or redistribute the community edition.

## Development Checks

Use macOS 14 or newer, Xcode with Swift 6+, and XcodeGen. From the repository
root, run:

```bash
swift test --package-path Core
bash scripts/build.sh Release
```

Keep patches focused and include tests for behavioral changes. Describe the
change, its motivation, and how it was tested in the pull request. Do not include
private notes, credentials, signing certificates, or generated build output.

See [docs/FORMAT.md](docs/FORMAT.md) and
[docs/BACKUP_RECOVERY.md](docs/BACKUP_RECOVERY.md) before changing storage or
recovery behavior, and [docs/RELEASING.md](docs/RELEASING.md) for release checks.

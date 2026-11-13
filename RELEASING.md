# Release signing

Releases are signed with a self-signed certificate; the in-app updater and `install.sh` reject downloads that aren't. Each release also has a [build provenance attestation](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations): `gh attestation verify Vantage.app.zip --repo SchoofsEbert/vantage-mac`.

Pushing a `v*` tag runs the release workflow. It builds and tests the tag without any secrets, then the `release` environment signs the build. Only that signing step sees the certificate, and only for a tag on `main`. The workflow can be re-run for the same tag; it updates the existing release and cask.

For maintainers, the certificate's safety depends on these repository settings, which `scripts/configure-github.sh` applies (re-run it any time):

- **Tag ruleset** for `v*`: only admins may create tags, and nobody may move or delete them. A tag runs the release workflow from its own commit, so this is what keeps others away from the signing step.
- **Environments `release` and `homebrew-tap`**: deployments from `v*` tags only.

The signing and tap secrets are set with `gh secret set`.

Add required reviewers to the `release` environment if anyone else gets write access.

## The rename from MissionStrike

The certificate, the `MISSIONSTRIKE_P12_*` secrets, `~/.missionstrike-signing` and the bundle identifier `io.github.schoofsebert.missionstrike` keep the old name: changing the identifier or certificate would cost every user their Accessibility grant and stop their updates.

Copies of MissionStrike 2.12.2 and older only read `releases/latest` of `SchoofsEbert/MissionStrike` (GitHub redirects it to `vantage-mac`) and only install an asset named `MissionStrike.app.zip`. So:

- Every release ships `MissionStrike.app.zip` next to `Vantage.app.zip`, and `LegacyBundleRename` renames such an install to Vantage.app. Keep both: there's no later stepping stone for those copies, and they cost a few lines.
- Never create a new repository named `SchoofsEbert/MissionStrike`; it would break the redirect.
- The first Vantage release went out in this order: rename the repository, push `Casks/vantage-mac.rb` and `cask_renames.json` to the tap, then tag.

Keep an offline copy of the P12 and its password. If the certificate expires, is lost, or may have leaked:

1. If it may have leaked, delete the signing secrets at once so the workflow can't sign with it.
2. Create a new self-signed code signing certificate named "MissionStrike Code Signing", and store its P12 and password with `gh secret set`.
3. Replace the certificate hash in `CodeSigning.swift` and `install.sh`, and release a new version.
4. Tell users to reinstall with Homebrew or the install script. The updater in their copy only accepts the old certificate, so it won't install the new release, and macOS asks for Accessibility again because the signature changed. If the old key leaked, say so, since anyone holding it can sign an update that older copies accept.

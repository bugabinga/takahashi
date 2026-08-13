---
id: TAKA-PLAN-KD6QCZL0
type: plan
title: Implement release process
spec: TAKA-SPEC-R3L8X2Q7
status: done
---

# Implement release process

## Build identity

- Rename the installed executable and CLI usage text to `taka`.
- Reset package metadata version to `0.0.0`.
- Keep package metadata version aligned with release tags.
- Delete the obsolete local and remote `v0.0.0-alpha` branch.

## Release workflow

- Restrict the trigger to version tags.
- Build natively on Linux, macOS, and Windows for x86_64 and ARM64.
- Install Zig through a pinned, verified setup action.
- Run tests and formatting checks on every target before packaging.
- Build optimized executables.

## Assets

- Package Unix targets as `.tar.gz` and Windows targets as `.zip`.
- Include the executable, project license, and third-party notices.
- Name assets with product, version, platform, and architecture.
- Generate one `SHA256SUMS` file after collecting all assets.

## Release creation

- Create one draft release only after every target succeeds.
- Generate release notes from GitHub history.
- Mark suffixed versions as prereleases.
- Require the pushed tag to exist.
- Grant write permission only to the release job.

## Maintenance

- Pin external actions to immutable commit SHAs.
- Add automated GitHub Actions dependency updates.
- Enable immutable releases after one successful reviewed release.

## Verification

- Validate workflow syntax.
- Run local tests, formatting, and a full build.
- Publish a disposable prerelease tag.
- Verify six bundles, names, contents, checksums, notes, and draft state.
- Delete the disposable draft and tag before the first real release.

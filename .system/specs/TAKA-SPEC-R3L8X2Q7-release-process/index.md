---
id: TAKA-SPEC-R3L8X2Q7
type: spec
title: Release process
---

# Release process

## Intent

Turn a pushed version tag into complete, reviewable GitHub release binaries.

## Scope

- Linux, macOS, and Windows.
- x86_64 and ARM64 for each platform.
- GitHub release assets, notes, checksums, and publication state.

Package-manager distribution and in-app updates are out of scope.

## Behavior

- A `vX.Y.Z` tag starts one release.
- A suffixed version, such as `vX.Y.Z-alpha`, creates a prerelease.
- Every supported target produces an optimized native `taka` executable.
- Unix bundles use `.tar.gz`; Windows bundles use `.zip`.
- Each bundle contains only the executable and required license notices.
- README and specification files are excluded from bundles.
- One SHA-256 checksum file covers every bundle.
- Release notes summarize changes since the previous release.
- The release remains a draft for human review before publication.

## Constraints

- Tests and formatting checks must pass before release creation.
- Failed or incomplete target builds must not create a release.
- Asset names must identify product, version, platform, and architecture.
- Tags and published assets must not be replaced.
- macOS and Windows binaries are initially unsigned.
- Release consumers must not need Zig or repository sources.

## Acceptance criteria

- Pushing one valid version tag creates one draft GitHub release.
- The draft contains six bundles: three platforms by two architectures.
- Every checksum verifies its corresponding downloaded bundle.
- Extracting a bundle yields a runnable `taka` executable and license notices.
- Stable releases are not marked prerelease; suffixed versions are.
- No release is created when any required check or build fails.

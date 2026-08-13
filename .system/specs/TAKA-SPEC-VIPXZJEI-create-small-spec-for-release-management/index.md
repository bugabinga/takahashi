---
id: TAKA-SPEC-VIPXZJEI
type: spec
title: Release management
---

# Release management

## Intent

Reduce a release to one explicit action while keeping version intent and publication under human control.

## Scope

- SemVer selection and validation.
- Package-version updates.
- Required checks.
- Signed release commits and tags.
- Atomic publication of the commit and tag.

Release artifact creation remains governed by TAKA-SPEC-R3L8X2Q7.

## Behavior

- Accept `patch`, `minor`, `major`, or an explicit SemVer version.
- Derive named bumps from the current package version.
- Accept explicit prerelease versions such as `0.1.0-alpha.1` and `0.1.0-rc.1`.
- Reject malformed, duplicate, or decreasing versions.
- Require a clean `trunk` synchronized with its upstream.
- Update the package version before running required checks.
- Create a signed release commit and signed annotated `vX.Y.Z` tag only after checks pass.
- Publish the release commit and tag together.
- Leave the generated GitHub release as a draft for human review and publication.

## Constraints

- The user chooses the compatibility bump; it cannot be inferred reliably.
- Package version, commit, and tag must identify the same release.
- Existing tags and releases must never be replaced.
- Failure must not publish a partial release.
- Prerelease labels have only SemVer syntax and precedence semantics.

## Acceptance criteria

- From `1.4.2`, `patch`, `minor`, and `major` select `1.4.3`, `1.5.0`, and `2.0.0`.
- An explicit version such as `0.1.0-beta.1` is accepted when it advances the current version.
- Dirty, unsynchronized, invalid, duplicate, and decreasing releases are rejected before publication.
- Failed checks create no published commit or tag.
- A successful release aligns the package version, signed commit, and signed tag.
- A successful push starts the existing draft-release workflow.

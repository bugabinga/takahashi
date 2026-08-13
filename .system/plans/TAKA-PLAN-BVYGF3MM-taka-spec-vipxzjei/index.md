---
id: TAKA-PLAN-BVYGF3MM
type: plan
title: Implement release management
spec: TAKA-SPEC-VIPXZJEI
status: done
---

# Implement release management

## Command

- Add one host-native Zig release tool.
- Expose it as `zig build release -- <request>`.
- Accept one named bump or one explicit SemVer version.
- Keep release management outside the product CLI.

## Version handling

- Read the current version from `build.zig.zon`.
- Use the standard-library SemVer parser and precedence rules.
- Increment the requested numeric component and clear lower components and suffixes.
- Validate explicit versions before changing files.
- Replace only the manifest version value; preserve surrounding content.
- Support SemVer build metadata in release-tag validation.

## Preflight

- Require `trunk`, a clean worktree, and an upstream.
- Fetch the upstream branch and tags.
- Require local `trunk` to equal upstream `trunk`.
- Reject an existing release tag.
- Require an SSH signing format and signing key.

## Release transaction

- Update the manifest to the selected version.
- Run formatting checks and tests against the updated manifest.
- Stage only the manifest.
- Create a signed release commit with the version in its subject.
- Create a signed annotated tag for the same version.
- Atomically push `trunk` and the tag to `origin`.
- Let the existing release workflow create the draft release.

## Failure behavior

- Restore the manifest when validation or checks fail before commit creation.
- Never overwrite commits or tags.
- Preserve local commit and tag state when signing or publication fails.
- Report the failed stage and exact recovery action.

## Tests

- Cover named bumps across patch, minor, major, prerelease, and build metadata versions.
- Cover explicit-version parsing, ordering, duplicates, and decreases.
- Cover targeted manifest reading and replacement.
- Cover preflight result interpretation without network access.
- Import the release tool tests from the headless test root.

## Verification

- Run formatting and headless tests.
- Confirm invalid requests and dirty or unsynchronized repositories make no changes.
- Confirm a failed check restores the original manifest.
- Run one disposable prerelease through signed commit, signed tag, atomic push, and draft creation.
- Verify package version, commit, tag, and draft release agree.

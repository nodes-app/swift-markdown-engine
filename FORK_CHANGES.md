# NoFray fork changes

This fork release is derived from `nodes-app/swift-markdown-engine` at the
immutable upstream baseline `08ff3c07b198ed639f595d0279ebac62c0410bc7`.
The latest published upstream tag when the baseline was frozen was `0.12.0` at
`e5f7607fc4021181056ef7a09dbb7573dc0237d9`. The fork baseline includes the
upstream commits after that tag through `08ff3c07b198ed639f595d0279ebac62c0410bc7`
and no commits after that baseline SHA.

## Governance

- `main` remains an unmodified mirror of the frozen upstream baseline.
- Each upstreamable change lives on its own topic branch and draft pull request.
- `nofray/integration` is the release branch that combines those reviewed topic
  commits. It is not merged into `main`.
- The release tag `0.12.1-nofray.1` points to one integration commit and must
  never be moved or reused.
- When upstream accepts an equivalent change, its fork commit is removed during
  a deliberate rebase rather than maintained as a permanent parallel API.

## Changes from the upstream baseline

The exact topic and integration commit identities are:

| Change | Topic commit(s) | Integration commit(s) | Upstream PR |
| --- | --- | --- | --- |
| Focus binding | `d5a05413855ba7470a891f9385cbb5c340fae7c1` | `b19a6ebe92d632df50b01b93023a60978e9092ae` | [#175](https://github.com/nodes-app/swift-markdown-engine/pull/175) |
| Unhandled commands | `bc5e27a2769f50d547748c0fbad82e3fd0107103`, `b0ddb9fc1cdca9261b5617a23df5d4a7496cb6b3` | `f564a90b4bad80febadb657d898f5da9d125d932`, `a017c5a19ed306f839b3d6870d02451fb1b537df` | [#176](https://github.com/nodes-app/swift-markdown-engine/pull/176) |
| Block formatting | `8285c11ab23f5f29ee36358a5f07232d47e83922` | `eae29d89ce585c52153e8323b781034824623086` | [#177](https://github.com/nodes-app/swift-markdown-engine/pull/177) |
| Read-only checkbox | `098dc62883d42ff67de20e89fb6730b1501d043b`, `c66fb23d6ecbdd1909a307560f183ae8ed5c8390` | `fc0a97c7d9fb84504ba2d18c70d0684d0bae2b0e`, `f9f5bdc81247ce2540c56262414f7a88af50ec00` | [#178](https://github.com/nodes-app/swift-markdown-engine/pull/178) |

1. Optional two-way editor focus binding. Upstream draft PR
   [#175](https://github.com/nodes-app/swift-markdown-engine/pull/175).
2. Synchronous host fallback for unhandled Escape, Tab, and Shift-Tab commands,
   after preview and list behavior decline them. Upstream draft PR
   [#176](https://github.com/nodes-app/swift-markdown-engine/pull/176).
3. Paragraph and task-list block-formatting actions that preserve line endings,
   selections, attributes, and storage-form wiki-link metadata. Upstream draft
   PR [#177](https://github.com/nodes-app/swift-markdown-engine/pull/177).
4. Opt-in task-checkbox interaction in read-only editors, while ordinary text
   input remains disabled. The sanctioned mutation path reports exact edits and
   supports document-scoped undo and redo. Upstream draft PR
   [#178](https://github.com/nodes-app/swift-markdown-engine/pull/178).

These changes satisfy the reusable engine-side contract discussed in upstream
issue [#173](https://github.com/nodes-app/swift-markdown-engine/issues/173).
No NoFray application integration is included in this release.

## Release validation

Validated on macOS on 2026-09-03:

- `swift test --filter` over the five relevant suites: 43 tests in 5 suites
  passed, including existing per-document undo coverage.
- Clean `swift test`: 510 tests in 72 suites passed.
- `swift build --product MarkdownEngine`: succeeded.
- SwiftPM graph inspection: the `MarkdownEngine` target has no dependencies and
  the `MarkdownEngine` product contains only that target.
- Debug build of the `MarkdownEngineDemo` macOS scheme with code signing
  disabled: succeeded.
- `git diff --check`: clean.

No package dependency, platform requirement, or license was changed. The
upstream Apache License 2.0 remains in `LICENSE`; the upstream baseline contains
no `NOTICE` file. Every modified pre-existing file carries a dated pointer to
this change record; newly added source and test files are documented here and
remain covered by the repository's Apache-2.0 license.

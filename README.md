# RepoKit

What every Pivetta repo shares about how it is built and checked, as one submodule
(`deps/repokit`, listed in the repo's `deps/deps.json` like any shared package) instead of copies
kept in step by hand.

| File | What | Used by a repo as |
|---|---|---|
| `deps.mts` | the shared-packages pipeline: `status`, `prepare`, `check`, `bump`; vite aliases and dedupe | `scripts/deps.mts`, a shim that re-exports it and runs `main()` |
| `check.ps1` | the step runner (`x`, `withEnv`, `withDevServer`, `Invoke-Check`) | dot-sourced by `scripts/check.ps1`, which keeps only its steps |
| `check.sh` | the same runner for bash (`step`, `x`, `withEnv`, `withDevServer`, `invoke_check`; same flags, output and exit codes) | sourced by `scripts/check.sh`, the twin of `scripts/check.ps1` |
| `rust-toolchain.toml` | the Rust channel of every Pivetta repo | `deps.mts check` compares the repo's `rust-toolchain.toml` and `deploy/Dockerfile.cross` to it |
| `prune.ps1` | removes worktrees whose branch is merged into main (clean ones only, links unlinked first) and merged local branches (`git branch -d`); lists stale unmerged ones | `powershell -File deps/repokit/prune.ps1 [-DryRun]` from the repo; on Linux and macOS `bash deps/repokit/prune.sh [-DryRun]` |

## Rules `deps.mts check` adds

- Every submodule URL in `.gitmodules` is SSH: `git@github.com:<owner>/<repo>.git`.
- The repo's `rust-toolchain.toml` channel (and `FROM rust:<version>` in `deploy/Dockerfile.cross`)
  equals this repo's `rust-toolchain.toml` channel. A repo on its own Rust says so in its
  `deps/deps.json`, `"repokit": { "repo": "Pivetta/RepoKit", "toolchain": "own" }`, and gets a
  warning instead.
- A dep has no submodules of its own, unless its `deps/deps.json` entry says `"submodules": true`
  (say, a tool whose npm workspace packages are submodules). Then `prepare` checks them out
  recursively and runs `npm ci` in the dep, and `check` holds them to their pins and their
  `.gitmodules` to SSH as well.

## A repo's shim

```ts
// scripts/deps.mts
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { main } from '../deps/repokit/deps.mts';
export * from '../deps/repokit/deps.mts';
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main(process.argv.slice(2), dirname(fileURLToPath(import.meta.url)));
```

## Changing something here

1. Commit and push to `main` here.
2. In each repo: `node scripts/deps.mts bump repokit`, run `scripts/check.ps1` (or `scripts/check.sh`), commit the pin alone.

Keep `check.ps1` ASCII (Windows PowerShell 5.1 reads BOM-less files in the ANSI code page), each
`.ps1` and its `.sh` twin doing the same thing, and
`deps.mts` free of anything one repo alone needs.

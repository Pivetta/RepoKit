# RepoKit

What every Pivetta repo shares about how it is built and checked, as one submodule
(`deps/repokit`, listed in the repo's `deps/deps.json` like any shared package) instead of copies
kept in step by hand.

| File | What | Used by a repo as |
|---|---|---|
| `deps.mts` | the shared-packages pipeline: `status`, `prepare`, `check`, `bump`; vite aliases and dedupe | `scripts/deps.mts`, a shim that re-exports it and runs `main()` |
| `check.ps1` | the step runner (`x`, `withEnv`, `withDevServer`, `Invoke-Check`) | dot-sourced by `scripts/check.ps1`, which keeps only its steps |
| `rust-toolchain.toml` | the Rust channel of every Pivetta repo | `deps.mts check` compares the repo's `rust-toolchain.toml` and `deploy/Dockerfile.cross` to it |

## Rules `deps.mts check` adds

- Every submodule URL in `.gitmodules` is SSH: `git@github.com:<owner>/<repo>.git`.
- The repo's `rust-toolchain.toml` channel (and `FROM rust:<version>` in `deploy/Dockerfile.cross`)
  equals this repo's `rust-toolchain.toml` channel. A repo on its own Rust says so in its
  `deps/deps.json`, `"repokit": { "repo": "Pivetta/RepoKit", "toolchain": "own" }`, and gets a
  warning instead.

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
2. In each repo: `node scripts/deps.mts bump repokit`, run `scripts/check.ps1`, commit the pin alone.

Keep `check.ps1` ASCII (Windows PowerShell 5.1 reads BOM-less files in the ANSI code page) and
`deps.mts` free of anything one repo alone needs.

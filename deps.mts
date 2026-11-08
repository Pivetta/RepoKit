// The shared packages: git submodules under deps/, listed in deps/deps.json, all through one
// pipeline: wired as submodules, consumed through their own
// package.json `exports` (vite/vitest aliases from depAliases(), tsconfig `paths` checked here) or
// as Cargo path dependencies, prepared (`npm ci` + their `prepare` scripts) in place, pinned on
// their origin/main, checked and bumped by this script.
//
// One copy for every Pivetta repo: RepoKit (github Pivetta/RepoKit), the deps/repokit submodule.
// A repo's scripts/deps.mts re-exports this file and runs main(), so vite configs, deploys and
// docs keep that path. `check` also holds the repo to RepoKit's rules: every submodule URL is SSH
// (git@github.com:owner/repo.git), and rust-toolchain.toml (and deploy/Dockerfile.cross, where
// there is one) use the channel of RepoKit's rust-toolchain.toml.
//
//   node scripts/deps.mts status                 what is pinned, checked out, dirty, on origin
//   node scripts/deps.mts prepare [name...]      npm ci + prepare scripts where needed (stamped)
//   node scripts/deps.mts prepare --consumer .   the same for the deps one consumer imports (its
//                                               npm pre* hooks: predev, prebuild, pretest, ...)
//   node scripts/deps.mts check                  the gates (scripts/check.ps1 step `deps`)
//   node scripts/deps.mts bump <name> [rev]      fetch, show the log, move the pin to rev (default
//                                               origin/<branch>), prepare and stage it; then run
//                                               scripts/check.ps1 and commit the pin alone
//
// git: $PIVETTA_GIT, else Git for Windows (`...\cmd\git.exe`) before any other git on PATH (an
// msys git has no GitHub key and sees CRLF checkouts as modified). Needs node 22.18 or later.
import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { delimiter, dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

/** A deps.json entry. `toolchain: "own"` (on the repokit entry only): the repo keeps its own Rust
 *  channel, and check only warns that it differs from RepoKit's. */
export type Dep = { repo: string; branch?: string; consumers?: string[]; prepare?: string[]; note?: string; toolchain?: 'own' };
export type Entry = { spec: string; file: string; types: string };

/** The repository root: the nearest folder at or above `from` with deps/deps.json. */
export function findRoot(from: string): string {
  for (let d = resolve(from); ; d = dirname(d)) {
    if (existsSync(join(d, 'deps', 'deps.json'))) return d;
    if (dirname(d) === d) throw new Error(`no deps/deps.json at or above ${from}`);
  }
}

export function manifest(root: string): Record<string, Dep> {
  return JSON.parse(readFileSync(join(root, 'deps', 'deps.json'), 'utf8')) as Record<string, Dep>;
}

function readJson(path: string): Record<string, unknown> {
  return JSON.parse(readFileSync(path, 'utf8').replace(/^﻿/, '')) as Record<string, unknown>;
}

/** The import entries of deps/<name>: its package.json `exports`, as absolute files. A wildcard
 *  export (`"./*": "./src/*.ts"`) keeps its `*` in spec, file and types; exact ones come first. */
export function entries(root: string, name: string): Entry[] {
  const dir = join(root, 'deps', name);
  const pkgPath = join(dir, 'package.json');
  if (!existsSync(pkgPath)) return [];
  const pkg = readJson(pkgPath) as { name: string; exports?: Record<string, string | Record<string, string>> };
  const out: Entry[] = [];
  for (const [key, value] of Object.entries(pkg.exports ?? {})) {
    if (key === './package.json') continue;
    const file = typeof value === 'string' ? value : (value.import ?? value.default);
    const types = typeof value === 'string' ? value : (value.types ?? file);
    if (!file) continue;
    out.push({ spec: key === '.' ? pkg.name : pkg.name + key.slice(1), file: join(dir, file), types: join(dir, types ?? file) });
  }
  return [...out.filter((e) => !e.spec.includes('*')), ...out.filter((e) => e.spec.includes('*'))];
}

/** The deps a consumer (a folder: `web`, `tools/<name>`) imports. */
function depsOf(root: string, consumer: string): string[] {
  const id = relative(root, resolve(root, consumer)).replace(/\\/g, '/');
  return Object.entries(manifest(root))
    .filter(([, d]) => (d.consumers ?? []).includes(id))
    .map(([n]) => n);
}

/** What a dep takes from its consumer: its peer dependencies (say, `typescript`, `vite`
 *  or `three`), and the runtime dependencies of a dep without a package-lock.json
 *  (say, `zod`): such a dep has no install of its own, `prepare` skips it. */
function borrowed(root: string, name: string): string[] {
  const dir = join(root, 'deps', name);
  const pkgPath = join(dir, 'package.json');
  if (!existsSync(pkgPath)) return [];
  const pkg = readJson(pkgPath) as { peerDependencies?: Record<string, string>; dependencies?: Record<string, string> };
  const own = existsSync(join(dir, 'package-lock.json')) ? [] : Object.keys(pkg.dependencies ?? {});
  return [...Object.keys(pkg.peerDependencies ?? {}), ...own];
}

/** Whether a dep gets its own `npm ci`: it has prepare scripts, or dependencies and a lockfile. */
function installs(root: string, name: string, dep: Dep): boolean {
  if ((dep.prepare ?? []).length) return true;
  const dir = join(root, 'deps', name);
  const pkgPath = join(dir, 'package.json');
  if (!existsSync(pkgPath)) return false;
  const deps = Object.keys((readJson(pkgPath) as { dependencies?: Record<string, string> }).dependencies ?? {});
  return deps.length > 0 && existsSync(join(dir, 'package-lock.json'));
}

/** node's lookup of node_modules/<pkg> from the consumer folder up to the repo root, without
 *  following links (a worktree's node_modules may be a junction to another checkout's). */
function findUp(root: string, consumerDir: string, pkg: string): string | null {
  for (let d = resolve(root, consumerDir); ; d = dirname(d)) {
    if (existsSync(join(d, 'node_modules', pkg, 'package.json'))) return join(d, 'node_modules', pkg);
    if (d === root || dirname(d) === d) return null;
  }
}

/** The packages a consumer's deps borrow from it: for vite's `resolve.dedupe`, so their subpaths
 *  (`three/examples/jsm/...`) resolve from the consumer as well. */
export function depDedupe(consumerDir: string): string[] {
  const root = findRoot(consumerDir);
  return [...new Set(peerEntries(root, consumerDir).map((e) => e.spec).filter((s) => !s.includes('*')))];
}

/** A dep's borrowed packages (borrowed()) come from its consumer's installed copy, when it has one
 *  (one that is another dep resolves through that dep's
 *  entries). node and tsc would look beside deps/<name>, where there is none. A package with
 *  subpath exports also gets `<name>/*` for tsc, into its types (`@types/<name>` when it ships none
 *  of its own); vite takes those subpaths through depDedupe(). */
function peerEntries(root: string, consumerDir: string): Entry[] {
  const out = new Map<string, Entry>();
  for (const n of depsOf(root, consumerDir)) {
    const pkgPath = join(root, 'deps', n, 'package.json');
    if (!existsSync(pkgPath)) continue;
    for (const peer of borrowed(root, n)) {
      if (depsOf(root, consumerDir).some((d) => entries(root, d).some((e) => e.spec === peer))) continue;
      // node's lookup from the consumer folder up, without following links (a worktree's
      // node_modules may be a junction to another checkout's)
      const dir = findUp(root, consumerDir, peer);
      if (!dir) continue; // an optional peer the consumer does not install
      type Cond = string | { types?: string; import?: string; default?: string };
      const p = readJson(join(dir, 'package.json')) as { exports?: Cond | Record<string, Cond>; types?: string; typings?: string; module?: string; main?: string };
      const ex = p.exports && typeof p.exports === 'object' && '.' in p.exports ? (p.exports as Record<string, Cond>)['.'] : (p.exports as Cond | undefined);
      const exObj = ex && typeof ex === 'object' ? ex : undefined;
      const file = (typeof ex === 'string' ? ex : (exObj?.import ?? exObj?.default)) ?? p.module ?? p.main ?? 'index.js';
      const dts = file.replace(/\.(m?)js$/, '.d.$1ts');
      const typesDir = findUp(root, consumerDir, join('@types', peer.startsWith('@') ? peer.slice(1).replace('/', '__') : peer));
      const tp = typesDir ? (readJson(join(typesDir, 'package.json')) as { types?: string; typings?: string }) : null;
      const own = exObj?.types ?? p.types ?? p.typings ?? (existsSync(join(dir, dts)) ? dts : null);
      const types = own ? join(dir, own) : typesDir ? join(typesDir, tp?.types ?? tp?.typings ?? 'index.d.ts') : join(dir, file);
      out.set(peer, { spec: peer, file: join(dir, file), types });
      const subpaths = !!p.exports && typeof p.exports === 'object' && Object.keys(p.exports).some((k) => k.startsWith('./') && k !== './package.json');
      if (subpaths) out.set(peer + '/*', { spec: peer + '/*', file: join(dir, '*'), types: join(own || !typesDir ? dir : typesDir, '*') });
    }
  }
  return [...out.values()];
}

/** Everything a consumer folder resolves through deps/: its deps' exports, then their peers. */
export function consumerEntries(root: string, consumerDir: string): Entry[] {
  return [...depsOf(root, consumerDir).flatMap((n) => entries(root, n)), ...peerEntries(root, consumerDir)];
}

/** vite/vitest `resolve.alias` for the consumer folder `consumerDir` (absolute). */
export function depAliases(consumerDir: string): { find: RegExp; replacement: string }[] {
  const root = findRoot(consumerDir);
  const esc = (s: string) => s.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&');
  const peers = new Set(depDedupe(consumerDir).map((p) => p + "/*"));
  return consumerEntries(root, consumerDir)
    .filter((e) => !peers.has(e.spec)) // tsc only: vite takes a peer's subpaths through resolve.dedupe
    .map((e) =>
      e.spec.includes('*')
        ? { find: new RegExp(`^${e.spec.split('*').map(esc).join('(.+)')}$`), replacement: e.file.replace('*', '$1') }
        : { find: new RegExp(`^${esc(e.spec)}$`), replacement: e.file },
    );
}

/** The deps/ folder, for vite's `server.fs.allow`. */
export function depsDir(consumerDir: string): string {
  return join(findRoot(consumerDir), 'deps');
}

// ---- git

function findGit(): string {
  if (process.env.PIVETTA_GIT) return process.env.PIVETTA_GIT;
  if (process.platform !== 'win32') return 'git';
  const dirs = (process.env.PATH ?? '').split(delimiter).filter(Boolean);
  const found = dirs.map((d) => join(d, 'git.exe')).filter((p) => existsSync(p));
  return found.find((p) => /[\\/]cmd[\\/]git\.exe$/i.test(p)) ?? found[0] ?? 'git';
}
const GIT = findGit();

function git(cwd: string, args: string[], quiet = false): string | null {
  try {
    return execFileSync(GIT, ['-C', cwd, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', quiet ? 'ignore' : 'inherit'] }).trim();
  } catch {
    return null;
  }
}

function hasGit(dir: string): boolean {
  return existsSync(join(dir, '.git'));
}

/** The commit the superproject pins (its index, so a staged bump counts). */
function pinned(root: string, name: string): string | null {
  const line = git(root, ['ls-files', '-s', '--', `deps/${name}`], true);
  const m = line?.match(/^160000 ([0-9a-f]{40}) /);
  return m?.[1] ?? null;
}

// ---- prepare

function run(cwd: string, line: string): void {
  console.log(`> ${line}   (in ${cwd})`);
  const r = spawnSync(line, { cwd, stdio: 'inherit', shell: true });
  if (r.status !== 0) throw new Error(`${line} failed in ${cwd} (exit ${r.status})`);
}

/** npm ci + the dep's `prepare` scripts, for deps with dependencies or scripts; skipped while the stamp matches. */
export function prepare(root: string, only: string[] = []): void {
  for (const [name, dep] of Object.entries(manifest(root))) {
    if (only.length && !only.includes(name)) continue;
    const dir = join(root, 'deps', name);
    if (!readdirSync(join(root, 'deps')).includes(name) || readdirSync(dir).length === 0) {
      throw new Error(`deps/${name} is not checked out: git submodule update --init deps/${name}`);
    }
    const pkgPath = join(dir, 'package.json');
    if (!existsSync(pkgPath)) continue; // a Rust-only dep
    const scripts = dep.prepare ?? [];
    if (!installs(root, name, dep)) continue;
    const head = hasGit(dir) ? git(dir, ['rev-parse', 'HEAD'], true) : null;
    const dirty = head !== null && (git(dir, ['status', '--porcelain'], true) ?? '') !== '';
    const stampPath = join(dir, 'node_modules', '.deps-prepared');
    const want = `${head ?? 'no-git'}\n${scripts.join(' ')}\n`;
    if (!dirty && existsSync(stampPath) && readFileSync(stampPath, 'utf8') === want) continue;
    run(dir, 'npm ci --no-audit --no-fund');
    for (const s of scripts) run(dir, `npm run ${s}`);
    writeFileSync(stampPath, want);
  }
}

// ---- check

/** A tsconfig `paths` target: relative to the tsconfig, ./-prefixed (no baseUrl). */
function tsPath(rel: string): string {
  const p = rel.replace(/\\/g, '/');
  return p.startsWith('.') ? p : `./${p}`;
}

function gitmodules(root: string): Map<string, string> {
  const out = new Map<string, string>();
  const paths = git(root, ['config', '-f', '.gitmodules', '--get-regexp', '^submodule\\..*\\.path$'], true) ?? '';
  for (const line of paths.split('\n').filter(Boolean)) {
    const [key, path] = line.split(' ');
    if (!key || !path?.startsWith('deps/')) continue;
    const url = git(root, ['config', '-f', '.gitmodules', key.replace(/\.path$/, '.url')], true) ?? '';
    out.set(path.slice('deps/'.length), url);
  }
  return out;
}

function tsconfigPaths(root: string, consumer: string): Record<string, string[]> {
  const cfg = readJson(join(root, consumer, 'tsconfig.json')) as { compilerOptions?: { paths?: Record<string, string[]> } };
  return cfg.compilerOptions?.paths ?? {};
}

export function check(root: string): { errors: string[]; warnings: string[] } {
  const errors: string[] = [];
  const warnings: string[] = [];
  const deps = manifest(root);
  const mods = gitmodules(root);
  const onDisk = readdirSync(join(root, 'deps')).filter((f) => f !== 'deps.json');
  for (const n of new Set([...Object.keys(deps), ...mods.keys(), ...onDisk])) {
    if (!deps[n]) errors.push(`deps/${n}: not in deps/deps.json`);
    if (!mods.has(n)) errors.push(`deps/${n}: not a submodule in .gitmodules`);
    if (!onDisk.includes(n)) errors.push(`deps/${n}: missing (git submodule update --init deps/${n})`);
  }
  for (const [name, dep] of Object.entries(deps)) {
    const dir = join(root, 'deps', name);
    const url = `git@github.com:${dep.repo}.git`;
    if (mods.has(name) && mods.get(name) !== url) errors.push(`deps/${name}: .gitmodules url ${mods.get(name)}, deps.json says ${url}`);
    const branch = dep.branch ?? 'main';
    if (branch !== 'main') warnings.push(`deps/${name}: pinned on ${branch}, not main (temporary: ${dep.note ?? 'no note'})`);
    if (!hasGit(dir)) {
      errors.push(`deps/${name}: not checked out (git submodule update --init deps/${name})`);
      continue;
    }
    const pin = pinned(root, name);
    const head = git(dir, ['rev-parse', 'HEAD'], true);
    if (!pin) errors.push(`deps/${name}: no pin in the index`);
    else if (head !== pin) errors.push(`deps/${name}: checked out at ${head?.slice(0, 7)}, pinned ${pin.slice(0, 7)} (git submodule update deps/${name})`);
    if ((git(dir, ['status', '--porcelain'], true) ?? '') !== '') errors.push(`deps/${name}: has changes of its own (commit and push them there, or drop them)`);
    if (pin) {
      const on = (git(dir, ['branch', '-r', '--contains', pin], true) ?? '').split('\n').map((s) => s.trim());
      if (!on.includes(`origin/${branch}`)) errors.push(`deps/${name}: pin ${pin.slice(0, 7)} is not on origin/${branch} (push it there; or fetch in deps/${name})`);
    }
    if (git(dir, ['ls-files', '.gitmodules'], true)) errors.push(`deps/${name}: has a .gitmodules (no nested submodules)`);
    for (const consumer of dep.consumers ?? []) {
      if (!existsSync(join(root, consumer, 'tsconfig.json'))) {
        errors.push(`deps/${name}: consumer ${consumer} has no tsconfig.json`);
        continue;
      }
      const paths = tsconfigPaths(root, consumer);
      for (const e of entries(root, name)) {
        const want = tsPath(relative(join(root, consumer), e.types));
        const got = paths[e.spec];
        if (!got || got.length !== 1 || got[0] !== want) {
          errors.push(`${consumer}/tsconfig.json: "paths" needs "${e.spec}": ["${want}"]${got ? ` (has ${JSON.stringify(got)})` : ''}`);
        }
      }
    }
  }
  // the deps' peers, from each consumer's own node_modules
  const consumers = new Set(Object.values(deps).flatMap((d) => d.consumers ?? []));
  for (const consumer of consumers) {
    if (!existsSync(join(root, consumer, 'tsconfig.json'))) continue;
    const paths = tsconfigPaths(root, consumer);
    for (const e of peerEntries(root, consumer)) {
      const want = tsPath(relative(join(root, consumer), e.types));
      const got = paths[e.spec];
      if (!got || got.length !== 1 || got[0] !== want) {
        errors.push(`${consumer}/tsconfig.json: "paths" needs "${e.spec}": ["${want}"] (a peer of its deps)${got ? ` (has ${JSON.stringify(got)})` : ''}`);
      }
    }
  }
  errors.push(...sshOnly(root));
  const rust = toolchain(root);
  // a repo with its own Rust (deps.json: "repokit": { ..., "toolchain": "own" }) is only told
  if (deps.repokit?.toolchain === 'own') warnings.push(...rust.map((e) => `${e} (own toolchain: deps.json)`));
  else errors.push(...rust);
  return { errors, warnings };
}

/** Every submodule (deps/, assets/, content/...) comes from GitHub over SSH. */
function sshOnly(root: string): string[] {
  const urls = git(root, ['config', '-f', '.gitmodules', '--get-regexp', '^submodule\\..*\\.url$'], true) ?? '';
  return urls
    .split('\n')
    .filter(Boolean)
    .map((line) => line.split(' '))
    .filter(([, url]) => !/^git@github\.com:[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\.git$/.test(url ?? ''))
    .map(([key, url]) => `.gitmodules: ${key} is ${url}, not SSH (git submodule set-url <path> git@github.com:<owner>/<repo>.git)`);
}

/** The `channel = "..."` of a rust-toolchain.toml, or null. */
function channelOf(path: string): string | null {
  if (!existsSync(path)) return null;
  return readFileSync(path, 'utf8').match(/^\s*channel\s*=\s*"([^"]+)"/m)?.[1] ?? null;
}

/** The repo's Rust is RepoKit's (rust-toolchain.toml beside this file; a copy of this file without
 *  it, as in deploy tests, checks nothing). */
function toolchain(root: string): string[] {
  const want = channelOf(join(dirname(fileURLToPath(import.meta.url)), 'rust-toolchain.toml'));
  if (!want) return [];
  const errors: string[] = [];
  const own = join(root, 'rust-toolchain.toml');
  if (existsSync(own) && channelOf(own) !== want) errors.push(`rust-toolchain.toml: channel ${channelOf(own)}, RepoKit says ${want}`);
  const cross = join(root, 'deploy', 'Dockerfile.cross');
  if (existsSync(cross)) {
    const from = readFileSync(cross, 'utf8').match(/^FROM rust:([0-9.]+)/m)?.[1] ?? null;
    if (from !== want) errors.push(`deploy/Dockerfile.cross: FROM rust:${from}, RepoKit says ${want}`);
  }
  return errors;
}

// ---- status, bump

function status(root: string): void {
  for (const [name, dep] of Object.entries(manifest(root))) {
    const dir = join(root, 'deps', name);
    const branch = dep.branch ?? 'main';
    const pin = pinned(root, name)?.slice(0, 7) ?? '-';
    const head = hasGit(dir) ? (git(dir, ['rev-parse', '--short=7', 'HEAD'], true) ?? '?') : 'not checked out';
    const origin = hasGit(dir) ? (git(dir, ['rev-parse', '--short=7', `origin/${branch}`], true) ?? '?') : '-';
    const dirty = hasGit(dir) && (git(dir, ['status', '--porcelain'], true) ?? '') !== '' ? ' dirty' : '';
    console.log(`${name.padEnd(12)} pin ${pin}  at ${head}${dirty}  origin/${branch} ${origin}  ${dep.repo}  -> ${(dep.consumers ?? ['cargo']).join(', ')}`);
  }
}

function bump(root: string, name: string, rev?: string): void {
  const dep = manifest(root)[name];
  if (!dep) throw new Error(`no dep ${name} in deps/deps.json`);
  const dir = join(root, 'deps', name);
  const branch = dep.branch ?? 'main';
  if ((git(dir, ['status', '--porcelain'], true) ?? '') !== '') throw new Error(`deps/${name} has changes of its own: commit and push them there first`);
  if (git(dir, ['fetch', '-q', 'origin']) === null) throw new Error(`fetch failed in deps/${name} (git: ${GIT})`);
  const to = git(dir, ['rev-parse', '--verify', `${rev ?? `origin/${branch}`}^{commit}`], true);
  if (!to) throw new Error(`deps/${name}: no commit ${rev}`);
  const on = (git(dir, ['branch', '-r', '--contains', to], true) ?? '').split('\n').map((s) => s.trim());
  if (!on.includes(`origin/${branch}`)) throw new Error(`deps/${name}: ${to.slice(0, 7)} is not on origin/${branch}`);
  const pin = pinned(root, name);
  if (pin === to) return void console.log(`deps/${name} is already at ${to.slice(0, 7)}`);
  console.log(`deps/${name}: ${pin?.slice(0, 7)} -> ${to.slice(0, 7)}`);
  console.log(git(dir, ['log', '--oneline', `${pin}..${to}`], true) ?? '');
  if (git(dir, ['checkout', '-q', '--detach', to]) === null) throw new Error(`checkout failed in deps/${name}`);
  prepare(root, [name]);
  git(root, ['add', '--', `deps/${name}`]);
  console.log(`staged. Now: powershell -File scripts/check.ps1, then commit the pin alone: deps: ${name} ${pin?.slice(0, 7)} -> ${to.slice(0, 7)}`);
}

// ---- command line (only when run, not when a vite config imports this file)

/** The command line, for the repo at or above `from` (a repo's scripts/ shim passes its own folder). */
export function main(argv: string[], from: string): void {
  const root = findRoot(from);
  const [cmd, ...rest] = argv;
  try {
    if (cmd === 'status') status(root);
    else if (cmd === 'prepare' && rest[0] === '--consumer' && rest[1]) {
      const names = depsOf(root, resolve(process.cwd(), rest[1]));
      if (names.length) prepare(root, names);
    } else if (cmd === 'prepare') prepare(root, rest);
    else if (cmd === 'bump' && rest[0]) bump(root, rest[0], rest[1]);
    else if (cmd === 'check') {
      if (!hasGit(root)) {
        console.log('deps check: not a git checkout, skipped');
      } else {
        const { errors, warnings } = check(root);
        for (const w of warnings) console.warn(`warning: ${w}`);
        for (const e of errors) console.error(`error: ${e}`);
        if (errors.length) process.exit(1);
        console.log(`deps check: ${Object.keys(manifest(root)).length} deps ok`);
      }
    } else {
      console.error('usage: node scripts/deps.mts status | prepare [name...] | check | bump <name> [rev]');
      process.exit(2);
    }
  } catch (e) {
    console.error((e as Error).message);
    process.exit(1);
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2), dirname(fileURLToPath(import.meta.url)));
}

# Kiro Crew on Nix

Everything about the Nix packaging lives in this directory, deliberately. The
flake, the modules, and this document are additions this fork carries on top of
upstream, and keeping them out of `README.md`, `docs/`, and `CONTRIBUTING.md`
means an upstream merge never conflicts over them.

| File | What it is |
|---|---|
| [`../flake.nix`](../flake.nix) | Flake outputs: packages, apps, dev shell, checks, overlay, modules |
| [`kirocrew.nix`](kirocrew.nix) | The Python backend plus the pre-built dashboard |
| [`dashboard.nix`](dashboard.nix) | The `website/` SPA, built with npm + Vite |
| [`service.nix`](service.nix) | Option and unit definitions shared by both modules |
| [`nixos-module.nix`](nixos-module.nix) | NixOS `services.kirocrew` |
| [`hm-module.nix`](hm-module.nix) | home-manager `services.kirocrew` |

The backend and the dashboard are separate derivations, so a frontend-only
change does not rebuild the Python package, and a backend-only change does not
rebuild the SPA.

## Installing

```bash
nix run github:kirodotdev/KiroCrew -- setup   # run without installing
nix profile install github:kirodotdev/KiroCrew
```

Flake outputs:
`packages.{default,kirocrew,kirocrew-dashboard,kirocrew-with-kiro-cli}`,
`apps.{kirocrew,kirocrew-browse,dev}`, `devShells.default`, `checks`,
`overlays.default` (adds `kirocrew`, `kirocrew-dashboard`, and
`kirocrew-with-kiro-cli`), `nixosModules.default`, and
`homeManagerModules.default`.

Supported systems are `x86_64-linux`, `aarch64-linux`, and `aarch64-darwin`.
`x86_64-darwin` is absent because nixpkgs dropped it in 26.11; the package
itself still supports it for anyone pointing this flake at an older nixpkgs.

## Kiro CLI is not bundled

Kiro Crew is KiroACP-only and cannot answer a prompt without
[`kiro-cli`](https://kiro.dev/docs/cli/), which ships under Amazon's own terms.
The default `kirocrew` package therefore leaves it out and discovers whatever
`kiro-cli` is on `PATH`, exactly as a `pip` install does. That keeps `nix build`
working — and cached — for everyone regardless of `allowUnfree`.

Without one, the gateway still starts and serves the dashboard, but every
prompt fails with `kiro-cli not found in PATH`.

To pin the backend into the wrapper instead, use the `-with-kiro-cli` variant.
It sets `KIROCREW_KIRO_BIN` in the wrapper, so a gateway started by systemd
needs nothing on `PATH`:

```bash
nix run .#kirocrew-with-kiro-cli -- gateway
```

```nix
# From the overlay. nixpkgs.config.allowUnfree = true; is required here —
# the attribute reads the *caller's* nixpkgs config.
environment.systemPackages = [ pkgs.kirocrew-with-kiro-cli ];
```

The flake's own `packages.kirocrew-with-kiro-cli` needs no `allowUnfree` from
you and no `--impure`: flake evaluation is pure, so a caller's `nixpkgs.config`
could never reach this flake's nixpkgs import anyway, and `flake.nix` allows
exactly `kiro-cli` there via `allowUnfreePredicate`. It is kept out of `checks`
so `nix flake check` stays free-only.

## Development

```bash
nix develop
```

The dev shell replaces the virtualenv half of
[`CONTRIBUTING.md`](../CONTRIBUTING.md) § First-Time Setup. It brings its own
Python, Node, linters, and pytest, and needs neither a virtualenv nor
`pip install -e .`. The interpreter carries exactly the runtime dependency set
the package is built against, because the shell reads
`pkgs.kirocrew.dependencies` rather than repeating the list.

Run the working tree with:

```bash
python -m kiro_crew --help     # the `kirocrew` console script, from source
pytest                         # the backend suite
```

There is no `kirocrew` binary in the shell — the console script belongs to the
installed package, not to the sources. `setup.cfg` does set `pythonpath = src`,
but that key lives under `[tool:pytest]` and so applies to pytest alone; the
shell exports `PYTHONPATH` itself to make `python -m kiro_crew` work too. Use
`nix run .#kirocrew` when you want the wrapped binary rather than the sources.

That `PYTHONPATH` does not leak into the packaged binary. A wheel's dependencies
reach it through `site.addsitedir` calls that land after `$PYTHONPATH` on
`sys.path`, so an inherited one does not add to the package, it shadows it —
`nix run .#kirocrew` from this shell would otherwise run the working tree with
no bundled dashboard and none of the `postPatch` fixes. The wrapper unsets it.

`kiro-cli` is still yours to install; it is not in nixpkgs under a free license.

The dashboard is not built by the shell. Build it the normal way when you are
working on it:

```bash
cd website && npm ci && npm run build
```

### The full-stack dev loop

```bash
nix run .#dev
```

One command for what [`CONTRIBUTING.md`](../CONTRIBUTING.md) § Full-Stack Dev
Setup spreads over three terminals. It starts the gateway, starts Vite, waits
for each to actually listen, mints a token, and prints the single URL that
works. Ctrl-C stops both.

The backend runs from source on `PYTHONPATH`, so a Python change needs a
restart rather than a rebuild, and the dashboard comes from Vite rather than
the copy baked into the package, so `.tsx` edits hot-reload. The data home
defaults to `.kirocrew-dev/` in the checkout, never `~/.kiro/crew` — the dev
loop must not touch the sessions and credentials of an installed gateway.
`KIROCREW_HOME`, `KIROCREW_PORT` (default 6777), and `KIROCREW_DEV_UI_PORT`
(default 3000) override the defaults. The first run installs
`website/node_modules`.

To just *use* the app rather than work on it, no dev loop is needed — the
backend serves the dashboard the package was built with:

```bash
nix run .#kirocrew -- gateway
```

### Checks

```bash
nix flake check
```

Beyond building both derivations, `checks.smoke` guards the two things this
flake wires up that a plain `pip install` does not: the console script runs
against the Nix-resolved dependency set, and the separately-built dashboard
really landed on the path the backend serves it from. The real pytest suite is
not part of `nix flake check` — it spawns gateway subprocesses, drives a
browser, and reaches for a `kiro-cli` backend, none of which exist in the build
sandbox. Run it from the dev shell.

### Why Python 3.13

The interpreter is chosen once, in `flake.nix`'s overlay, and everything else
reads `pkgs.kirocrew.python`. It is 3.13 rather than the 3.12 upstream CI
tests, because Hydra only populates the binary cache for nixpkgs' default
interpreter and 3.13. On 3.12, `uv` (Rust), `slack-sdk`, and `scipy` have no
substitute and build from source, and `scipy` arrives only as a *test*
dependency of `isort` in the dev shell. That is the difference between a
36-second build and the better part of an hour.

`setup.cfg` declares `>=3.10` with no upper bound, so 3.13 is in range, but
it is a version CI does not cover — run the suite from the dev shell after
changing it. Revisit the choice when nixpkgs' default interpreter moves, since
what Hydra caches moves with it.

### After changing dependencies

- **Python** — edit `dependencies` in `kirocrew.nix`. Upper bounds in
  `setup.cfg` track what PyPI shipped when a release was cut, so they are
  relaxed here rather than pinning the derivation to whatever nixpkgs carried
  on the day it was written.
- **npm** — `npmDepsHash` in `dashboard.nix` must be updated whenever
  `website/package-lock.json` changes, which is most rebases onto upstream.
  `nix flake check` (it builds `kirocrew-dashboard`) is what catches a stale
  hash — same as any other build failure, with `ERROR: npmDepsHash is out of
  date`. Fix it in one step:

  ```console
  $ nix run .#update-npm-hash
  ```

  which wraps `nix run nixpkgs#prefetch-npm-deps -- website/package-lock.json`
  and rewrites the hash in `dashboard.nix` for you, or reports no-op if it was
  already current.

  `importNpmLock` would remove this hash entirely by fetching each dependency
  against the `integrity` field already in the lockfile. It does not work here.
  `website/package.json` pins ~50 transitive packages through `overrides`, and
  `importNpmLock` rewrites only `dependencies` and `devDependencies` into store
  paths. `dompurify` is both an override and a direct dependency, so the two
  stop matching and npm fails with `EOVERRIDE`; dropping the overrides instead
  lets npm resolve past the lockfile to versions that were never prefetched
  (`ENOTCACHED` on `hasown`). Revisit if upstream drops `overrides` or
  `importNpmLock` learns to map them.

## Source patches carried in postPatch

A few upstream behaviors only break under Nix, and all are patched in
`kirocrew.nix`'s `postPatch` rather than in the Python sources, so this fork
keeps its shared-file footprint at zero.

Trusted-system-binary resolution on NixOS is deliberately NOT among them. That
was a bug in the shared sources rather than a packaging concern — `ps`, `lsof`
and `systemd-run` live in `/run/current-system/sw/bin`, which the pin did not
cover, so `trusted_system_bin` resolved nothing and the Kiro CLI setup probe
could never succeed — and it is fixed in `platform_compat.py` and
`kiro_prerequisite.py` directly, upstream, as of #2303. Building this flake
against a tree predating that fix leaves the dashboard stuck on the first-run
*Install Kiro CLI* gate.

### Read-only skill trees

`deploy/__init__.py` and `skills.py` both install skills into the data home with
`shutil.copytree`, which preserves mode bits. Nix strips the write bit from
every store path, so the copy lands read-only. `deploy` then dies outright —
it writes a `.kirocrew-managed` marker inside the tree it just copied, and that
`EPERM` takes gateway startup with it. In `skills.py` the failure is deferred:
the `shutil.rmtree` on the resync path cannot delete a read-only tree, and a
user cannot edit a synced skill. Both patches restore owner-write across the
copied tree. A pip install never sees either, because site-packages is
writable.

### Known limitation: builtin skills do not resync on upgrade

`skills._ensure_builtin_skills` decides a skill is stale with
`src.st_mtime > dest.st_mtime`. Every file in the store has `mtime=1`, and
`copytree` preserves it, so after the first sync the comparison is permanently
`1 > 1` and a package upgrade never refreshes a skill whose name already exists.
Deleting the `skills/` directory in the data home forces a clean re-sync.

Fixing it properly means replacing the mtime heuristic with a content
comparison, which would also drop the mtime trick's protection of local edits to
a synced skill — a behavior change, so it is left alone here rather than decided
inside a packaging patch.

## Running the gateway as a service

`kirocrew service install` writes an imperative unit into `/etc/systemd/system`,
which a NixOS rebuild discards. The flake ships modules that render the same
service declaratively instead. Both expose one `services.kirocrew` option set
and import [`service.nix`](service.nix), so a change to the exec line or the
environment cannot land in one module and not the other.

Unlike the imperative installer, which writes a system unit with `User=`, both
modules render a systemd **user** service — Kiro Crew reads the invoking user's
files and holds that user's credentials.

```nix
{
  inputs.kirocrew.url = "github:kirodotdev/KiroCrew";

  # In your NixOS configuration:
  imports = [ inputs.kirocrew.nixosModules.default ];

  services.kirocrew = {
    enable = true;
    port = 5476;
    # Absolute: a service starts from an unspecified working directory.
    kiroBin = "/home/alice/.local/bin/kiro-cli";
  };
}
```

| Option | Default | Purpose |
|---|---|---|
| `enable` | `false` | Define the user unit |
| `package` | this flake's `kirocrew` | Package to run |
| `port` | `null` | `KIROCREW_PORT`; null keeps the gateway's own default, 5476 |
| `home` | `null` | `KIROCREW_HOME`; null uses `~/.kiro/crew` |
| `kiroBin` | `null` | Absolute path to `kiro-cli`; null falls back to discovery |
| `extraFlags` | `[ ]` | Extra arguments appended to `kirocrew gateway` |
| `environment` | `{ }` | Extra environment variables |
| `startAtLogin` | `false` | NixOS only — start the unit when a session begins |

The NixOS module defines the unit for every user on the system but leaves it
disabled, so an agent holding credentials stays a per-user opt-in. Turn it on
with `systemctl --user enable --now kirocrew`, or set
`services.kirocrew.startAtLogin = true`. The home-manager module takes the same
options and enables the unit for the user it is imported into.

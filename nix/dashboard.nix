# The dashboard SPA (website/) built with npm + Vite.
#
# The backend serves this tree from `kiro_crew/static/dist`; `kirocrew.nix`
# copies the result of this derivation into that path instead of running the
# `make frontend` target, which shells out to npm at build time.
{
  lib,
  buildNpmPackage,
  nodejs_22,
}:

let
  # website/ minus everything a local `npm run build` / `npm test` leaves
  # behind — those must not enter the store or the source hash depends on
  # whatever a developer last ran.
  websiteFiles = lib.fileset.difference ../website (
    lib.fileset.unions (
      map lib.fileset.maybeMissing [
        ../website/node_modules
        ../website/dist
        ../website/playwright-report
        ../website/test-results
        ../website/coverage
      ]
    )
  );

  # The SPA imports one file out of the backend tree
  # (src/pages/connections/registry.ts), so the source root has to be the repo
  # root even though only website/ is built. Listed explicitly rather than by
  # including src/: a wider fileset would rebuild the dashboard on every
  # unrelated backend edit.
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      websiteFiles
      ../src/kiro_crew/connections/registry.json
    ];
  };

  version = (lib.importJSON ../website/package.json).version;

  # The store hash of the exact sources this SPA is built from — a stand-in for
  # the git SHA the service worker's cache key normally carries (see below).
  srcHash = lib.head (lib.splitString "-" (baseNameOf src));
in

buildNpmPackage {
  pname = "kirocrew-dashboard";
  inherit version;

  inherit src;
  # lib.fileset.toSource names its store path "source"; the npm project is one
  # level down from the repo root it exports.
  sourceRoot = "source/website";

  # Refresh with `nix run .#update-npm-hash` whenever website/package-lock.json
  # changes. A stale hash fails this build (caught by `nix flake check`); the
  # value cannot be computed at eval or build time because the tool that hashes
  # npm deps has to fetch them itself, which needs the same sandboxed-network
  # permission a hash exists to grant. See nix/update-npm-hash.nix.
  #
  # importNpmLock, which would derive dependencies from the lockfile's own
  # `integrity` fields and need no hash at all, does not work here:
  # website/package.json pins ~50 transitive packages through `overrides`, and
  # importNpmLock rewrites only `dependencies`/`devDependencies` to store
  # paths. That leaves an override and its direct dependency disagreeing
  # (npm EOVERRIDE on dompurify), and dropping the overrides instead makes npm
  # re-resolve past the lock to uncached versions (ENOTCACHED on hasown).
  npmDepsHash = "sha256-rBlWu1VEZ7zUojJZl7NtFubFpD0sHck3iOqRBR644Qk=";

  nodejs = nodejs_22;

  env = {
    # @playwright/test is a devDependency that `npm ci` installs, and its
    # postinstall downloads browser bundles — impossible in the build sandbox
    # and unnecessary, since the E2E suite is not part of this build.
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
    # The Vite/Rolldown build of this SPA peaks above node's default old-space
    # ceiling and otherwise dies with "JavaScript heap out of memory".
    NODE_OPTIONS = "--max-old-space-size=6144";
  };

  # vite.config.ts's swVersionPlugin stamps the service-worker cache key with
  # `<version>-<git sha>`, falling back to the bare version when git is
  # unavailable — which it always is inside the sandbox. Left at the fallback,
  # every Nix-built dashboard would share one cache key and an upgraded client
  # could keep serving the previous shell from its offline cache. Restore the
  # per-build identity from the source hash.
  postBuild = ''
    substituteInPlace dist/sw.js \
      --replace-fail "const CACHE_VERSION = '${version}'" \
                     "const CACHE_VERSION = '${version}-${srcHash}'"
  '';

  # `npm run build` is `tsc -b && vite build`; the default install phase looks
  # for an `npm pack` tarball, which this private package does not produce.
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -r dist/. "$out/"
    runHook postInstall
  '';

  meta = {
    description = "Kiro Crew dashboard single-page app";
    homepage = "https://github.com/kirodotdev/KiroCrew";
    license = lib.licenses.asl20;
  };
}

# The `kirocrew` backend: the Python package plus the pre-built dashboard.
{
  lib,
  stdenv,
  python3,
  kirocrew-dashboard,
  autoPatchelfHook,
  makeWrapper,
  nodejs_22,
  git,
  # kiro-cli is REQUIRED at runtime but is not in nixpkgs (no public source
  # build, no redistributable binary). Leave it null and the wrapper falls back
  # to whatever `kiro-cli` the user has on PATH — the same discovery a pip
  # install performs. Point it at a derivation (or an overlay attribute) to pin
  # one into the wrapper instead. See README § Nix.
  kiro-cli ? null,
}:

let
  # Vendored llama.cpp shared libraries ship for every supported platform. Only
  # the host tuple can ever be loaded, and autoPatchelfHook fails hard on the
  # foreign-architecture ELF files, so drop everything else.
  vendorLibDir =
    {
      "x86_64-linux" = "linux_x86_64";
      "aarch64-linux" = "linux_aarch64";
      "x86_64-darwin" = "macos_x86_64";
      "aarch64-darwin" = "macos_arm64";
    }
    .${stdenv.hostPlatform.system} or null;

  # pdfplumber type-checks its test suite against pandas-stubs, which is a
  # nativeCheckInput and pulls scipy, pandas, torch, and jupyterlab into the
  # BUILD closure of a PDF text extractor. None of it is reachable at runtime.
  # Beyond the closure size, that chain is what actually breaks the build: on a
  # lock rev the binary cache has not caught up with, scipy compiles from source
  # and one of its ~88k hypothesis tests fails, taking kirocrew down with it.
  # Upstream's test suite is nixpkgs' to run, not ours to re-run per consumer.
  pdfplumber-no-tests = python3.pkgs.pdfplumber.overridePythonAttrs { doCheck = false; };
in

python3.pkgs.buildPythonApplication rec {
  pname = "kirocrew";
  version = "0.2.0";
  pyproject = true;

  src = lib.cleanSourceWith {
    src = ../.;
    # `website/` is deliberately excluded: its build output arrives through the
    # kirocrew-dashboard derivation, so keeping the sources out of this src
    # means a frontend-only edit does not invalidate the backend build.
    filter =
      path: type:
      let
        base = baseNameOf path;
      in
      !(
        (
          type == "directory"
          && builtins.elem base [
            ".git"
            ".venv"
            "build"
            "dist"
            "node_modules"
            "website"
            "temp-screenshots"
            "__pycache__"
            ".hypothesis"
            ".pytest_cache"
            ".mypy_cache"
            "result"
          ]
        )
        || (type == "symlink" && lib.hasPrefix "result" base)
      );
  };

  build-system = with python3.pkgs; [
    setuptools
    wheel
  ];

  nativeBuildInputs = [ makeWrapper ] ++ lib.optional stdenv.hostPlatform.isLinux autoPatchelfHook;

  # libstdc++ for the vendored llama.cpp libraries, which are built against it
  # but carry no RPATH entry that resolves outside the wheel.
  buildInputs = lib.optional stdenv.hostPlatform.isLinux (lib.getLib stdenv.cc.cc);

  dependencies =
    with python3.pkgs;
    [
      aiohttp
      croniter
      cron-descriptor
      defusedxml
      jinja2
      numpy
      opentelemetry-api
      opentelemetry-sdk
      pdfplumber-no-tests
      pillow # qrcode[pil]
      python-docx
      pyyaml
      qrcode
      requests
      slack-sdk
      snowballstemmer
      typing-extensions
      uv
      websockets
      yarl
    ]
    # setup.cfg extras that nixpkgs can satisfy from source. They are pure
    # Python and add no meaningful closure, and leaving them out would make the
    # Teams channel and OTLP metrics egress silently unavailable on Nix only.
    # Neither turns itself on: OTLP still requires telemetry.otlp_endpoint, and
    # Teams still requires channel configuration.
    ++ [ python3.pkgs.opentelemetry-exporter-otlp-proto-http ]
    ++ [ python3.pkgs.pyjwt ]
    ++ python3.pkgs.pyjwt.optional-dependencies.crypto; # PyJWT[crypto]

  # pysqlite3-binary exists to backfill FTS5/UPSERT on distributions whose
  # system SQLite is too old. The SQLite nixpkgs builds CPython against has
  # both, and kiro_crew._sqlite_compat falls back to the stdlib module when the
  # import fails, so the dependency is dead weight here — and it has no
  # nixpkgs equivalent, which would otherwise fail the runtime-deps check.
  pythonRemoveDeps = [ "pysqlite3-binary" ];

  # Upper bounds in setup.cfg track what PyPI shipped when a release was cut,
  # not an incompatibility nixpkgs hits. Relax them rather than pinning this
  # derivation to whatever nixpkgs happened to carry on the day it was written.
  pythonRelaxDeps = [
    # nixpkgs carries croniter 6.x and cron-descriptor 2.x against setup.cfg's
    # <3 and <2 ceilings. Both are majors ahead, so unlike the others in this
    # list they are worth re-checking after a nixpkgs bump: cron scheduling is
    # a shipped feature, and test/test_cron*.py is what covers the expression
    # parsing and the human-readable descriptions.
    "cron-descriptor"
    "croniter"
    "cryptography"
    "numpy"
    "uv"
    "websockets"
  ];

  postPatch = ''
    # setup.py's BuildWithFrontend copies this tree into the wheel; the
    # upstream `make frontend` target produces it by running npm in-tree.
    rm -rf src/kiro_crew/static/dist
    mkdir -p src/kiro_crew/static
    cp -r ${kirocrew-dashboard} src/kiro_crew/static/dist
    chmod -R u+w src/kiro_crew/static/dist

    # deploy._register_core_skills copies builtin_skills/ into the data home
    # with shutil.copytree, which preserves mode bits. Nix strips the write bit
    # from every store path, so the copy lands read-only and the very next
    # statement — writing the .kirocrew-managed marker INSIDE it — dies with
    # EPERM, taking gateway startup with it. The rmtree on the refresh path
    # would fail the same way, so restore write on the whole tree, not just the
    # top directory. A pip install never hits this: site-packages is writable.
    substituteInPlace src/kiro_crew/deploy/__init__.py \
      --replace-fail \
        'shutil.copytree(skill_dir, link)' \
        'shutil.copytree(skill_dir, link); [_p.chmod(_p.stat().st_mode | 0o200) for _p in [link, *link.rglob("*")]]'

    # skills._ensure_builtin_skills copies builtin_skills/ the same way, and
    # hits the same read-only copy. Here it is the shutil.rmtree on the resync
    # path that would fail, leaving the tree permanently unupdatable, and a
    # user cannot edit a synced skill either.
    substituteInPlace src/kiro_crew/skills.py \
      --replace-fail \
        'shutil.copytree(src_dir, dest_dir)' \
        'shutil.copytree(src_dir, dest_dir); [_p.chmod(_p.stat().st_mode | 0o200) for _p in [dest_dir, *dest_dir.rglob("*")]]'
  ''
  + lib.optionalString (vendorLibDir != null) ''
    find src/kiro_crew/_vendor/llama_cpp_libs -mindepth 1 -maxdepth 1 -type d \
      ! -name ${vendorLibDir} -exec rm -rf {} +
  ''
  + lib.optionalString (vendorLibDir == null) ''
    rm -rf src/kiro_crew/_vendor/llama_cpp_libs/*
  '';

  # The suite spawns real gateway subprocesses, drives a browser, and reaches
  # for a kiro-cli backend, none of which exist in the sandbox. `nix flake
  # check` exercises the built artifact instead (see checks.smoke); run pytest
  # from the dev shell for the real suite.
  doCheck = false;

  pythonImportsCheck = [ "kiro_crew" ];

  makeWrapperArgs = [
    # The dependency set reaches the app through `site.addsitedir` calls inside
    # the generated console script, which land AFTER anything $PYTHONPATH put on
    # sys.path. An inherited PYTHONPATH therefore does not merely add to this
    # package, it SHADOWS it — and `nix develop` in this very repo exports one
    # pointing at ./src, so `nix run .#kirocrew` from a dev shell silently runs
    # the working tree instead: no bundled dashboard, none of the postPatch
    # fixes. Nothing here reads PYTHONPATH, and dropping it also keeps spawned
    # MCP servers on the packaged sources.
    "--unset"
    "PYTHONPATH"
    # A gateway started by systemd/launchd inherits no login PATH, and several
    # code paths shell out to node (MCP servers, the frontend build) or git.
    # Without this the runtime tries to *install* a node for itself.
    "--suffix"
    "PATH"
    ":"
    (lib.makeBinPath (
      [
        nodejs_22
        git
      ]
      ++ lib.optional (kiro-cli != null) kiro-cli
    ))
    # env.node_bin_dirs() treats this as the highest-priority node, ahead of
    # any mise/nvm tree, so the pinned interpreter is the one build
    # subprocesses get.
    "--set-default"
    "KIROCREW_NODE_BIN_DIR"
    "${nodejs_22}/bin"
  ]
  ++ lib.optionals (kiro-cli != null) [
    "--set-default"
    "KIROCREW_KIRO_BIN"
    "${lib.getExe' kiro-cli "kiro-cli"}"
  ];

  passthru = {
    dashboard = kirocrew-dashboard;
    python = python3;
    # Re-exported so the dev shell can build an interpreter carrying exactly
    # the runtime set the package was built against, with no second list to
    # keep in sync.
    inherit dependencies;
  };

  meta = {
    description = "Personal AI agent that runs locally — chat via CLI, dashboard, Slack, or desktop app";
    homepage = "https://github.com/kirodotdev/KiroCrew";
    changelog = "https://github.com/kirodotdev/KiroCrew/blob/main/CHANGELOG.md";
    license = lib.licenses.asl20;
    mainProgram = "kirocrew";
    platforms = lib.platforms.unix;
  };
}

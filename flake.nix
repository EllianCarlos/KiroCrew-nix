{
  description = "Kiro Crew — personal AI agent that runs locally (CLI, dashboard, Slack, desktop)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      # x86_64-darwin is absent because nixpkgs dropped it in 26.11; the
      # package itself still supports it (see the vendor-lib table in
      # nix/kirocrew.nix) for anyone pointing this flake at an older nixpkgs.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      forAllSystems =
        f:
        lib.genAttrs systems (
          system:
          f (
            import nixpkgs {
              inherit system;
              overlays = [ self.overlays.default ];
              # Scoped to kiro-cli alone (its bwrap sub-derivations carry the
              # same unfree meta, hence the prefix match). Flake evaluation is
              # pure, so no `nixpkgs.config` of the caller's reaches this
              # import: without the predicate `kirocrew-with-kiro-cli` is not
              # buildable from this flake at all, and `nix run
              # .#kirocrew-with-kiro-cli` would demand `--impure` plus
              # NIXPKGS_ALLOW_UNFREE. The default `kirocrew` stays free.
              config.allowUnfreePredicate = pkg: lib.hasPrefix "kiro-cli" (lib.getName pkg);
            }
          )
        );
    in
    {
      overlays.default = final: prev: {
        kirocrew-dashboard = final.callPackage ./nix/dashboard.nix { };

        kirocrew = final.callPackage ./nix/kirocrew.nix {
          # setup.cfg declares >=3.10 with no upper bound; CI covers 3.10 and
          # 3.12. 3.13 is picked over the tested 3.12 for one reason: nixpkgs'
          # default interpreter is 3.14, and Hydra only populates the binary
          # cache for the default and 3.13. On 3.12, uv (Rust), slack-sdk, and
          # scipy have no substitute and compile from source, turning a
          # two-minute build into the better part of an hour. Keep this in step
          # with what Hydra caches when the default interpreter moves.
          python3 = final.python313;
          # Explicit null so callPackage does NOT auto-fill nixpkgs' own
          # `kiro-cli`, which is unfree: that would make plain `nix build` fail
          # for anyone without allowUnfree and take the binary cache with it.
          # The wrapper falls back to PATH discovery instead.
          kiro-cli = null;
        };

        # Same package with the backend pinned into the wrapper, so the gateway
        # needs nothing on PATH. Unfree (Kiro CLI ships under Amazon's own
        # terms), which is why it is an opt-in attribute and not `kirocrew`
        # itself — see README § Nix.
        kirocrew-with-kiro-cli = final.kirocrew.override { inherit (final) kiro-cli; };
      };

      packages = forAllSystems (pkgs: {
        default = pkgs.kirocrew;
        inherit (pkgs) kirocrew kirocrew-dashboard;
        # Unfree, and deliberately kept out of `checks`: `nix flake check` must
        # stay buildable from the free binary cache alone. Reachable as
        # `nix run .#kirocrew-with-kiro-cli` for anyone who accepts Amazon's
        # terms — see README § Kiro CLI is not bundled.
        inherit (pkgs) kirocrew-with-kiro-cli;
      });

      apps = forAllSystems (pkgs: {
        default = self.apps.${pkgs.stdenv.hostPlatform.system}.kirocrew;

        kirocrew = {
          type = "app";
          program = lib.getExe pkgs.kirocrew;
          meta.description = "Kiro Crew CLI";
        };

        kirocrew-browse = {
          type = "app";
          program = lib.getExe' pkgs.kirocrew "kirocrew-browse";
          meta.description = "Kiro Crew headless-browser helper";
        };

        # Gateway + Vite together, against the working tree. Not a package
        # output: it only makes sense inside a checkout.
        dev = {
          type = "app";
          program = lib.getExe (pkgs.callPackage ./nix/dev-app.nix { });
          meta.description = "Run the gateway and the dashboard dev server together";
        };

        # Refreshes dashboard.nix's npmDepsHash from the working tree's
        # website/package-lock.json. Not a package output, and not wired into
        # `checks`: it writes to the checkout, which a check must not do.
        update-npm-hash = {
          type = "app";
          program = lib.getExe (pkgs.callPackage ./nix/update-npm-hash.nix { });
          meta.description = "Refresh dashboard.nix's npmDepsHash from website/package-lock.json";
        };
      });

      devShells = forAllSystems (pkgs: {
        # A pure-Nix shell: no venv, no `pip install -e .`. setup.cfg sets
        # `pythonpath = src`, so pytest and the CLI both resolve the working
        # tree directly.
        default = pkgs.mkShell {
          packages = [
            # passthru.python, not a literal: the interpreter is chosen once in
            # the overlay and the shell must not drift from what the package
            # was built against.
            (pkgs.kirocrew.python.withPackages (
              ps:
              pkgs.kirocrew.dependencies
              ++ [
                ps.black
                ps.flake8
                ps.hypothesis
                ps.isort
                ps.jsonschema
                ps.mypy
                ps.pytest
                ps.pytest-asyncio
                ps.pytest-cov
                ps.pytest-timeout
                ps.pytest-xdist
                ps.setuptools
                ps.wheel
              ]
            ))
            pkgs.nodejs_22
            pkgs.git
            pkgs.ripgrep
          ];

          shellHook = ''
            # ensure-node.sh would otherwise try to install its own node into
            # the data home; point the runtime at the pinned one instead.
            export KIROCREW_NODE_BIN_DIR="${pkgs.nodejs_22}/bin"

            # setup.cfg's `pythonpath = src` sits under [tool:pytest], so it
            # puts the working tree on the path for pytest and nothing else.
            # Without this the shell can run the tests but not the CLI they
            # cover. Resolved from the repo root, not $PWD, so entering the
            # shell from a subdirectory still points at the right tree.
            export PYTHONPATH="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")/src''${PYTHONPATH:+:$PYTHONPATH}"

            echo "Kiro Crew dev shell — python $(python3 --version | cut -d' ' -f2), node $(node --version)"
            echo "  run the CLI:    python -m kiro_crew --help"
            echo "  backend tests:  pytest"
            echo "  dashboard:      cd website && npm ci && npm run build"
            echo "  kiro-cli is NOT provided by nixpkgs; install it separately."
          '';
        };
      });

      checks = forAllSystems (
        pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
        in
        {
          inherit (self.packages.${system}) kirocrew kirocrew-dashboard;

          # Guards the two things this flake actually wires up beyond a plain
          # `pip install`: the console script runs against the Nix-resolved
          # dependency set, and the separately-built dashboard really landed on
          # the path the backend serves it from.
          smoke =
            pkgs.runCommand "kirocrew-smoke"
              {
                nativeBuildInputs = [ pkgs.kirocrew ];
              }
              ''
                # Even `--help` resolves the data home and mkdirs it, so the
                # sandbox's unwritable /homeless-shelter HOME fails the run
                # before argument parsing produces any output.
                export HOME="$NIX_BUILD_TOP/home"
                export KIROCREW_HOME="$NIX_BUILD_TOP/home/.kiro/crew"
                mkdir -p "$HOME"

                kirocrew --help > /dev/null
                dist="${pkgs.kirocrew}/${pkgs.kirocrew.python.sitePackages}/kiro_crew/static/dist"
                test -f "$dist/index.html" || {
                  echo "dashboard missing from the installed package: $dist" >&2
                  exit 1
                }
                touch "$out"
              '';
        }
      );

      nixosModules.default = import ./nix/nixos-module.nix { inherit self; };
      homeManagerModules.default = import ./nix/hm-module.nix { inherit self; };

      formatter = forAllSystems (pkgs: pkgs.nixfmt-rfc-style);
    };
}

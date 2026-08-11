# `nix run .#update-npm-hash` — refresh dashboard.nix's npmDepsHash from the
# working tree's website/package-lock.json.
#
# npmDepsHash cannot be computed at build or eval time (see the comment above
# it in dashboard.nix): the tool that hashes the npm deps has to fetch them
# over the network itself, which needs its own sandboxed-fetch permission —
# the exact thing a hash is for. So the lockfile and the hash can drift, and
# `nix flake check` (which builds kirocrew-dashboard) is what catches that,
# same as any other build failure. This app is the one-command fix once it
# does.
{
  lib,
  writeShellApplication,
  nix,
  gnused,
  git,
}:

writeShellApplication {
  name = "update-npm-hash";

  runtimeInputs = [
    nix
    gnused
    git
  ];

  text = ''
    root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -z "$root" ] || [ ! -f "$root/nix/dashboard.nix" ]; then
      echo "update-npm-hash: run this from a Kiro Crew checkout." >&2
      exit 1
    fi
    cd "$root"

    lockfile="website/package-lock.json"
    dashboard_nix="nix/dashboard.nix"

    new_hash="$(nix run nixpkgs#prefetch-npm-deps -- "$lockfile")"
    old_hash="$(sed -n 's/.*npmDepsHash = "\(sha256-[^"]*\)".*/\1/p' "$dashboard_nix")"

    if [ "$old_hash" = "$new_hash" ]; then
      echo "npmDepsHash is already up to date with $lockfile"
      exit 0
    fi

    sed -i "s#npmDepsHash = \"$old_hash\"#npmDepsHash = \"$new_hash\"#" "$dashboard_nix"

    echo "npmDepsHash updated in $dashboard_nix:"
    echo "  old: $old_hash"
    echo "  new: $new_hash"
  '';

  meta = {
    description = "Refresh dashboard.nix's npmDepsHash from website/package-lock.json";
    mainProgram = "update-npm-hash";
  };
}

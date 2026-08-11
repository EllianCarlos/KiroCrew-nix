# `nix run .#dev` — the full-stack dev loop as one command.
#
# CONTRIBUTING.md § Full-Stack Dev Setup describes this as three terminals:
# start the gateway, start Vite, mint a token, then hand-assemble the URL. This
# runs all of it, waits for each side to actually listen, prints the one link
# that works, and tears both down together on Ctrl-C.
#
# The backend runs FROM SOURCE (PYTHONPATH=src), not from the built package, so
# a Python edit needs only a restart rather than a rebuild. The dashboard is
# served by Vite rather than the copy baked into the package, so .tsx edits
# hot-reload.
{
  lib,
  writeShellApplication,
  kirocrew,
  nodejs_22,
  git,
  curl,
}:

let
  # The same interpreter and runtime set the package is built against, so the
  # dev loop cannot drift from what ships.
  pythonEnv = kirocrew.python.withPackages (_: kirocrew.dependencies);
in

writeShellApplication {
  name = "kirocrew-dev";

  runtimeInputs = [
    pythonEnv
    nodejs_22
    git
    curl
  ];

  text = ''
    root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -z "$root" ] || [ ! -f "$root/src/kiro_crew/__main__.py" ]; then
      echo "kirocrew-dev: run this from a Kiro Crew checkout (it serves the working tree)." >&2
      exit 1
    fi
    cd "$root"

    # Isolated by default: the dev loop must never touch a real ~/.kiro/crew,
    # whose sessions and credentials belong to the installed gateway.
    export KIROCREW_HOME="''${KIROCREW_HOME:-$root/.kirocrew-dev}"
    export KIROCREW_PORT="''${KIROCREW_PORT:-6777}"
    ui_port="''${KIROCREW_DEV_UI_PORT:-3000}"

    export PYTHONPATH="$root/src''${PYTHONPATH:+:$PYTHONPATH}"
    # Keep the runtime off any mise/nvm node and on the pinned one.
    export KIROCREW_NODE_BIN_DIR="${nodejs_22}/bin"

    backend_pid=""
    vite_pid=""
    cleanup() {
      # Negated PIDs: Vite and the gateway both spawn children that outlive a
      # bare kill and keep the ports bound.
      [ -n "$vite_pid" ] && kill -- "-$vite_pid" 2>/dev/null || true
      [ -n "$backend_pid" ] && kill -- "-$backend_pid" 2>/dev/null || true
    }
    trap cleanup EXIT INT TERM

    if [ ! -d website/node_modules ]; then
      echo "==> installing dashboard dependencies (first run only)"
      ( cd website && npm ci )
    fi

    echo "==> backend  : http://localhost:$KIROCREW_PORT  (KIROCREW_HOME=$KIROCREW_HOME)"
    setsid python -m kiro_crew gateway --no-open &
    backend_pid=$!

    # Poll rather than sleep: first run migrates the data home and can take a
    # while, and a fixed sleep would either race it or waste time every run.
    until curl -sf -o /dev/null "http://127.0.0.1:$KIROCREW_PORT/"; do
      if ! kill -0 "$backend_pid" 2>/dev/null; then
        echo "kirocrew-dev: the gateway exited during startup." >&2
        exit 1
      fi
      sleep 1
    done

    echo "==> frontend : starting Vite on port $ui_port"
    ( cd website && setsid npm run dev -- --port "$ui_port" --strictPort ) &
    vite_pid=$!

    until curl -sf -o /dev/null "http://127.0.0.1:$ui_port/"; do
      if ! kill -0 "$vite_pid" 2>/dev/null; then
        echo "kirocrew-dev: the Vite dev server exited during startup." >&2
        exit 1
      fi
      sleep 1
    done

    # The gateway trusts loopback without a token in its default config, but it
    # does not have to; mint one so the link works either way. Vite's
    # token-proxy plugin performs the handshake and drops the query string.
    token="$(python -m kiro_crew token 2>/dev/null | grep -oE 'token=[A-Za-z0-9._~+/=-]+' | head -1 || true)"

    echo ""
    echo "  ────────────────────────────────────────────────────────────"
    if [ -n "$token" ]; then
      echo "   Open:  http://localhost:$ui_port/?$token"
    else
      echo "   Open:  http://localhost:$ui_port/"
    fi
    echo "   Hot-reloads .tsx/.ts/.css. Restart for Python changes."
    echo "   Ctrl-C stops both."
    echo "  ────────────────────────────────────────────────────────────"
    echo ""

    # Surface whichever side dies first instead of hanging on the survivor.
    wait -n "$backend_pid" "$vite_pid"
  '';

  meta = {
    description = "Run the Kiro Crew gateway and the Vite dev server together";
    mainProgram = "kirocrew-dev";
  };
}

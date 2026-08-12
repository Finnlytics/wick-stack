#!/usr/bin/env bash
#
# run-demo.sh — the whole Wick demo in one terminal.
#
# Starts the LwM2M demo server (CoAP on UDP 5683, web UI on 8683) and a demo device that
# registers with it, streams both logs side by side, and opens the UI. Ctrl-C stops both,
# giving the device a chance to deregister first.
#
# Both nodes run with distribution on, so the IEx recipes in the demo READMEs are still
# reachable — the `iex --remsh` lines to attach are printed at startup.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$ROOT/demo/wick_demo_server"
CLIENT_DIR="$ROOT/demo/wick_demo_client"
LOG_DIR="$ROOT/demo/.logs"

SERVER_LOG="$LOG_DIR/server.log"
CLIENT_LOG="$LOG_DIR/client.log"

# Distribution names, so `iex --remsh` can attach to either node. The cookie is a fixed
# well-known string because this is a loopback demo, not a deployment.
SERVER_NODE="wick-demo-server"
CLIENT_NODE="wick-demo-device"
COOKIE="wick-demo"

# How long to wait for the server's web UI to answer before giving up.
BOOT_TIMEOUT_S=45

run_server=1
run_client=1
open_browser=1

usage() {
  cat <<'USAGE'
Usage: ./run-demo.sh [options]

Starts the Wick LwM2M demo server and a demo device in one terminal, streams both
logs, and opens the web UI.

  --no-open       don't open a browser
  --server-only   just the server (point Leshan or a real device at coap://127.0.0.1:5683)
  --client-only   just the device (a server is already running elsewhere)
  -h, --help      this message

Ctrl-C stops everything. Logs are kept in demo/.logs/.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --server-only) run_client=0 ;;
    --client-only) run_server=0; open_browser=0 ;;
    --no-open)     open_browser=0 ;;
    -h|--help)     usage; exit 0 ;;
    *)             echo "run-demo.sh: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# ── Output ───────────────────────────────────────────────────────────────────

if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
  TEAL=$'\033[36m'; PURPLE=$'\033[35m'; RED=$'\033[31m'
else
  BOLD=""; DIM=""; RESET=""; TEAL=""; PURPLE=""; RED=""
fi

say()  { printf '%s%s%s\n' "$BOLD" "$1" "$RESET"; }
note() { printf '%s%s%s\n' "$DIM" "$1" "$RESET"; }
die()  { printf '%serror:%s %s\n' "$RED" "$RESET" "$1" >&2; exit 1; }

# Prefix every line of a log file with a coloured label, so two nodes can share one terminal.
# Blank lines are dropped: Elixir's console logger puts one before every entry, which is fine
# in a terminal of its own and pure noise once each line carries a label.
stream() {
  local label="$1" colour="$2" file="$3"
  tail -n +1 -f "$file" 2>/dev/null | while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s%s%s %s\n' "$colour" "$label" "$RESET" "$line"
  done
}

# ── Shutdown ─────────────────────────────────────────────────────────────────

NODE_PIDS=()
TAIL_PIDS=()

cleanup() {
  trap - INT TERM EXIT
  printf '\n'
  say "Stopping…"

  # SIGTERM shuts the BEAM down gracefully, which runs Registrar.terminate/2 and sends a
  # Deregister. The device is in NODE_PIDS after the server, and killing it in reverse is why
  # the UI empties out rather than showing a client that only reaps 60s later.
  #
  # The server usually needs the SIGKILL that follows: an open browser tab holds an SSE
  # connection that by design never completes, and Bandit waits on it. Nothing is lost — by
  # then the device has already said goodbye.
  local i
  for (( i = ${#NODE_PIDS[@]} - 1; i >= 0; i-- )); do
    local pid="${NODE_PIDS[$i]}"
    kill "$pid" 2>/dev/null || true
    local waited=0
    while [ "$waited" -lt 25 ]; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.2
      waited=$(( waited + 1 ))
    done
    kill -9 "$pid" 2>/dev/null || true
  done

  # A backgrounded pipeline runs in a subshell, so TAIL_PIDS holds the subshell and the
  # `tail -f` inside it is a child of that. Killing only the subshell leaves the tail behind,
  # following a file nothing will write to again — one stray process per node, per run.
  local pid
  for pid in "${TAIL_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
  done

  note "Logs kept in demo/.logs/"
}

# ── Preflight ────────────────────────────────────────────────────────────────

command -v mix >/dev/null  || die "mix not found — install Elixir ~> 1.19 (see the README)."
command -v curl >/dev/null || die "curl not found — it's used to wait for the web UI."

[ -d "$SERVER_DIR" ] || die "$SERVER_DIR is missing; run this from a checkout of wick-stack."
[ -d "$CLIENT_DIR" ] || die "$CLIENT_DIR is missing; run this from a checkout of wick-stack."

# A server left running from a previous session is the likeliest reason this appears to work
# but shows nothing: the new one can't bind 5683, and the device registers with the old one.
if [ "$run_server" = 1 ] && command -v lsof >/dev/null; then
  if lsof -nP -iUDP:5683 >/dev/null 2>&1; then
    die "something is already listening on UDP 5683 — stop it, or use --client-only."
  fi
fi

mkdir -p "$LOG_DIR"

# `mix run` would fetch and compile inline, but that output interleaves with the boot log and
# a cold first run looks like a hang. Doing it up front keeps the streamed log clean.
prepare() {
  local dir="$1" name="$2"
  local rel="${dir#$ROOT/}"
  say "Building ${name}…"
  (cd "$dir" && mix deps.get >/dev/null && mix compile) \
    || die "${name} failed to build — run 'cd ${rel} && mix compile' to see why."
}

if [ "$run_server" = 1 ]; then prepare "$SERVER_DIR" "wick_demo_server"; fi
if [ "$run_client" = 1 ]; then prepare "$CLIENT_DIR" "wick_demo_client"; fi

# INT and TERM exit rather than falling back into the main loop, which would otherwise find the
# nodes it just stopped and announce them as a crash.
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap cleanup EXIT

# ── Boot ─────────────────────────────────────────────────────────────────────

# `elixir --sname … -S mix run --no-halt` rather than `iex -S mix`: no shell competing for this
# terminal, but the node is still named, so `iex --remsh` gets you a prompt on demand.
boot() {
  local dir="$1" node="$2" log="$3"
  : > "$log"
  (cd "$dir" && exec elixir --sname "$node" --cookie "$COOKIE" -S mix run --no-halt) \
    >> "$log" 2>&1 &
  BOOTED_PID=$!
  NODE_PIDS+=("$BOOTED_PID")
  # Off the job table, so shutting down doesn't print a wall of "Terminated: 15" over the
  # goodbye message. The PID is still ours to signal and to poll with `kill -0`.
  disown "$BOOTED_PID" 2>/dev/null || true
}

ui_url=""
coap_port=""

if [ "$run_server" = 1 ]; then
  say "Starting the LwM2M server…"
  boot "$SERVER_DIR" "$SERVER_NODE" "$SERVER_LOG"
  server_pid="$BOOTED_PID"

  # Read the UI's address out of the boot log rather than assuming 8683 — the port lives in
  # config/config.exs, and reading it back is how the two can't drift apart.
  deadline=$(( SECONDS + BOOT_TIMEOUT_S ))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if ! kill -0 "$server_pid" 2>/dev/null; then
      note "--- server log ---"; cat "$SERVER_LOG"
      die "the server exited during boot."
    fi

    ui_url="$(grep -o 'http://[0-9.]*:[0-9]*' "$SERVER_LOG" | head -1 || true)"
    if [ -n "$ui_url" ] && curl -fsS -o /dev/null --max-time 2 "$ui_url/api/summary"; then
      break
    fi
    ui_url=""
    sleep 0.3
  done

  if [ -z "$ui_url" ]; then
    note "--- server log ---"; cat "$SERVER_LOG"
    die "the web UI didn't come up within ${BOOT_TIMEOUT_S}s."
  fi

  coap_port="$(grep -o 'udp:[0-9]*' "$SERVER_LOG" | head -1 | cut -d: -f2 || true)"
fi

if [ "$run_client" = 1 ]; then
  say "Starting the device…"
  boot "$CLIENT_DIR" "$CLIENT_NODE" "$CLIENT_LOG"
fi

# ── What to do now ───────────────────────────────────────────────────────────

host="$(hostname -s)"

printf '\n'
say "── Wick demo ─────────────────────────────────────────────────────"
if [ "$run_server" = 1 ]; then
  printf '  %sWeb UI%s   %s\n' "$BOLD" "$RESET" "$ui_url"
  printf '  %sCoAP%s     coap://127.0.0.1:%s   %s(aim Leshan or a real device here)%s\n' \
    "$BOLD" "$RESET" "${coap_port:-5683}" "$DIM" "$RESET"
  printf '\n'
  printf '  %sIn the UI:%s\n' "$BOLD" "$RESET"
  printf '    1. Click the client in the %sClients%s pane on the left.\n' "$TEAL" "$RESET"
  printf '    2. Expand %s3303 Temperature%s and hit %sRead%s on /3303/0.\n' \
    "$BOLD" "$RESET" "$PURPLE" "$RESET"
  printf '    3. Open %sAttributes…%s on it, set pmin 5 and st 0.2, write them.\n' \
    "$PURPLE" "$RESET"
  printf '    4. Hit %sObserve%s and watch Notifications land in the Event Log.\n' \
    "$TEAL" "$RESET"
  printf '    %sThe Guide button in the page header walks through the same thing.%s\n' \
    "$DIM" "$RESET"
fi
printf '\n'
printf '  %sIEx shells%s — in another terminal, for the recipes in the READMEs:\n' \
  "$BOLD" "$RESET"
if [ "$run_server" = 1 ]; then
  printf '    iex --sname console-a --cookie %s --remsh %s@%s\n' "$COOKIE" "$SERVER_NODE" "$host"
fi
if [ "$run_client" = 1 ]; then
  printf '    iex --sname console-b --cookie %s --remsh %s@%s\n' "$COOKIE" "$CLIENT_NODE" "$host"
fi
printf '\n'
printf '  %sCtrl-C stops everything. Logs are kept in demo/.logs/.%s\n' "$DIM" "$RESET"
say "──────────────────────────────────────────────────────────────────"
printf '\n'

if [ "$open_browser" = 1 ] && [ -n "$ui_url" ]; then
  if command -v open >/dev/null; then
    open "$ui_url" || true
  elif command -v xdg-open >/dev/null; then
    xdg-open "$ui_url" >/dev/null 2>&1 || true
  fi
fi

# ── Stream both logs until Ctrl-C ────────────────────────────────────────────

if [ "$run_server" = 1 ]; then
  stream "server" "$PURPLE" "$SERVER_LOG" &
  TAIL_PIDS+=("$!")
  disown "$!" 2>/dev/null || true
fi
if [ "$run_client" = 1 ]; then
  stream "device" "$TEAL" "$CLIENT_LOG" &
  TAIL_PIDS+=("$!")
  disown "$!" 2>/dev/null || true
fi

# Poll rather than `wait`: waiting would also wait on the tails, which never exit, so a node
# that dies would leave the script sitting on a log that will never gain another line.
while :; do
  for pid in "${NODE_PIDS[@]}"; do
    if ! kill -0 "$pid" 2>/dev/null; then
      sleep 0.5   # let the tail catch the last lines before cleanup kills it
      printf '\n%sA node exited — see the log above.%s\n' "$RED" "$RESET"
      exit 1
    fi
  done
  sleep 1
done

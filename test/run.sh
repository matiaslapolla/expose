#!/usr/bin/env bash
# End-to-end tests against a stub tailscale. Needs: bash, jq, python3, node + npm; tmux optional.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
EXPOSE=$ROOT/bin/expose
TMP=$(mktemp -d)
FAILS=0

cleanup() {
  local f kind ref
  for f in "$TMP"/state/expose/*.run; do
    [[ -f $f ]] || continue
    read -r kind ref <"$f"
    case $kind in
      tmux) tmux kill-session -t "=$ref" 2>/dev/null ;;
      pid) pkill -P "$ref" 2>/dev/null; kill "$ref" 2>/dev/null ;;
    esac
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

export XDG_CONFIG_HOME=$TMP/config XDG_STATE_HOME=$TMP/state
export STUB_LOG=$TMP/tailscale.log
export EXPOSE_TAILSCALE=$TMP/tailscale EXPOSE_PORT_MIN=41300 EXPOSE_PORT_MAX=41399 EXPOSE_WAIT=20
unset EXPOSE_MODE EXPOSE_CMD EXPOSE_RUNNER EXPOSE_HTTPS_OFFSET

cat >"$EXPOSE_TAILSCALE" <<'EOF'
#!/bin/sh
echo "$*" >>"$STUB_LOG"
case "$1 $2" in
  "status --json") echo '{"Self":{"DNSName":"box.tail123.ts.net."}}' ;;
  "serve status") echo "stub serve status" ;;
esac
EOF
chmod +x "$EXPOSE_TAILSCALE"

pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; echo "     ${2//$'\n'/$'\n'     }"; FAILS=$((FAILS + 1)); }
expect() { # name, haystack, needle
  if [[ $2 == *"$3"* ]]; then pass "$1"; else fail "$1" "expected to contain: $3"$'\n'"got: $2"; fi
}
reject() {
  if [[ $2 != *"$3"* ]]; then pass "$1"; else fail "$1" "expected not to contain: $3"$'\n'"got: $2"; fi
}
listening() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

app() { # name, lockfile -> dir with a dev script that honours --port
  local d=$TMP/$1
  mkdir -p "$d"
  echo '{"scripts":{"dev":"node server.js"}}' >"$d/package.json"
  cat >"$d/server.js" <<'EOF'
const port = +process.argv[process.argv.indexOf('--port') + 1];
require('http').createServer((_, res) => res.end('hi')).listen(port, '127.0.0.1');
EOF
  [[ -n $2 ]] && touch "$d/$2"
  echo "$d"
}

# --- config ---
d=$(app pnpmapp pnpm-lock.yaml)
expect "pnpm detection" "$(cd "$d" && "$EXPOSE" config)" "command: pnpm run dev --port {port}"
d=$(app npmapp package-lock.json)
expect "npm detection" "$(cd "$d" && "$EXPOSE" config)" "command: npm run dev -- --port {port}"

mkdir -p "$XDG_CONFIG_HOME/expose"
echo "EXPOSE_HTTPS_OFFSET=1" >"$XDG_CONFIG_HOME/expose/config"
expect "global config" "$(cd "$d" && "$EXPOSE" config)" "EXPOSE_HTTPS_OFFSET=1"
printf '# comment\nEXPOSE_HTTPS_OFFSET = "2"\nEXPOSE_CMD=python3 -m http.server {port}\n' >"$d/.expose"
out=$(cd "$d" && "$EXPOSE" config)
expect "project config beats global" "$out" "EXPOSE_HTTPS_OFFSET=2"
expect "quoted value and EXPOSE_CMD" "$out" "command: python3 -m http.server {port}"
expect "env beats project config" "$(cd "$d" && EXPOSE_HTTPS_OFFSET=3 "$EXPOSE" config)" "EXPOSE_HTTPS_OFFSET=3"
echo "BOGUS=1" >>"$d/.expose"
expect "unknown key warns" "$(cd "$d" && "$EXPOSE" config 2>&1)" "unknown key BOGUS"
rm -f "$d/.expose" "$XDG_CONFIG_HOME/expose/config"

expect "invalid mode fails" "$(cd "$d" && EXPOSE_MODE=nope "$EXPOSE" 2>&1)" "EXPOSE_MODE must be serve or direct"
expect "no package.json and no EXPOSE_CMD fails" "$(cd "$TMP" && "$EXPOSE" 2>&1)" "set EXPOSE_CMD"

# --- start, reuse, stop (each runner) ---
runners=(background)
command -v tmux >/dev/null && runners+=(tmux)
for runner in "${runners[@]}"; do
  export EXPOSE_RUNNER=$runner
  d=$(app "app-$runner" package-lock.json)
  : >"$STUB_LOG"
  out=$(cd "$d" && "$EXPOSE" 2>&1)
  port=$(sed -nE 's/^http:\/\/box:([0-9]+).*/\1/p' <<<"$out")
  expect "[$runner] starts and prints https url" "$out" "https://box.tail123.ts.net:$((port + 10000))"
  if listening "$port"; then pass "[$runner] dev server listens on $port"; else fail "[$runner] dev server listens" "$out"; fi
  expect "[$runner] calls tailscale serve" "$(cat "$STUB_LOG")" "serve --bg --https=$((port + 10000)) http://127.0.0.1:$port"

  out=$(cd "$d" && "$EXPOSE" 2>&1)
  reject "[$runner] second run reuses the server" "$out" "starting"
  expect "[$runner] ls marks it" "$("$EXPOSE" ls)" "[started by expose]"

  out=$("$EXPOSE" off "$port" 2>&1)
  expect "[$runner] off stops it" "$out" "stopped dev server on :$port"
  sleep 1
  if listening "$port"; then fail "[$runner] port freed after off" "still listening"; else pass "[$runner] port freed after off"; fi
  expect "[$runner] off calls serve off" "$(cat "$STUB_LOG")" "serve --https=$((port + 10000)) off"
done
unset EXPOSE_RUNNER

# --- explicit port, EXPOSE_CMD, direct mode ---
d=$TMP/py && mkdir -p "$d"
: >"$STUB_LOG"
out=$(cd "$d" && EXPOSE_MODE=direct EXPOSE_RUNNER=background EXPOSE_CMD='python3 -m http.server {port} --bind 127.0.0.1' "$EXPOSE" 41350 2>&1)
expect "EXPOSE_CMD on an explicit port" "$out" "http://box:41350"
reject "direct mode skips tailscale serve" "$(cat "$STUB_LOG")" "serve --bg"
EXPOSE_MODE=direct "$EXPOSE" off 41350 >/dev/null

out=$(cd "$d" && EXPOSE_RUNNER=background EXPOSE_CMD='sh -c "echo boom; exit 3"' "$EXPOSE" 41351 2>&1)
expect "crashing server is reported" "$out" "dev server exited before listening"
expect "crash output is shown" "$out" "boom"

echo
if ((FAILS)); then echo "$FAILS failed"; exit 1; fi
echo "all passed"

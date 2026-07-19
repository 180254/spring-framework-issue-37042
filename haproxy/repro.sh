#!/usr/bin/env bash
# Reproduces the ~200 ms response-tail delay described in README.md.
#
# Topology: curl (HTTP/1.1, keep-alive, sequential) -> haproxy -> scripted h2c backend
# (h2-backend.py). The backend responds with HEADERS + DATA(N, no END_STREAM), then a small
# gap, then an empty DATA(0, END_STREAM) - a legal HTTP/2 pattern that Jetty 12 emits for
# Spring Framework 7.0.5+ responses carrying a Content-Length.
#
# Cells:
#   split      x default        -> EXPECTED SLOW (~208 ms/request): the last body send is
#                                  flagged MSG_MORE (backend EOM not seen yet) and the EOM
#                                  produces no output bytes to uncork the socket
#   split      x http-no-delay  -> fast (MSG_MORE disabled)
#   split-nocl x default        -> fast (no content-length in the response; haproxy forwards
#                                  it to the h1 client as chunked, whose terminal chunk
#                                  flushes the socket - only CL-framed responses are hit)
#   merged     x default        -> fast (END_STREAM arrives with the body; no split)
#
# Requires docker (HAPROXY_IMAGE, default haproxy:3.5-dev; any 2.x/3.x reproduces),
# Python 3.9+, curl 7.33+. Docker must provide real host networking (native Linux; Docker
# Desktop/rootless run --network host inside a VM/namespace and will not work).
# BYTES is capped at 16384: the scripted backend sends the body as a single h2 DATA
# frame and must not exceed the peer's default SETTINGS_MAX_FRAME_SIZE. Example:
#   HAPROXY_IMAGE=haproxy:2.8 ./repro.sh
set -euo pipefail

SCRIPT_DIR="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)"
die() { echo "dependency check failed: $*" >&2; exit 127; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' was not found in PATH"; }

for tool in awk curl docker mktemp python3 rm seq sleep sort tail; do
  need "$tool"
done
python3 -c 'import sys; raise SystemExit(sys.version_info < (3, 9))' || die "Python 3.9+ is required"
[[ "$(curl --help all 2>/dev/null)" == *--http1.1* ]] || die "curl 7.33+ is required"
docker info >/dev/null 2>&1 || die "Docker daemon is unavailable"

cd "$SCRIPT_DIR"

unused_port() {
  local base="$1" span="$2" port
  while port=$((base + RANDOM % span)) && (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; do :; done
  echo "$port"
}

HAPROXY_IMAGE="${HAPROXY_IMAGE:-haproxy:3.5-dev}"
BYTES="${BYTES:-4096}"
GAP_MS="${GAP_MS:-5}"
REQUESTS="${REQUESTS:-15}"
BACKEND_PORT="${BACKEND_PORT:-$(unused_port 20000 10000)}"
PROXY_PORT="${PROXY_PORT:-$(unused_port 30000 10000)}"       # haproxy defaults (MSG_MORE active)
PROXY_ND_PORT="${PROXY_ND_PORT:-$(unused_port 40000 10000)}" # haproxy with "option http-no-delay"
RESULTS="$(mktemp)"
HAPROXY_DIR="$(mktemp -d)"
HAPROXY_NAME="haproxy-cork-repro"

if [ "$BYTES" -gt 16384 ]; then
  echo "BYTES=$BYTES exceeds 16384 (single h2 DATA frame; peer SETTINGS_MAX_FRAME_SIZE default)" >&2
  exit 1
fi

backend_pid=""
cleanup() {
  docker rm -f "$HAPROXY_NAME" >/dev/null 2>&1 || true
  if [ -n "$backend_pid" ]; then
    kill "$backend_pid" 2>/dev/null || true
  fi
  rm -rf "$HAPROXY_DIR" "$RESULTS"
}
trap cleanup EXIT

cat >"$HAPROXY_DIR/haproxy.cfg" <<EOF
global
    maxconn 100

defaults
    mode http
    timeout connect 5s
    timeout client 60s
    timeout server 60s

frontend fe_default
    bind 0.0.0.0:${PROXY_PORT}
    default_backend be_app

frontend fe_nodelay
    bind 0.0.0.0:${PROXY_ND_PORT}
    option http-no-delay
    default_backend be_nodelay

backend be_app
    server app 127.0.0.1:${BACKEND_PORT} proto h2

backend be_nodelay
    option http-no-delay
    server app 127.0.0.1:${BACKEND_PORT} proto h2
EOF

wait_for_up() {
  local url="$1" tries=30
  while [ "$tries" -gt 0 ]; do
    curl -fsS -o /dev/null "$url" 2>/dev/null && return 0
    tries=$((tries - 1))
    sleep 1
  done
  return 1
}

# Sequential closed-loop client: one keep-alive HTTP/1.1 connection, REQUESTS transfers.
# Prints "<http_code> <time_starttransfer> <time_total>" per transfer (seconds).
# "|| true": a transient transfer failure must not abort the run under set -e;
# stats() flags it instead of silently averaging bogus near-zero timings.
measure() {
  local url="$1"
  local args=()
  for _ in $(seq 1 "$REQUESTS"); do
    args+=(-o /dev/null -w '%{http_code} %{time_starttransfer} %{time_total}\n' "$url")
  done
  curl -s --http1.1 "${args[@]}" || true
}

# Reads measure() output, prints "<median_ms> <p90_ms>" of time_total. Any non-200
# transfer (5xx, or 000 for transport errors) invalidates the cell: failed transfers
# report near-zero timings that would otherwise corrupt the percentiles.
stats() {
  LC_ALL=C sort -k3 -n | LC_ALL=C awk -v want="$REQUESTS" '
    { if ($1 != "200") bad++; total[NR] = $3 * 1000 }
    END {
      if (NR != want || bad > 0) { printf "FAILED(%d/%d-ok) -\n", NR - bad, want; exit }
      median = total[int((NR + 1) / 2)]
      p90 = total[int(NR * 0.9) > 0 ? int(NR * 0.9) : 1]
      printf "%.1f %.1f\n", median, p90
    }'
}

row() {
  local mode="$1" route="$2" port="$3"
  local out med p90
  out="$(measure "http://127.0.0.1:${port}/" | stats)"
  med="${out%% *}"
  p90="${out##* }"
  printf '%s\t%s\t%s\t%s\n' "$mode" "$route" "$med" "$p90" >>"$RESULTS"
  echo "  mode=$mode route=$route: median ${med} ms, p90 ${p90} ms"
}

# No --rm: if haproxy exits at startup (e.g. port conflict), the container must
# survive so the failure path below can still show its logs; cleanup removes it.
docker rm -f "$HAPROXY_NAME" >/dev/null 2>&1 || true
docker run -d --name "$HAPROXY_NAME" --network host \
  -v "$HAPROXY_DIR/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro" \
  "$HAPROXY_IMAGE" >/dev/null

for cell in split split-nocl merged; do
  backend_args=(--port "$BACKEND_PORT" --bytes "$BYTES" --gap-ms "$GAP_MS")
  case "$cell" in
  split) backend_args+=(--mode split) ;;
  split-nocl) backend_args+=(--mode split --no-content-length) ;;
  merged) backend_args+=(--mode merged) ;;
  esac
  python3 h2-backend.py "${backend_args[@]}" >/dev/null 2>&1 &
  backend_pid=$!
  if ! wait_for_up "http://127.0.0.1:${PROXY_PORT}/"; then
    echo "SETUP FAILED (backend or haproxy not reachable; needs native-Linux docker host networking and free ports ${PROXY_PORT}/${PROXY_ND_PORT}/${BACKEND_PORT})"
    docker logs "$HAPROXY_NAME" 2>&1 | tail -5 || true
    exit 1
  fi
  row "$cell" "default" "$PROXY_PORT"
  if [ "$cell" = "split" ]; then
    row "$cell" "http-no-delay" "$PROXY_ND_PORT"
  fi
  kill "$backend_pid" 2>/dev/null || true
  wait "$backend_pid" 2>/dev/null || true
  backend_pid=""
  sleep 1
done

echo
echo "===== SUMMARY (sequential HTTP/1.1 keep-alive client, ${REQUESTS} requests, bytes=$BYTES, gap=${GAP_MS}ms, image=$HAPROXY_IMAGE) ====="
printf '%-12s %-15s %-10s %-10s\n' CELL ROUTE MEDIAN_MS P90_MS
printf '%-12s %-15s %-10s %-10s\n' ---- ----- --------- ------
awk -F'\t' '{ printf "%-12s %-15s %-10s %-10s\n", $1, $2, $3, $4 }' "$RESULTS"

echo
echo "Expected: only {split, default} is slow (~208 ms median); {split, http-no-delay} and"
echo "{split-nocl, default} stay at ~gap+1 ms; {merged, default} at ~1 ms (no gap in merged)."

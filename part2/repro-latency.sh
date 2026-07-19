#!/usr/bin/env bash
# End-to-end latency impact (part 2): the split END_STREAM produced by Spring >= 7.0.5 on
# Jetty + HTTP/2 (see repro-frames.sh) costs ~200 ms per response behind haproxy.
#
# Mechanism: haproxy (h1 towards the client, h2c towards the app - a standard kubernetes
# haproxy-ingress data path) sends the last body bytes with MSG_MORE because the backend
# stream has not delivered END_STREAM yet; the kernel corks the final partial TCP segment.
# The trailing empty DATA(0, END_STREAM) produces no forwardable bytes for a
# Content-Length-framed h1 response, so nothing uncorks the socket until the ~200 ms kernel
# cork timeout (tcp(7) TCP_CORK). A sequential keep-alive client therefore sees ~208 ms per
# request. Controls built in:
#   - direct route (no haproxy): fast on every version - the defect alone adds no latency,
#   - "option http-no-delay" frontend (disables MSG_MORE): fast on every version,
#   - no-Content-Length shape: fast on every version (chunked; the terminal 0-chunk is real
#     bytes sent without MSG_MORE and flushes the socket; also both Spring versions frame it
#     identically, as neither can call setContentLengthLong without a Content-Length).
#
# Requires docker (HAPROXY_IMAGE, default haproxy:2.8), curl, a JDK. Jetty only. Example:
#   VERSIONS="7.0.4 7.0.5" ./repro-latency.sh
set -euo pipefail

cd "$(dirname "$0")/"

VERSIONS="${VERSIONS:-7.0.4 7.0.5}"
BYTES="${BYTES:-4096}"
ASYNC="${ASYNC:-true}"
REQUESTS="${REQUESTS:-20}"
APP_PORT="${APP_PORT:-8080}"
PROXY_PORT="${PROXY_PORT:-9090}"       # haproxy defaults (MSG_MORE active)
PROXY_ND_PORT="${PROXY_ND_PORT:-9091}" # haproxy with "option http-no-delay"
HAPROXY_IMAGE="${HAPROXY_IMAGE:-haproxy:3.5-dev}"
JAR="target/issue-0.0.1-SNAPSHOT.jar"
RESULTS="$(mktemp)"
HAPROXY_DIR="$(mktemp -d)"
HAPROXY_NAME="issue-part2-latency"

server_pid=""
cleanup() {
  docker rm -f "$HAPROXY_NAME" >/dev/null 2>&1 || true
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
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

# Mirrors the ingress data path: HTTP/1.1 towards the client, h2c towards Jetty.
frontend fe_default
    bind 0.0.0.0:${PROXY_PORT}
    default_backend be_default

backend be_default
    server app 127.0.0.1:${APP_PORT} proto h2

# Control: identical, plus the documented remedy for MSG_MORE-induced latency.
frontend fe_nodelay
    bind 0.0.0.0:${PROXY_ND_PORT}
    option http-no-delay
    default_backend be_nodelay

backend be_nodelay
    option http-no-delay
    server app 127.0.0.1:${APP_PORT} proto h2
EOF

wait_for_up() {
  local url="$1" tries=60
  while [ "$tries" -gt 0 ]; do
    curl -fsS -o /dev/null "$url" 2>/dev/null && return 0
    tries=$((tries - 1))
    sleep 1
  done
  return 1
}

shape_query() {
  case "$1" in
  cl) echo "bytes=${BYTES}&async=${ASYNC}&contentLength=true&json=true" ;;
  nocl) echo "bytes=${BYTES}&async=${ASYNC}&contentLength=false&json=true" ;;
  *)
    echo "unknown shape: $1" >&2
    return 1
    ;;
  esac
}

# Sequential closed-loop client: one keep-alive HTTP/1.1 connection, REQUESTS transfers.
# Prints "<time_starttransfer> <time_total>" per transfer (seconds).
measure() {
  local url="$1"
  local args=()
  for _ in $(seq 1 "$REQUESTS"); do
    args+=(-o /dev/null -w '%{time_starttransfer} %{time_total}\n' "$url")
  done
  curl -s --http1.1 "${args[@]}"
}

# Reads measure() output, prints "<median_ms> <p90_ms>" of time_total.
stats() {
  LC_ALL=C sort -k2 -n | LC_ALL=C awk '
    { total[NR] = $2 * 1000 }
    END {
      if (NR == 0) { print "NA NA"; exit }
      median = total[int((NR + 1) / 2)]
      p90 = total[int(NR * 0.9) > 0 ? int(NR * 0.9) : 1]
      printf "%.1f %.1f\n", median, p90
    }'
}

row() {
  local version="$1" route="$2" shape="$3" base="$4"
  local url out med p90
  url="${base}/endstream?$(shape_query "$shape")"
  out="$(measure "$url" | stats)"
  med="${out%% *}"
  p90="${out##* }"
  printf '%s\t%s\t%s\t%s\t%s\n' "$version" "$route" "$shape" "$med" "$p90" >>"$RESULTS"
  echo "  $route $shape: median ${med} ms, p90 ${p90} ms"
}

for entry in $VERSIONS; do
  version="${entry%%+*}"
  profiles="jetty${entry#"$version"}"
  profiles="${profiles//+/,}"

  echo "### building: jetty version=$version profiles=$profiles ###"
  # shellcheck disable=SC2086  # MVN_FLAGS is intentionally word-split (e.g. "-o")
  if ! ../mvnw ${MVN_FLAGS:-} -q clean package -DskipTests -P"$profiles" -Dspring-framework.version="$version" >/dev/null 2>&1; then
    echo "  BUILD FAILED - skipping"
    continue
  fi

  java -jar "$JAR" --server.port="$APP_PORT" >"latency-${entry}.log" 2>&1 &
  server_pid=$!
  if ! wait_for_up "http://127.0.0.1:${APP_PORT}/endstream?bytes=16"; then
    echo "  SERVER DID NOT START - see latency-${entry}.log"
    kill "$server_pid" 2>/dev/null || true
    continue
  fi

  docker rm -f "$HAPROXY_NAME" >/dev/null 2>&1 || true
  docker run -d --rm --name "$HAPROXY_NAME" --network host \
    -v "$HAPROXY_DIR/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro" \
    "$HAPROXY_IMAGE" >/dev/null
  if ! wait_for_up "http://127.0.0.1:${PROXY_PORT}/endstream?bytes=16"; then
    echo "  HAPROXY DID NOT START"
    docker logs "$HAPROXY_NAME" 2>&1 | tail -5 || true
    kill "$server_pid" 2>/dev/null || true
    continue
  fi

  for shape in cl nocl; do
    row "$entry" "direct" "$shape" "http://127.0.0.1:${APP_PORT}"
    row "$entry" "haproxy" "$shape" "http://127.0.0.1:${PROXY_PORT}"
    row "$entry" "haproxy+http-no-delay" "$shape" "http://127.0.0.1:${PROXY_ND_PORT}"
  done

  docker rm -f "$HAPROXY_NAME" >/dev/null 2>&1 || true
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  server_pid=""
  sleep 1
done

echo
echo "===== SUMMARY (sequential HTTP/1.1 keep-alive client, ${REQUESTS} requests, bytes=$BYTES async=$ASYNC, image=$HAPROXY_IMAGE) ====="
printf '%-44s %-24s %-7s %-10s %-10s\n' VERSION ROUTE SHAPE MEDIAN_MS P90_MS
printf '%-44s %-24s %-7s %-10s %-10s\n' ------- ----- ----- --------- ------
awk -F'\t' '{ printf "%-44s %-24s %-7s %-10s %-10s\n", $1, $2, $3, $4, $5 }' "$RESULTS"

echo
echo "Expected: only {>= 7.0.5, haproxy route, cl shape} is slow (~208 ms); everything else"
echo "is fast. http-no-delay and the no-CL shape prove the MSG_MORE/Content-Length mechanism."

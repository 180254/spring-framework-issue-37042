#!/usr/bin/env bash
# Frame-level proof (part 2): since Spring Framework 7.0.5, ServletServerHttpResponse never
# calls HttpServletResponse#setContentLengthLong, so on Jetty + HTTP/2 a response with a known
# Content-Length is no longer terminated on its final body write:
#
#   good (<= 7.0.4, or the shadow revert):  HEADERS, DATA(N, END_STREAM)          - one flush
#   bad  (>= 7.0.5):                        HEADERS, DATA(N), DATA(0, END_STREAM) - split
#
# Tomcat is immune (setHeader("Content-Length") is special-cased into setContentLength, and
# its h2 output computes END_OF_STREAM at flush time).
#
# Builds the reproducer app from the repository root for each {container} x {version token},
# fetches /endstream over h2c with nghttp -v, prints and classifies the received frames.
# Version tokens support "+profile" suffixes, e.g. "7.0.8+shadowServletServerHttpResponse".
#
# Requires nghttp, curl, JDK 25+, and the bundled Maven wrapper. Example:
#   CONTAINERS=jetty VERSIONS="7.0.4 7.0.5" ./repro-frames.sh
set -euo pipefail

SCRIPT_DIR="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)"
die() { echo "dependency check failed: $*" >&2; exit 127; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' was not found in PATH"; }

for tool in awk curl grep java javac mktemp nghttp rm sleep; do
  need "$tool"
done
MAVEN="$SCRIPT_DIR/../mvnw"
[ -x "$MAVEN" ] || die "Maven wrapper '$MAVEN' is missing or not executable"
java_version="$(java -version 2>&1)"
if [[ ! "$java_version" =~ version\ \"([0-9]+) ]] || ((BASH_REMATCH[1] < 25)); then die "JDK 25+ is required"; fi
javac_version="$(javac -version 2>&1)"
if [[ ! "$javac_version" =~ ^javac\ ([0-9]+) ]] || ((BASH_REMATCH[1] < 25)); then die "JDK 25+ is required"; fi
"$MAVEN" --version >/dev/null 2>&1 || die "Maven could not run"

cd "$SCRIPT_DIR"

CONTAINERS="${CONTAINERS:-jetty tomcat}"
VERSIONS="${VERSIONS:-7.0.4 7.0.5 7.0.8 7.0.8+shadowServletServerHttpResponse}"
BYTES="${BYTES:-4096}"
ASYNC="${ASYNC:-true}"
PORT="${PORT:-8080}"
JAR="target/issue-0.0.1-SNAPSHOT.jar"
URL="http://127.0.0.1:${PORT}/endstream?bytes=${BYTES}&async=${ASYNC}&contentLength=true&json=true"
RESULTS="$(mktemp)"

server_pid=""
cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
  fi
  rm -f "$RESULTS"
}
trap cleanup EXIT

wait_for_up() {
  local tries=60
  while [ "$tries" -gt 0 ]; do
    curl -fsS -o /dev/null "$URL" 2>/dev/null && return 0
    tries=$((tries - 1))
    sleep 1
  done
  return 1
}

# Fetch once with nghttp and echo the response frame lines (HEADERS/DATA with timestamps).
frame_trace() {
  # -n discards the response body (zero bytes would make grep treat stdout as binary)
  nghttp -nv "$URL" 2>/dev/null | grep -aE 'recv (HEADERS|DATA) frame' || true
}

# "single-flush" when the last DATA carries the body; "split-END_STREAM" when a zero-length
# DATA frame terminates the stream.
classify() {
  local trace="$1"
  local data_frames empty_last
  data_frames="$(grep -cE 'recv DATA frame' <<<"$trace" || true)"
  empty_last="$(grep -cE 'recv DATA frame <length=0' <<<"$trace" || true)"
  if [ "$data_frames" -eq 0 ]; then
    echo "no-data"
  elif [ "$empty_last" -gt 0 ]; then
    echo "split-END_STREAM"
  else
    echo "single-flush"
  fi
}

for container in $CONTAINERS; do
  for entry in $VERSIONS; do
    version="${entry%%+*}"
    profiles="${container}${entry#"$version"}"
    profiles="${profiles//+/,}"

    echo "### building: container=$container version=$version profiles=$profiles ###"
    # shellcheck disable=SC2086  # MVN_FLAGS is intentionally word-split (e.g. "-o")
    if ! "$MAVEN" ${MVN_FLAGS:-} -q clean package -DskipTests -P"$profiles" -Dspring-framework.version="$version" >/dev/null 2>&1; then
      echo "  BUILD FAILED - skipping"
      printf '%s\t%s\t%s\n' "$container" "$entry" "build-failed" >>"$RESULTS"
      continue
    fi

    java -jar "$JAR" --server.port="$PORT" >"frames-${container}-${entry}.log" 2>&1 &
    server_pid=$!
    if wait_for_up; then
      trace="$(frame_trace)"
      verdict="$(classify "$trace")"
      echo "  frames received by nghttp:"
      while IFS= read -r line; do printf '    %s\n' "$line"; done <<<"$trace"
      echo "  => $verdict"
      printf '%s\t%s\t%s\n' "$container" "$entry" "$verdict" >>"$RESULTS"
    else
      echo "  SERVER DID NOT START - see frames-${container}-${entry}.log"
      printf '%s\t%s\t%s\n' "$container" "$entry" "no-start" >>"$RESULTS"
    fi
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=""
    sleep 2
  done
done

echo
echo "===== SUMMARY (bytes=$BYTES async=$ASYNC, response with Content-Length) ====="
printf '%-9s %-52s %s\n' CONTAINER VERSION VERDICT
printf '%-9s %-52s %s\n' --------- ------- -------
awk -F'\t' '{ printf "%-9s %-52s %s\n", $1, $2, $3 }' "$RESULTS"

echo
echo "Expected: jetty <= 7.0.4 and jetty +shadowServletServerHttpResponse -> single-flush;"
echo "jetty >= 7.0.5 -> split-END_STREAM; tomcat -> single-flush on every version."

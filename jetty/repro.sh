#!/usr/bin/env bash
# Runs the plain-servlet reproducer on all containers (maven profiles: jetty-ee11,
# jetty-ee10, tomcat) and prints the HTTP/2 frames received for the two endpoints:
#   /setcontentlength - Content-Length via HttpServletResponse#setContentLengthLong
#   /setheader        - the same value via HttpServletResponse#setHeader
#
# Expected:
#   jetty-ee11 and jetty-ee10:
#     /setcontentlength -> HEADERS + DATA(4096, END_STREAM)              (single-flush)
#     /setheader        -> HEADERS + DATA(4096) + DATA(0, END_STREAM)    (split-END_STREAM)
#   tomcat:
#     both endpoints    -> HEADERS + DATA(4096, END_STREAM)              (single-flush)
#
# Requires nghttp, curl, a JDK, maven (uses ../mvnw when available); Linux/macOS only
# (the classpath is joined with ':'). Server output goes to server-<container>.log
# (kept for inspection). Example:
#   ./repro.sh
set -euo pipefail

cd "$(dirname "$0")"

CONTAINERS="${CONTAINERS:-jetty-ee11 jetty-ee10 tomcat}"
PORT="${PORT:-8080}"

# Integer.getInteger in the mains silently falls back to 8080 on malformed values and
# parses leading-zero values as octal, so the shell and the server would disagree about
# the port; validate up front instead.
case "$PORT" in
'' | *[!0-9]* | 0*)
  echo "invalid PORT: '$PORT' (must be a decimal port number without leading zeros)" >&2
  exit 1
  ;;
esac
if [ "$PORT" -gt 65535 ]; then
  echo "invalid PORT: '$PORT' (must be <= 65535)" >&2
  exit 1
fi

RESULTS="$(mktemp)"

MVN="../mvnw"
if [ ! -x "$MVN" ]; then
  MVN="mvn"
fi

server_pid=""
cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
  fi
  rm -f "$RESULTS"
}
trap cleanup EXIT

main_class() {
  case "$1" in
  jetty-ee11) echo "JettyEE11Main" ;;
  jetty-ee10) echo "JettyEE10Main" ;;
  tomcat) echo "TomcatMain" ;;
  *)
    echo "unknown container: $1" >&2
    return 1
    ;;
  esac
}

# "single-flush" when a single body DATA frame carries END_STREAM; "split-END_STREAM"
# when an empty DATA(END_STREAM) frame terminates the stream separately; "multi-DATA"
# when the body spans several frames and the last non-empty one carries END_STREAM.
# Flags are matched with 0x0[19] so END_STREAM is also recognized on PADDED (0x08) frames.
classify() {
  local trace="$1"
  local data_frames empty_end_stream end_stream
  data_frames="$(grep -cE 'recv DATA frame' <<<"$trace" || true)"
  empty_end_stream="$(grep -cE 'recv DATA frame <length=0, flags=0x0[19]' <<<"$trace" || true)"
  end_stream="$(grep -cE 'recv DATA frame <length=[0-9]+, flags=0x0[19]' <<<"$trace" || true)"
  if [ "$data_frames" -eq 0 ]; then
    echo "no-data"
  elif [ "$empty_end_stream" -gt 0 ] && [ "$data_frames" -gt 1 ]; then
    echo "split-END_STREAM"
  elif [ "$end_stream" -gt 0 ] && [ "$data_frames" -eq 1 ]; then
    echo "single-flush"
  elif [ "$end_stream" -gt 0 ]; then
    echo "multi-DATA"
  else
    echo "no-END_STREAM"
  fi
}

for container in $CONTAINERS; do
  echo "### container=$container ###"
  # Assigned on its own line so set -e still aborts on an unknown container; in argument
  # position the substitution's failure would be ignored. Resolved before the build so a
  # typo fails fast (maven only warns about an unknown profile id).
  main="$(main_class "$container")"

  # Any response here means a foreign listener occupies the port (the readiness probe
  # below could not tell it apart from our server, whose bind failure it would mask).
  if curl -sS -o /dev/null "http://127.0.0.1:${PORT}/" 2>/dev/null; then
    echo "PORT ${PORT} is already in use - stop the other listener first" >&2
    exit 1
  fi

  # shellcheck disable=SC2086  # MVN_FLAGS is intentionally word-split (e.g. "-o")
  "$MVN" ${MVN_FLAGS:-} -q -f pom.xml -P"$container" clean compile dependency:build-classpath \
    -Dmdep.outputFile=target/cp.txt

  java -Dport="$PORT" -cp "target/classes:$(cat target/cp.txt)" "$main" \
    >"server-${container}.log" 2>&1 &
  server_pid=$!

  tries=30
  until curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/setheader" 2>/dev/null; do
    if ! kill -0 "$server_pid" 2>/dev/null; then
      echo "SERVER PROCESS EXITED - see server-${container}.log" >&2
      exit 1
    fi
    tries=$((tries - 1))
    if [ "$tries" -le 0 ]; then
      echo "SERVER DID NOT START - see server-${container}.log" >&2
      exit 1
    fi
    sleep 1
  done

  for path in setcontentlength setheader; do
    echo "--- GET /${path} ---"
    # -n discards the response body (zero bytes would make grep treat stdout as binary)
    if ! nghttp_out="$(nghttp -nv "http://127.0.0.1:${PORT}/${path}")"; then
      echo "NGHTTP FAILED for /${path}" >&2
      exit 1
    fi
    # nghttp exits 0 even on connect/protocol failures, so the guard above alone is not
    # enough; also, a non-200 (an error page) would be classified and could fake the
    # expected verdict, so require the endpoint to have actually answered 200.
    if ! grep -q ':status: 200' <<<"$nghttp_out"; then
      echo "UNEXPECTED RESPONSE (no ':status: 200') for /${path} - see the nghttp trace" >&2
      exit 1
    fi
    trace="$(grep -aE 'recv (HEADERS|DATA) frame' <<<"$nghttp_out" || true)"
    if [ -n "$trace" ]; then
      while IFS= read -r line; do printf '  %s\n' "$line"; done <<<"$trace"
    fi
    verdict="$(classify "$trace")"
    echo "  => $verdict"
    printf '%s\t%s\t%s\n' "$container" "/$path" "$verdict" >>"$RESULTS"
  done

  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  server_pid=""
  sleep 1
done

echo
echo "===== SUMMARY ====="
printf '%-11s %-19s %s\n' CONTAINER ENDPOINT VERDICT
printf '%-11s %-19s %s\n' --------- -------- -------
awk -F'\t' '{ printf "%-11s %-19s %s\n", $1, $2, $3 }' "$RESULTS"

echo
echo "Expected: only the jetty-ee11 and jetty-ee10 /setheader rows are split-END_STREAM;"
echo "everything else is single-flush - Tomcat treats setHeader(\"Content-Length\") and"
echo "setContentLengthLong as equivalent, Jetty does not."

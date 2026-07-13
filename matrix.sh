#!/usr/bin/env bash
# Reproducer sweep for the Spring Framework 7.0.5 header-handling regression (gh-36334).
#
# Builds {container} x {framework version} and benchmarks each over HTTP/1.1 and HTTP/2, printing req/s and
# the server's CPU use. The regression only shows when the server is the bottleneck (CPU-saturated), so each
# server is pinned to SERVER_CPUS (2 cores) and the script warns when a run was not saturated.
#
# Per-request header work is set by RESPONSE_HEADER_COUNT / RESPONSE_HEADER_READS / REQUEST_HEADER_READS. The
# defaults (RESPONSE_HEADER_READS=50) reproduce production scale (~85% drop on Jetty h2); RESPONSE_HEADER_READS=0
# gives a fast ~1.2x isolation sweep. Reads lower throughput, so request counts auto-shrink when a read knob is on.
#
# A version token may carry Maven profiles as "+" suffixes: "7.0.8+shadowServletServerHttpResponse" reverts
# that class over 7.0.8; "+shadowServletServerHttpRequest" reverts the request side; combine to revert both.
#
# Requires h2load, a JDK, taskset, Linux. Example:
#   CONTAINERS=jetty VERSIONS="7.0.4 7.0.5 7.0.8+shadowServletServerHttpResponse" PROTOCOLS=h2 ./matrix.sh
set -euo pipefail

cd "$(dirname "$0")"

CONTAINERS="${CONTAINERS:-tomcat jetty}"
VERSIONS="${VERSIONS:-7.0.4 7.0.5 7.0.8 7.0.8+shadowServletServerHttpRequest 7.0.8+shadowServletServerHttpResponse 7.0.8+shadowServletServerHttpRequest,shadowServletServerHttpResponse}"
PROTOCOLS="${PROTOCOLS:-h1 h2}"
RESPONSE_HEADER_COUNT="${RESPONSE_HEADER_COUNT:-50}"
RESPONSE_HEADER_READS="${RESPONSE_HEADER_READS:-50}" # per-request RESPONSE-header reads (exercises ServletServerHttpResponse); 0 disables
REQUEST_HEADER_READS="${REQUEST_HEADER_READS:-50}"   # per-request REQUEST-header reads (exercises ServletServerHttpRequest); 0 disables
REQUEST_HEADER_COUNT="${REQUEST_HEADER_COUNT:-50}"   # request headers the client sends (only relevant when REQUEST_HEADER_READS>0)
SERVER_CPUS="${SERVER_CPUS:-0-1}"
CLIENT_CPUS="${CLIENT_CPUS:-2-9}"
# Reads tank throughput (the regressed build can run at ~100 req/s), so default to far fewer requests when
# either read knob is on - otherwise a fixed large count would take many minutes per run. Still overridable.
if [ "$RESPONSE_HEADER_READS" -gt 0 ] || [ "$REQUEST_HEADER_READS" -gt 0 ]; then
  WARMUP_N="${WARMUP_N:-4000}"
  MEASURE_N="${MEASURE_N:-8000}"
else
  WARMUP_N="${WARMUP_N:-100000}"
  MEASURE_N="${MEASURE_N:-300000}"
fi
PORT="${PORT:-8080}"
JAR="target/issue-0.0.1-SNAPSHOT.jar"
URL="http://127.0.0.1:${PORT}/repro?responseHeaderCount=${RESPONSE_HEADER_COUNT}&responseHeaderReads=${RESPONSE_HEADER_READS}&requestHeaderReads=${REQUEST_HEADER_READS}"
CLK_TCK="$(getconf CLK_TCK)"
RESULTS="$(mktemp)"

# Count logical CPUs in a taskset spec like "0-1", "0", "2-9,12".
count_cpus() {
  local spec="$1" total=0 part a b
  local -a parts
  IFS=',' read -ra parts <<<"$spec"
  for part in "${parts[@]}"; do
    if [[ "$part" == *-* ]]; then
      a="${part%%-*}"
      b="${part##*-}"
      total=$((total + b - a + 1))
    else
      total=$((total + 1))
    fi
  done
  echo "$total"
}

SERVER_CAP="$(count_cpus "$SERVER_CPUS")"
# h2load uses one thread per client core so the client can out-run a CPU-capped server.
CLIENT_THREADS="${CLIENT_THREADS:-$(count_cpus "$CLIENT_CPUS")}"
CONNS="${CONNS:-16}"
STREAMS="${STREAMS:-100}"

# When exercising request-header reads, have the client send REQUEST_HEADER_COUNT request headers (h2load -H,
# repeatable) so each read scans a non-trivial header set.
REQUEST_HEADER_FLAGS=()
if [ "$REQUEST_HEADER_READS" -gt 0 ]; then
  for i in $(seq 0 $((REQUEST_HEADER_COUNT - 1))); do
    REQUEST_HEADER_FLAGS+=(-H "X-Req-$i: value-$i")
  done
fi

# Process-wide CPU ticks (utime + stime) for a pid; echoes nothing and returns 1 if unavailable.
cpu_ticks() {
  local stat rest
  stat="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  rest="${stat#*) }" # drop "pid (comm) "; comm may contain spaces/parens
  # shellcheck disable=SC2086
  set -- $rest
  [ "$#" -ge 13 ] || return 1
  echo $((${12} + ${13})) # utime(14) + stime(15) -> positions 12,13 after the comm field
}

# PID of the process listening on a TCP port (ss, then fuser); empty if none found.
listener_pid() {
  local port="$1" p=""
  p="$(ss -ltnpH 2>/dev/null | grep -E "[:.]${port}([^0-9]|$)" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)"
  if [ -z "$p" ]; then
    p="$(fuser "${port}/tcp" 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$' | head -1)"
  fi
  echo "$p"
}

# Wait until nothing is listening on the port (our own server dying), up to ~15s; 1 if still busy.
wait_port_free() {
  local tries=15
  while curl -fsS -o /dev/null "$URL" 2>/dev/null; do
    tries=$((tries - 1))
    [ "$tries" -le 0 ] && return 1
    sleep 1
  done
  return 0
}

wait_for_up() {
  local tries=60
  while [ "$tries" -gt 0 ]; do
    curl -fsS -o /dev/null "$URL" 2>/dev/null && return 0
    tries=$((tries - 1))
    sleep 1
  done
  return 1
}

# Write one row per protocol with the same value (for build-failed / no-start outcomes).
emit_rows() {
  local value="$1" proto
  for proto in $PROTOCOLS; do
    printf '%s\t%s\t%s\t%s\t%s\n' "$container" "$entry" "$proto" "$value" "-" >>"$RESULTS"
  done
}

# Echo "<req/s>\t<server_cores>" for a protocol, measuring server CPU across the timed window.
# h1 -> HTTP/1.1 (--h1), h2 -> HTTP/2 cleartext (default). $1 proto, $2 server pid.
run_load() {
  local proto="$1" pid="$2"
  local flag=()
  [ "$proto" = "h1" ] && flag=(--h1)
  taskset -c "$CLIENT_CPUS" h2load "${flag[@]}" "${REQUEST_HEADER_FLAGS[@]}" -t "$CLIENT_THREADS" -c "$CONNS" -m "$STREAMS" -n "$WARMUP_N" "$URL" >/dev/null 2>&1 || true
  local t0 w0 rps t1 w1 cores
  t0="$(cpu_ticks "$pid" || true)"
  w0="$(date +%s.%N)"
  rps="$(taskset -c "$CLIENT_CPUS" h2load "${flag[@]}" "${REQUEST_HEADER_FLAGS[@]}" -t "$CLIENT_THREADS" -c "$CONNS" -m "$STREAMS" -n "$MEASURE_N" "$URL" 2>/dev/null |
    grep -oE '[0-9.]+ req/s' | grep -oE '^[0-9.]+' || echo "ERR")"
  t1="$(cpu_ticks "$pid" || true)"
  w1="$(date +%s.%N)"
  if [ -n "$t0" ] && [ -n "$t1" ]; then
    cores="$(LC_ALL=C awk -v dt="$((t1 - t0))" -v tck="$CLK_TCK" -v w0="$w0" -v w1="$w1" \
      'BEGIN { if (w1 > w0 && dt >= 0) printf "%.2f", (dt / tck) / (w1 - w0); else printf "NA" }')"
  else
    cores="NA" # server pid could not be measured (e.g. it exited, or lives under a different pid)
  fi
  printf '%s\t%s' "$rps" "$cores"
}

for container in $CONTAINERS; do
  for entry in $VERSIONS; do
    version="${entry%%+*}"                     # "7.0.8+shadowServletServerHttpResponse" -> "7.0.8"
    profiles="${container}${entry#"$version"}" # append any "+profile" suffix(es)
    profiles="${profiles//+/,}"                # "tomcat+shadowServletServerHttpResponse" -> "tomcat,shadowServletServerHttpResponse"

    echo "### building: container=$container version=$version profiles=$profiles ###"
    # shellcheck disable=SC2086  # MVN_FLAGS is intentionally word-split (e.g. "-o")
    if ! ./mvnw ${MVN_FLAGS:-} -q clean package -DskipTests -P"$profiles" -Dspring-framework.version="$version" >/dev/null 2>&1; then
      echo "  BUILD FAILED (version likely incompatible with Spring Boot 4.1.0) - skipping"
      emit_rows "build-failed"
      continue
    fi

    if ! wait_port_free; then
      echo "  ERROR: port $PORT is already in use by another process (pid $(listener_pid "$PORT")). Free it"
      echo "  (e.g. 'kill \$(fuser $PORT/tcp)') and re-run - otherwise we would measure that server, not ours."
      emit_rows "port-busy"
      continue
    fi

    taskset -c "$SERVER_CPUS" java -jar "$JAR" --server.port="$PORT" >"run-${container}-${entry}.log" 2>&1 &
    launch_pid=$!
    if wait_for_up; then
      # Measure the process actually listening on the port. taskset normally exec()s java (so this equals
      # launch_pid), but resolving the listener is robust to a forking taskset or an orphaned JVM.
      server_pid="$(listener_pid "$PORT")"
      [ -z "$server_pid" ] && server_pid="$launch_pid"
      for proto in $PROTOCOLS; do
        result="$(run_load "$proto" "$server_pid")"
        rps="${result%%$'\t'*}"
        cores="${result##*$'\t'}"
        printf '%s\t%s\t%s\t%s\t%s\n' "$container" "$entry" "$proto" "$rps" "$cores" >>"$RESULTS"
        echo "  $container $entry $proto -> $rps req/s (server $cores of $SERVER_CAP cores)"
      done
    else
      echo "  SERVER DID NOT START - see run-${container}-${entry}.log"
      server_pid=""
      emit_rows "no-start"
    fi
    for p in "$server_pid" "$launch_pid"; do
      if [ -n "$p" ]; then
        kill "$p" 2>/dev/null || true
      fi
    done
    wait "$launch_pid" 2>/dev/null || true
    sleep 2
  done
done

echo
echo "===== SUMMARY (req/s; responseHeaderCount=$RESPONSE_HEADER_COUNT responseHeaderReads=$RESPONSE_HEADER_READS requestHeaderReads=$REQUEST_HEADER_READS, server CPUs=$SERVER_CPUS) ====="
printf '%-9s %-72s %-8s %-10s %-8s\n' CONTAINER VERSION PROTO REQ/S CORES
printf '%-9s %-72s %-8s %-10s %-8s\n' --------- ---------------- ----- ----- -----
# Group by container, then protocol, then version (each in its input order), so every version for a
# given container+protocol is contiguous - makes the version-over-version trend easy to read down a column.
LC_ALL=C awk -F'\t' -v containers="$CONTAINERS" -v protocols="$PROTOCOLS" -v versions="$VERSIONS" '
  BEGIN { nc = split(containers, C, " "); np = split(protocols, P, " "); nv = split(versions, V, " ") }
  { row[$1 SUBSEP $3 SUBSEP $2] = $0 }
  END {
    for (i = 1; i <= nc; i++)
      for (j = 1; j <= np; j++)
        for (k = 1; k <= nv; k++) {
          key = C[i] SUBSEP P[j] SUBSEP V[k]
          if (key in row) { split(row[key], f, "\t"); printf "%-9s %-72s %-8s %-10s %-8s\n", f[1], f[2], f[3], f[4], f[5] }
        }
  }
' "$RESULTS"

# Saturation guard: an unsaturated (or unmeasured) server means the comparison is invalid.
sat_threshold="$(LC_ALL=C awk -v cap="$SERVER_CAP" 'BEGIN { printf "%.2f", cap * 0.85 }')"
unsaturated="$(LC_ALL=C awk -F'\t' -v thr="$sat_threshold" \
  '$5 ~ /^[0-9.]+$/ && ($5 + 0) < thr { printf "  %s %s %s: server used only %s of '"$SERVER_CAP"' cores\n",$1,$2,$3,$5 }' "$RESULTS")"
unmeasured="$(LC_ALL=C awk -F'\t' \
  '$5 == "NA" { printf "  %s %s %s: server CPU could not be measured (JVM exited, or lives under another pid)\n",$1,$2,$3 }' "$RESULTS")"
rm -f "$RESULTS"

echo
if [ -n "$unsaturated" ] || [ -n "$unmeasured" ]; then
  echo "!!! WARNING: these runs are NOT trustworthy - the server was not CPU-saturated (or not measured):"
  [ -n "$unsaturated" ] && echo "$unsaturated"
  [ -n "$unmeasured" ] && echo "$unmeasured"
  echo "  If unsaturated, the client (h2load) was the bottleneck, so throughput is capped independently of the"
  echo "  framework version and the table looks FLAT even though the regression is present. Fix by giving the"
  echo "  server fewer cores (e.g. SERVER_CPUS=0) and/or a stronger client (raise CONNS / CLIENT_CPUS), then"
  echo "  re-run until every row shows server cores ~= $SERVER_CAP. Only saturated rows are meaningful."
  echo
fi
echo "Read across each container: req/s should drop from 7.0.4 to 7.0.5 and stay down through 7.0.8,"
echo "then recover at 7.0.8+shadow*. Trust a row only when its CORES ~= $SERVER_CAP (server saturated);"
echo "see the WARNING above if any were not."

#!/bin/bash
# Offline tests for netatmoweather.sh. No Netatmo account is needed: curl is replaced
# by a stub that answers like the Netatmo API.
# Usage: tests/run_tests.sh      (needs bash, jq, coreutils)

set -u
set -o pipefail

repo_dir=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT

failed=0
passed=0
ok()   { passed=$((passed + 1)); echo "ok   - $*"; }
fail() { failed=$((failed + 1)); echo "FAIL - $*"; }
check() { local desc="$1"; shift; if "$@"; then ok "$desc"; else fail "$desc"; fi; }
not() { ! "$@"; }

# ---------------------------------------------------------------------------
# curl stub: reads the request from "-K -" (stdin), logs it and answers with the
# files in $MOCK/token.* and $MOCK/station.* (body, code; rc = curl exit code)
# ---------------------------------------------------------------------------
mkdir -p "$work/bin"
cat > "$work/bin/curl" <<'STUB'
#!/bin/bash
cfg=$(cat)
printf 'ARGV: %s\n' "$*" >> "$MOCK/argv.log"
if [[ "$cfg" == *oauth2/token* ]]; then kind=token; else kind=station; fi
n=$(( $(cat "$MOCK/$kind.count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$MOCK/$kind.count"
printf '%s\n---\n' "$cfg" >> "$MOCK/$kind.requests"
[ -f "$MOCK/$kind.sleep" ] && sleep "$(cat "$MOCK/$kind.sleep")"
# answers can differ per call: <kind>.<n>.body overrides <kind>.body
body="$MOCK/$kind.body"; [ -f "$MOCK/$kind.$n.body" ] && body="$MOCK/$kind.$n.body"
code="$MOCK/$kind.code"; [ -f "$MOCK/$kind.$n.code" ] && code="$MOCK/$kind.$n.code"
rc=$(cat "$MOCK/$kind.rc" 2>/dev/null || echo 0)
if [ "$rc" -ne 0 ]; then echo "curl: (6) Could not resolve host" >&2; exit "$rc"; fi
cat "$body"
printf '\n%s' "$(cat "$code" 2>/dev/null || echo 200)"
STUB
chmod +x "$work/bin/curl"

STATION_OK='{"status":"ok","body":{"devices":[{"_id":"70:ee:50:00:00:01","type":"NAMain","reachable":true,
 "dashboard_data":{"Temperature":21.4,"Humidity":45,"Pressure":1013.2,"CO2":512,"Noise":38},
 "modules":[
  {"type":"NAModule1","reachable":true,"dashboard_data":{"Temperature":12.3,"Humidity":80}},
  {"type":"NAModule3","reachable":true,"dashboard_data":{"Rain":0}},
  {"type":"NAModule2","reachable":true,"dashboard_data":{"WindStrength":5,"WindAngle":180}}]}]}}'
SCREEN_OK='Main Device Data:
Temperature: 21.4°C Humidity: 45% Pressure: 1013.2 mb CO2: 512 ppm Noise: 38 dB
Outdoor Module Data:
Out. Temp.: 12.3°C Humidity: 80%
Rain Module Data:
Rain: 0 mm
Wind Module Data:
Wind: 5 km/h from: 180°'
FILE_OK='Temperature: 21.4°C Humidity: 45% Pressure: 1013.2 mb CO2: 512 ppm Noise: 38 dB, Out. Temp.: 12.3°C Humidity: 80%, Rain: 0 mm  Wind: 5 km/h from: 180°'

# Fresh test case: script copy, config, empty mock directory
# Arguments: extra config lines
setup() {
    T="$work/case$((++case_no))"
    MOCK="$T/mock"
    mkdir -p "$T/app" "$MOCK"
    cp "$repo_dir/netatmoweather.sh" "$T/app/"
    cat > "$T/app/config.cfg" <<CFG
REFRESH_TOKEN_INITIAL="initial|refresh"
APP_ID="app123"
CLIENT_SECRET="s3cr3t\"with'quotes"
DEVICE_ID="70:ee:50:00:00:01"
TOKEN_STORE="$T/app/.tokenstore"
OUTPUT_FILE="$T/app/weatherinfo.txt"
CFG
    printf '%s\n' "$@" >> "$T/app/config.cfg"
    chmod 600 "$T/app/config.cfg"
    printf '%s' "$STATION_OK" > "$MOCK/station.body"
    printf '{"access_token":"new|access","refresh_token":"new|refresh","expires_in":10800,"scope":["read_station"]}' > "$MOCK/token.body"
    export MOCK
}
case_no=0

run() {
    OUT=$(PATH="$work/bin:$PATH" "$T/app/netatmoweather.sh" "$@" 2>"$T/stderr")
    RC=$?
    ERR=$(cat "$T/stderr")
}
# Run the script in a pseudo terminal with 55 rows, like a start by hand on the Pi.
# bash then sets LINES and COLUMNS after each external command (checkwinsize).
# stdout and stderr share the terminal, so they are split by their prefix.
HAVE_PTY=no
if command -v python3 >/dev/null 2>&1; then
    HAVE_PTY=yes
    cat > "$work/ptyrun.py" <<'PYEOF'
import fcntl, os, pty, struct, sys, termios
pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 55, 120, 0, 0))
    os.execvp(sys.argv[1], sys.argv[1:])
out = b""
while True:
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    out += data
_, status = os.waitpid(pid, 0)
sys.stdout.buffer.write(out.replace(b"\r\n", b"\n"))
sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status))
PYEOF
fi
run_tty() {
    local all
    all=$(PATH="$work/bin:$PATH" python3 "$work/ptyrun.py" "$T/app/netatmoweather.sh" </dev/null)
    RC=$?
    OUT=$(grep -vE '^(WARNING|ERROR):|netatmoweather\.sh: line' <<<"$all")
    ERR=$(grep -E '^(WARNING|ERROR):|netatmoweather\.sh: line' <<<"$all")
}
calls() { cat "$MOCK/$1.count" 2>/dev/null || echo 0; }
store_line() { sed -n "s/^$1: //p" "$T/app/.tokenstore"; }
valid_store() {
    printf 'Access Token: stored|access\nAccess Token Expires: %s\nRefresh Token: stored|refresh\n' "$1" > "$T/app/.tokenstore"
    chmod 600 "$T/app/.tokenstore"
}

# --- options -----------------------------------------------------------------
setup
run --version;  check "--version" [ "$RC" -eq 0 -a "$OUT" == "netatmoweather 1.4.6" ]
run --help;     check "--help exits 0" [ "$RC" -eq 0 ]
run --bogus;    check "unknown option exits 1" [ "$RC" -eq 1 ]

# --- first run: no token store ----------------------------------------------
setup
run
check "first run exits 0" [ "$RC" -eq 0 ]
check "first run: screen output unchanged" [ "$OUT" == "$SCREEN_OK" ]
check "first run: refresh with REFRESH_TOKEN_INITIAL" grep -q 'refresh_token=initial|refresh' "$MOCK/token.requests"
check "first run: new refresh token stored" [ "$(store_line 'Refresh Token')" == "new|refresh" ]
check "first run: token store mode 600" [ "$(stat -c %a "$T/app/.tokenstore")" == "600" ]
check "first run: no temporary token file left" [ -z "$(find "$T/app" -name '.tokenstore.*' ! -name '*.lock')" ]
check "secrets are not on the curl command line" not grep -qE 's3cr3t|refresh|access' "$MOCK/argv.log"
check "quotes in CLIENT_SECRET passed correctly" grep -qF "client_secret=s3cr3t\\\"with'quotes" "$MOCK/token.requests"
check "station request: GET with device_id parameter" grep -q '^data-urlencode = "device_id=70:ee:50:00:00:01"' "$MOCK/station.requests"
check "first run: nothing on stderr" [ -z "$ERR" ]

# --- valid token, file output -------------------------------------------------
setup 'OUTPUT_TYPE="file"'
valid_store $(( $(date +%s) + 3600 ))
(umask 022; run)
run
check "valid token: exits 0" [ "$RC" -eq 0 ]
check "valid token: no refresh" [ "$(calls token)" -eq 0 ]
check "valid token: bearer header from store" grep -q 'Authorization: Bearer stored|access' "$MOCK/station.requests"
check "file output unchanged, no line break at the end" [ "$(cat "$T/app/weatherinfo.txt"; echo x)" == "${FILE_OK}x" ]
check "file output: nothing on stdout" [ -z "$OUT" ]
check "file output: new file gets umask permissions (644)" [ "$(stat -c %a "$T/app/weatherinfo.txt")" == "644" ]
chmod 640 "$T/app/weatherinfo.txt"; run
check "file output: permissions of an existing file kept" [ "$(stat -c %a "$T/app/weatherinfo.txt")" == "640" ]
check "file output: no temporary file left" [ -z "$(find "$T/app" -name 'weatherinfo.txt.tmp.*')" ]
setup 'OUTPUT_TYPE="file"' 'OUTPUT_SEPARATOR=" | "'
valid_store $(( $(date +%s) + 3600 )); run
check "OUTPUT_SEPARATOR joins all modules" [ "$(cat "$T/app/weatherinfo.txt")" == 'Temperature: 21.4°C Humidity: 45% Pressure: 1013.2 mb CO2: 512 ppm Noise: 38 dB | Out. Temp.: 12.3°C Humidity: 80% | Rain: 0 mm | Wind: 5 km/h from: 180°' ]

# --- expired token: stored refresh token is used and rotated -------------------
setup
valid_store $(( $(date +%s) + 100 ))   # inside the 300 s safety margin
run
check "expired: exits 0" [ "$RC" -eq 0 ]
check "expired: refresh with the STORED refresh token" grep -q 'refresh_token=stored|refresh' "$MOCK/token.requests"
check "expired: exactly one refresh" [ "$(calls token)" -eq 1 ]
check "expired: rotated refresh token persisted" [ "$(store_line 'Refresh Token')" == "new|refresh" ]
check "expired: new access token used" grep -q 'Bearer new|access' "$MOCK/station.requests"
exp=$(store_line 'Access Token Expires'); now=$(date +%s)
check "expired: expiry = now + expires_in" [ "$exp" -ge $((now + 10790)) -a "$exp" -le $((now + 10800)) ]

# --- answer without refresh_token: keep the old one ---------------------------
setup
valid_store 1
printf '{"access_token":"new|access","expires_in":10800}' > "$MOCK/token.body"
run
check "no refresh_token in answer: old one kept" [ "$RC" -eq 0 -a "$(store_line 'Refresh Token')" == "stored|refresh" ]

# --- stored refresh token rejected: fallback to REFRESH_TOKEN_INITIAL ---------
setup
valid_store 1
printf '{"error":"invalid_grant"}' > "$MOCK/token.1.body"; echo 400 > "$MOCK/token.1.code"
run
check "fallback: exits 0" [ "$RC" -eq 0 ]
check "fallback: second refresh with REFRESH_TOKEN_INITIAL" [ "$(calls token)" -eq 2 ] && sed -n '/---/,$p' "$MOCK/token.requests" | grep -q 'refresh_token=initial|refresh'
check "fallback: reported on stderr" grep -q 'invalid_grant' <<<"$ERR"

# --- both refresh tokens rejected -------------------------------------------
setup 'OUTPUT_TYPE="file"'
valid_store 1
printf 'old weather' > "$T/app/weatherinfo.txt"
printf '{"error":"invalid_grant","error_description":"bad token"}' > "$MOCK/token.body"; echo 400 > "$MOCK/token.code"
before=$(cat "$T/app/.tokenstore")
run
check "both rejected: exit code 2" [ "$RC" -eq 2 ]
check "both rejected: token store unchanged" [ "$(cat "$T/app/.tokenstore")" == "$before" ]
check "both rejected: output file unchanged" [ "$(cat "$T/app/weatherinfo.txt")" == "old weather" ]
check "both rejected: no station request" [ "$(calls station)" -eq 0 ]

# --- access token rejected by the API: forced refresh and retry -------------
setup
valid_store $(( $(date +%s) + 3600 ))
printf '{"error":{"code":3,"message":"Access token expired"}}' > "$MOCK/station.1.body"; echo 403 > "$MOCK/station.1.code"
run
check "rejected access token: exits 0" [ "$RC" -eq 0 -a "$OUT" == "$SCREEN_OK" ]
check "rejected access token: one refresh, two station requests" [ "$(calls token)" -eq 1 -a "$(calls station)" -eq 2 ]

# --- no connection -------------------------------------------------------------
setup 'OUTPUT_TYPE="file"'
valid_store $(( $(date +%s) + 3600 ))
printf 'old weather' > "$T/app/weatherinfo.txt"
echo 6 > "$MOCK/station.rc"
run
check "no connection: exit code 3" [ "$RC" -eq 3 ]
check "no connection: output file unchanged" [ "$(cat "$T/app/weatherinfo.txt")" == "old weather" ]
setup
valid_store 1
echo 28 > "$MOCK/token.rc"
before=$(cat "$T/app/.tokenstore")
run
check "no connection during refresh: exit 2, no fallback, store unchanged" [ "$RC" -eq 2 -a "$(calls token)" -eq 1 -a "$(cat "$T/app/.tokenstore")" == "$before" ]

# --- unexpected answers --------------------------------------------------------
setup
valid_store 1
printf '<html>502 Bad Gateway</html>' > "$MOCK/token.body"; echo 502 > "$MOCK/token.code"
run
check "HTML answer on refresh: exit 2" [ "$RC" -eq 2 ]
setup
valid_store $(( $(date +%s) + 3600 ))
printf '<html>502</html>' > "$MOCK/station.body"; echo 502 > "$MOCK/station.code"
run
check "HTML answer on station data: exit 3" [ "$RC" -eq 3 ]

# --- token store directory not writable: refresh token is not spent -------------
setup 'TOKEN_STORE="'"$work"'/ro/.tokenstore"'
mkdir -p "$work/ro"; chmod 555 "$work/ro"
run
check "store not writable: exit code 1 (lock file)" [ "$RC" -eq 1 ]
check "store not writable: refresh token not spent" [ "$(calls token)" -eq 0 ]
chmod 755 "$work/ro"

# --- tokens issued but the store cannot be replaced ---------------------------
setup
valid_store 1
cat > "$work/bin/mv" <<'MV'
#!/bin/bash
case "${!#}" in */.tokenstore) exit 1 ;; esac
exec /bin/mv "$@"
MV
chmod +x "$work/bin/mv"
run
rm -f "$work/bin/mv"
check "store not replaceable: exit code 2" [ "$RC" -eq 2 ]
check "store not replaceable: REFRESH_TOKEN_INITIAL not spent as well" [ "$(calls token)" -eq 1 ]
kept=$(find "$T/app" -name '.tokenstore.*' ! -name '*.lock')
check "store not replaceable: new tokens kept in a 600 file" [ -n "$kept" ] && grep -q 'new|refresh' "$kept" && [ "$(stat -c %a "$kept")" == "600" ]

# --- interrupted during the refresh: no temporary token file left -------------
setup
valid_store 1
echo 2 > "$MOCK/token.sleep"
PATH="$work/bin:$PATH" "$T/app/netatmoweather.sh" >/dev/null 2>&1 &
pid=$!
sleep 0.5; kill -TERM "$pid"; wait "$pid"; RC=$?
check "SIGTERM: exit code 143" [ "$RC" -eq 143 ]
check "SIGTERM: temporary token file removed" [ -z "$(find "$T/app" -name '.tokenstore.*' ! -name '*.lock')" ]

# --- modules -----------------------------------------------------------------
setup 'RAIN_MODULE="disable"'
valid_store $(( $(date +%s) + 3600 ))
jq -c '.body.devices[0].modules |= map(select(.type != "NAModule2")) | .body.devices[0].modules[0].reachable = false' <<<"$STATION_OK" > "$MOCK/station.body"
run
check "modules: exit 0 with main module only" [ "$RC" -eq 0 -a "$OUT" == "$(head -n 2 <<<"$SCREEN_OK")" ]
check "modules: unreachable outdoor module reported" grep -q 'Outdoor Module Data skipped: the module is not reachable' <<<"$ERR"
check "modules: missing wind module reported" grep -q 'Wind Module Data skipped: the station has no module' <<<"$ERR"
check "modules: disabled rain module silent" not grep -q 'Rain' <<<"$ERR"
setup
valid_store $(( $(date +%s) + 3600 ))
jq -c '.body.devices[0].dashboard_data.CO2 = null' <<<"$STATION_OK" > "$MOCK/station.body"
run
check "missing value shown as n/a" grep -q 'CO2: n/a ppm' <<<"$OUT"

# --- module combinations: titles must always match their data -----------------
# Each case runs with a pipe (cron) and in a terminal (start by hand).
MAIN_L='Temperature: 21.4°C Humidity: 45% Pressure: 1013.2 mb CO2: 512 ppm Noise: 38 dB'
OUT_L='Out. Temp.: 12.3°C Humidity: 80%'
RAIN_L='Rain: 0 mm'
WIND_L='Wind: 5 km/h from: 180°'
# Arguments: name, jq filter for the station answer, expected screen output, expected file output
combo() {
    local name="$1" filter="$2" screen="$3" file="$4" runner
    for runner in run run_tty; do
        [ "$runner" == run_tty ] && [ "$HAVE_PTY" != yes ] && continue
        setup
        valid_store $(( $(date +%s) + 3600 ))
        jq -c "$filter" <<<"$STATION_OK" > "$MOCK/station.body"
        "$runner"
        check "$name ($runner): screen output" [ "$OUT" == "$screen" ]
        check "$name ($runner): exit 0, no crash" [ "$RC" -eq 0 ] && not grep -q 'unbound variable' <<<"$ERR"
        setup 'OUTPUT_TYPE="file"'
        valid_store $(( $(date +%s) + 3600 ))
        jq -c "$filter" <<<"$STATION_OK" > "$MOCK/station.body"
        "$runner"
        check "$name ($runner): file output" [ "$(cat "$T/app/weatherinfo.txt" 2>/dev/null)" == "$file" ]
    done
}
combo "rain and wind unreachable" \
    '.body.devices[0].modules |= map(if .type == "NAModule3" or .type == "NAModule2" then .reachable = false else . end)' \
    "$(printf 'Main Device Data:\n%s\nOutdoor Module Data:\n%s' "$MAIN_L" "$OUT_L")" \
    "$MAIN_L, $OUT_L"
combo "only rain unreachable" \
    '.body.devices[0].modules |= map(if .type == "NAModule3" then .reachable = false else . end)' \
    "$(printf 'Main Device Data:\n%s\nOutdoor Module Data:\n%s\nWind Module Data:\n%s' "$MAIN_L" "$OUT_L" "$WIND_L")" \
    "$MAIN_L, $OUT_L, $WIND_L"
combo "only outdoor unreachable" \
    '.body.devices[0].modules |= map(if .type == "NAModule1" then .reachable = false else . end)' \
    "$(printf 'Main Device Data:\n%s\nRain Module Data:\n%s\nWind Module Data:\n%s' "$MAIN_L" "$RAIN_L" "$WIND_L")" \
    "$MAIN_L, $RAIN_L  $WIND_L"
combo "all present" "." "$SCREEN_OK" "$FILE_OK"
combo "main only" '.body.devices[0].modules = []' \
    "$(printf 'Main Device Data:\n%s' "$MAIN_L")" "$MAIN_L"

# --- configuration checks -------------------------------------------------------
setup 'DEVICE_ID="xx:xx:xx:xx:xx:xx"'
run
check "invalid DEVICE_ID: exit 1 without API call" [ "$RC" -eq 1 -a "$(calls token)" -eq 0 ]
setup 'OUTPUT_TYPE="printer"'; run
check "invalid OUTPUT_TYPE: exit 1" [ "$RC" -eq 1 ]
setup 'APP_ID=""'; run
check "missing APP_ID: exit 1" [ "$RC" -eq 1 ]
setup
valid_store $(( $(date +%s) + 3600 ))
chmod 644 "$T/app/config.cfg"; run
check "config readable by others: warning, still exit 0" [ "$RC" -eq 0 ] && grep -q 'chmod 600' <<<"$ERR"
rm "$T/app/config.cfg"; run
check "missing config: exit 1" [ "$RC" -eq 1 ]

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]

#!/bin/bash

# This script fetches weather data from a Netatmo weather station using the Netatmo API.
# @Version 1.4.2 - 10.10.2026
# - 1.1   - Added support for writing output to a file
# - 1.2   - better handling for config file
# - 1.3   - Fixed API base URL (api.netatmo.net → api.netatmo.com), added error handling
# - 1.4.0 - Startup checks for dependencies and configuration, fixed .gitignore
# - 1.4.1 - Hardened token handling: atomic token store, lock against parallel runs,
#           expiry safety margin, secrets no longer visible in the process list
# - 1.4.2 - Station data is requested only once per run, output file is replaced
#           atomically and only on success, retry after a rejected access token
#
# Exit codes: 0 = ok, 1 = configuration or dependency problem, 2 = token problem,
#             3 = weather data could not be fetched

VERSION="1.4.2"

set -u
set -o pipefail

# Print an error message to stderr and exit with the given code
die() {
    local code="$1"
    shift
    echo "ERROR: $*" >&2
    exit "$code"
}

# Check required external tools
for tool in curl jq realpath; do
    command -v "$tool" >/dev/null 2>&1 || die 1 "Required tool '$tool' is not installed."
done

# Configuration file path
script_dir=$(dirname "$(realpath "$0")")
CONFIG_FILE="$script_dir/config.cfg"         # set path to config file

# Read security-relevant variables from config file
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
else
    die 1 "Configuration file $CONFIG_FILE not found."
fi

# Defaults for optional settings
OUTPUT_TYPE="${OUTPUT_TYPE:-screen}"
MAIN_MODULE="${MAIN_MODULE:-enable}"
OUTPUT_FILE="${OUTPUT_FILE:-}"

# Validate required settings
for var in REFRESH_TOKEN_INITIAL APP_ID CLIENT_SECRET DEVICE_ID TOKEN_STORE; do
    [ -n "${!var:-}" ] || die 1 "Setting $var is missing or empty in $CONFIG_FILE."
done

case "$OUTPUT_TYPE" in
    screen) ;;
    file)   [ -n "$OUTPUT_FILE" ] || die 1 "OUTPUT_TYPE is 'file' but OUTPUT_FILE is not set in $CONFIG_FILE." ;;
    *)      die 1 "OUTPUT_TYPE must be 'screen' or 'file' (found: '$OUTPUT_TYPE')." ;;
esac

case "$MAIN_MODULE" in
    enable|disable) ;;
    *) die 1 "MAIN_MODULE must be 'enable' or 'disable' (found: '$MAIN_MODULE')." ;;
esac

# ------------------------------------------------------------------------------------------------------------------------------------------- 


# Internal settings
TOKEN_URL="https://api.netatmo.com/oauth2/token"
API_URL="https://api.netatmo.com/api/getstationsdata"
TOKEN_MARGIN=300        # refresh the access token this many seconds before it expires
CURL_TIMEOUT=20         # maximum duration of a single HTTP request in seconds

# Follow symlinks so that replacing a file keeps the link intact
if [ -L "$TOKEN_STORE" ]; then
    TOKEN_STORE=$(realpath "$TOKEN_STORE")
fi
if [ -n "$OUTPUT_FILE" ] && [ -L "$OUTPUT_FILE" ]; then
    OUTPUT_FILE=$(realpath "$OUTPUT_FILE")
fi

# Remove a leftover temporary output file when the script ends
TMP_OUTPUT=""
trap '[ -n "$TMP_OUTPUT" ] && rm -f "$TMP_OUTPUT"' EXIT

ACCESS_TOKEN=""
ACCESS_TOKEN_EXPIRES=""
STORED_REFRESH_TOKEN=""

# Escape a value for use inside a double-quoted string of a curl config file
curl_quote() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "$value"
}

# Read the token store into ACCESS_TOKEN, ACCESS_TOKEN_EXPIRES and STORED_REFRESH_TOKEN
load_tokens() {
    ACCESS_TOKEN=""
    ACCESS_TOKEN_EXPIRES=""
    STORED_REFRESH_TOKEN=""
    [ -f "$TOKEN_STORE" ] || return 1
    ACCESS_TOKEN=$(sed -n 's/^Access Token: //p' "$TOKEN_STORE" | head -n 1)
    ACCESS_TOKEN_EXPIRES=$(sed -n 's/^Access Token Expires: //p' "$TOKEN_STORE" | head -n 1)
    STORED_REFRESH_TOKEN=$(sed -n 's/^Refresh Token: //p' "$TOKEN_STORE" | head -n 1)
    return 0
}

# Request new tokens with the given refresh token and store them.
# Return codes: 0 = ok, 1 = refresh rejected or store not writable, 2 = no usable answer from the server
update_tokens() {
    local refresh_token="$1"
    local tmp_store response curl_rc http_code body error error_desc
    local new_access_token new_refresh_token expires_in expiration

    # Netatmo invalidates the old refresh token as soon as it is used. Make sure the
    # new tokens can be stored BEFORE the old one is spent.
    if ! tmp_store=$(mktemp "${TOKEN_STORE}.XXXXXX" 2>/dev/null); then
        echo "Cannot write to the directory of the token store ($TOKEN_STORE)." >&2
        return 1
    fi

    # The request is passed on stdin so that the secrets do not show up in the process list
    response=$(curl -sS --max-time "$CURL_TIMEOUT" -w '\n%{http_code}' -K - <<EOF
url = "$TOKEN_URL"
data-urlencode = "grant_type=refresh_token"
data-urlencode = "refresh_token=$(curl_quote "$refresh_token")"
data-urlencode = "client_id=$(curl_quote "$APP_ID")"
data-urlencode = "client_secret=$(curl_quote "$CLIENT_SECRET")"
EOF
    )
    curl_rc=$?
    if [ "$curl_rc" -ne 0 ]; then
        rm -f "$tmp_store"
        echo "Token refresh failed: no connection to the Netatmo API (curl exit code $curl_rc)." >&2
        return 2
    fi

    http_code="${response##*$'\n'}"
    body="${response%$'\n'*}"

    # Check for errors in the response
    error=$(jq -r '.error // empty | if type == "string" then . else tojson end' <<<"$body" 2>/dev/null)
    if [ -n "$error" ]; then
        error_desc=$(jq -r '.error_description // "no description"' <<<"$body" 2>/dev/null)
        rm -f "$tmp_store"
        echo "Token refresh failed (HTTP $http_code): $error - $error_desc" >&2
        echo "Please check your credentials and refresh token." >&2
        return 1
    fi

    # Extract the new access token, refresh token, and expiration time from the response
    new_access_token=$(jq -r '.access_token // empty' <<<"$body" 2>/dev/null)
    new_refresh_token=$(jq -r '.refresh_token // empty' <<<"$body" 2>/dev/null)
    expires_in=$(jq -r '.expires_in // empty' <<<"$body" 2>/dev/null)

    # Validate that we got valid tokens
    if [ -z "$new_access_token" ]; then
        rm -f "$tmp_store"
        echo "Token refresh failed (HTTP $http_code): unexpected answer: ${body:0:200}" >&2
        return 2
    fi

    # From here on the server has issued new tokens, so they are stored in any case
    if [ -z "$new_refresh_token" ]; then
        new_refresh_token="$refresh_token"
    fi
    if ! [[ "$expires_in" =~ ^[0-9]+$ ]]; then
        echo "Warning: no valid expiration time received, the token is refreshed again on the next run." >&2
        expires_in=0
    fi
    expiration=$(( $(date +%s) + expires_in ))

    # Write the complete store to a temporary file and replace the old one in a single step
    printf 'Access Token: %s\nAccess Token Expires: %s\nRefresh Token: %s\n' \
        "$new_access_token" "$expiration" "$new_refresh_token" > "$tmp_store"
    chmod 600 "$tmp_store"
    if ! mv -f "$tmp_store" "$TOKEN_STORE"; then
        echo "Could not replace the token store $TOKEN_STORE. The new tokens are kept in $tmp_store." >&2
        return 1
    fi

    echo "Tokens have been updated successfully."
    return 0
}

# Renew the tokens with the stored refresh token. If the server rejects it, try the
# token from the config file (useful after generating a new one on dev.netatmo.com).
renew_tokens() {
    local rc
    if [ -n "$STORED_REFRESH_TOKEN" ]; then
        update_tokens "$STORED_REFRESH_TOKEN"
        rc=$?
        [ "$rc" -eq 0 ] && return 0
        # no fallback if the server could not be reached or both tokens are identical
        [ "$rc" -eq 1 ] || return 1
        [ "$STORED_REFRESH_TOKEN" != "$REFRESH_TOKEN_INITIAL" ] || return 1
        echo "Trying REFRESH_TOKEN_INITIAL from the config file..." >&2
    fi
    update_tokens "$REFRESH_TOKEN_INITIAL"
}

# Make sure ACCESS_TOKEN holds a token that is valid for at least TOKEN_MARGIN seconds.
# With the argument "force" the token is renewed in any case.
ensure_valid_token() {
    local force="${1:-}"
    local now
    now=$(date +%s)

    if [ ! -f "$TOKEN_STORE" ]; then
        echo "Token store file not found. Initializing with initial tokens..."
        update_tokens "$REFRESH_TOKEN_INITIAL" || return 1
    else
        load_tokens
        if [ -z "$ACCESS_TOKEN" ] || ! [[ "$ACCESS_TOKEN_EXPIRES" =~ ^[0-9]+$ ]]; then
            echo "Token store is incomplete or damaged. Requesting new tokens..." >&2
            renew_tokens || return 1
        elif [ "$force" == "force" ]; then
            echo "Renewing tokens..."
            renew_tokens || return 1
        elif [ "$now" -ge $((ACCESS_TOKEN_EXPIRES - TOKEN_MARGIN)) ]; then
            echo "Access token has expired. Updating tokens..."
            renew_tokens || return 1
        else
            echo "Access token is still valid."
            return 0
        fi
    fi

    # Always continue with what is actually stored
    load_tokens
    [ -n "$ACCESS_TOKEN" ]
}

STATION_DATA=""

# Request the data of the weather station and keep the answer in STATION_DATA.
# Return codes: 0 = ok, 1 = error, 3 = access token rejected by the API
request_station_data() {
    local response curl_rc http_code body error_code error_msg status

    STATION_DATA=""
    response=$(curl -sS --max-time "$CURL_TIMEOUT" --retry 2 -w '\n%{http_code}' -K - <<EOF
url = "$API_URL?device_id=$(curl_quote "$DEVICE_ID")"
header = "Authorization: Bearer $(curl_quote "$ACCESS_TOKEN")"
EOF
    )
    curl_rc=$?
    if [ "$curl_rc" -ne 0 ]; then
        echo "No connection to the Netatmo API (curl exit code $curl_rc)." >&2
        return 1
    fi

    http_code="${response##*$'\n'}"
    body="${response%$'\n'*}"

    # Check for API errors
    error_code=$(jq -r '.error.code? // empty' <<<"$body" 2>/dev/null)
    if [ -n "$error_code" ]; then
        error_msg=$(jq -r '.error.message? // "Unknown error"' <<<"$body" 2>/dev/null)
        echo "API Error (HTTP $http_code, code $error_code): $error_msg" >&2
        # 2 = invalid access token, 3 = access token expired
        if [ "$error_code" == "2" ] || [ "$error_code" == "3" ]; then
            return 3
        fi
        return 1
    fi

    # Extract status from response
    status=$(jq -r '.status? // empty' <<<"$body" 2>/dev/null)
    if [ "$status" != "ok" ]; then
        echo "API returned an unexpected answer (HTTP $http_code): ${body:0:200}" >&2
        return 1
    fi

    STATION_DATA="$body"
    return 0
}

# Fetch the station data. If the API rejects the access token, renew it and try once more.
fetch_station_data() {
    local rc
    request_station_data
    rc=$?
    if [ "$rc" -eq 3 ]; then
        ensure_valid_token force || return 2
        request_station_data
        rc=$?
    fi
    [ "$rc" -eq 0 ]
}

# Print the text for one module type ("NAMain", "NAModule1", ...) from STATION_DATA.
# Prints nothing if the station has no such module.
module_line() {
    local module_type="$1"
    jq -r --arg t "$module_type" '
        .body.devices[0]
        | first(
            if $t == "NAMain"
            then (if .type == "NAMain" then . else empty end)
            else (.modules[]? | select(.type == $t))
            end
          )
        | .dashboard_data
        | if   $t == "NAMain"    then "Temperature: \(.Temperature)°C Humidity: \(.Humidity)% Pressure: \(.Pressure) mb CO2: \(.CO2) ppm Noise: \(.Noise) dB"
          elif $t == "NAModule1" then "Out. Temp.: \(.Temperature)°C Humidity: \(.Humidity)%"
          elif $t == "NAModule3" then "Rain: \(.Rain) mm"
          elif $t == "NAModule2" then "Wind: \(.WindStrength) km/h from: \(.WindAngle)°"
          else empty
          end
    ' <<<"$STATION_DATA" 2>/dev/null
}

# Replace OUTPUT_FILE with the given text in a single step, so that readers never see
# an empty or half written file. The permissions of an existing file are kept.
write_output_file() {
    local content="$1"

    TMP_OUTPUT="${OUTPUT_FILE}.tmp.$$"
    if ( printf '%s' "$content" > "$TMP_OUTPUT" ) 2>/dev/null; then
        if [ -f "$OUTPUT_FILE" ]; then
            chmod --reference="$OUTPUT_FILE" "$TMP_OUTPUT" 2>/dev/null
        fi
        if mv -f "$TMP_OUTPUT" "$OUTPUT_FILE" 2>/dev/null; then
            TMP_OUTPUT=""
            return 0
        fi
    fi
    rm -f "$TMP_OUTPUT" 2>/dev/null
    TMP_OUTPUT=""

    # Fallback if the directory is not writable: overwrite the file in place
    printf '%s' "$content" > "$OUTPUT_FILE"
}

FILE_CONTENT=""
DATA_FOUND="no"

# Add the data of one module to the output.
# Arguments: title for screen output, module type, separator appended in file output
process_module() {
    local title="$1"
    local module_type="$2"
    local separator="$3"
    local line

    line=$(module_line "$module_type")

    if [ "$OUTPUT_TYPE" != "file" ]; then
        echo "$title"
    fi
    if [ -z "$line" ]; then
        echo "No data available for module type: $module_type"
        return 0
    fi

    DATA_FOUND="yes"
    if [ "$OUTPUT_TYPE" == "file" ]; then
        FILE_CONTENT+="${line}${separator}"
    else
        echo "$line"
    fi
}

# Allow only one instance at a time: two parallel refreshes would invalidate each other's tokens
if command -v flock >/dev/null 2>&1; then
    if ! { exec 9>"${TOKEN_STORE}.lock"; } 2>/dev/null; then
        die 1 "Cannot create lock file ${TOKEN_STORE}.lock."
    fi
    flock -w 60 9 || die 1 "Another instance is still running (lock ${TOKEN_STORE}.lock)."
fi

# Load the access token and renew it if necessary
ensure_valid_token || die 2 "No valid access token available."

# Fetch the data of all modules with a single API call
fetch_station_data
case $? in
    0) ;;
    2) die 2 "No valid access token available." ;;
    *) die 3 "Could not fetch weather data. Existing output is left unchanged." ;;
esac

# Process main device data if enabled
if [ "$MAIN_MODULE" == "enable" ]; then
    process_module "Main Device Data:" "NAMain" ""
fi

# Outdoor, rain and wind module
process_module "Outdoor Module Data:" "NAModule1" ", "
process_module "Rain Module Data:" "NAModule3" "  "
process_module "Wind Module Data:" "NAModule2" ""

if [ "$DATA_FOUND" != "yes" ]; then
    die 3 "The station returned no data for any module. Please check DEVICE_ID."
fi

if [ "$OUTPUT_TYPE" == "file" ]; then
    echo "Writing weather data to $OUTPUT_FILE"
    write_output_file "$FILE_CONTENT" || die 1 "Could not write $OUTPUT_FILE."
fi

exit 0

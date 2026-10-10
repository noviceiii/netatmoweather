#!/bin/bash

# This script fetches weather data from a Netatmo weather station using the Netatmo API.
# @Version 1.4.1 - 10.10.2026
# - 1.1   - Added support for writing output to a file
# - 1.2   - better handling for config file
# - 1.3   - Fixed API base URL (api.netatmo.net → api.netatmo.com), added error handling
# - 1.4.0 - Startup checks for dependencies and configuration, fixed .gitignore
# - 1.4.1 - Hardened token handling: atomic token store, lock against parallel runs,
#           expiry safety margin, secrets no longer visible in the process list
#
# Exit codes: 0 = ok, 1 = configuration or dependency problem, 2 = token problem

VERSION="1.4.1"

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
TOKEN_MARGIN=300        # refresh the access token this many seconds before it expires
CURL_TIMEOUT=20         # maximum duration of a single HTTP request in seconds

# Follow a symlinked token store so that replacing the file keeps the link intact
if [ -L "$TOKEN_STORE" ]; then
    TOKEN_STORE=$(realpath "$TOKEN_STORE")
fi

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

# Function to fetch weather data from Netatmo API and display it
fetch_weather_data() {
    local module_type="$1"
    local data_fields="$2"
    
    # Make API call and capture full response
    local full_response=$(curl -s -X GET -H "Authorization: Bearer $ACCESS_TOKEN" "https://api.netatmo.com/api/getstationsdata?device_id=$DEVICE_ID")
    
    # Check for API errors
    local error_code=$(echo "$full_response" | jq -r '.error.code // empty')
    if [ -n "$error_code" ]; then
        local error_msg=$(echo "$full_response" | jq -r '.error.message // "Unknown error"')
        echo "API Error (code $error_code): $error_msg" >&2
        return 1
    fi
    
    # Extract status from response
    local status=$(echo "$full_response" | jq -r '.status // empty')
    if [ "$status" != "ok" ]; then
        echo "API returned non-OK status: $status" >&2
        echo "Response: $full_response" >&2
        return 1
    fi
    
    # Parse data based on module type
    local response=$(echo "$full_response" | jq -r ".body.devices[0] | if .type == \"NAMain\" and \"$module_type\" == \"main\" then .dashboard_data | $data_fields else (if .modules then .modules[] | select(.type == \"$module_type\") | .dashboard_data | $data_fields else empty end) end")

    if [ -n "$response" ]; then
        # Remove line breaks to make all data on one line
        response=$(echo "$response" | tr -d '\n')
        if [ "$OUTPUT_TYPE" == "file" ]; then
            echo -n "$response" >> "$OUTPUT_FILE"
        else
            echo "$response"
        fi
    else
        echo "No data available for module type: $module_type"
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

# Fetch and display weather data
if [ "$OUTPUT_TYPE" == "file" ]; then
    # Clear the file if it exists
    > "$OUTPUT_FILE"
    echo "Writing weather data to $OUTPUT_FILE"
fi

# Process main device data if enabled
if [ "$MAIN_MODULE" == "enable" ]; then
    if [ "$OUTPUT_TYPE" != "file" ]; then
        echo "Main Device Data:"
    fi
    fetch_weather_data "main" '"
Temperature: \(.Temperature)°C Humidity: \(.Humidity)% Pressure: \(.Pressure) mb CO2: \(.CO2) ppm Noise: \(.Noise) dB
"'
fi

if [ "$OUTPUT_TYPE" != "file" ]; then
    echo "Outdoor Module Data:"
fi

# Fetch outdoor module data
fetch_weather_data "NAModule1" '"
Out. Temp.: \(.Temperature)°C Humidity: \(.Humidity)%, 
"'

if [ "$OUTPUT_TYPE" != "file" ]; then
    echo "Rain Module Data:"
fi

# Fetch rain module data
fetch_weather_data "NAModule3" '"
Rain: \(.Rain) mm  
"'

if [ "$OUTPUT_TYPE" != "file" ]; then
    echo "Wind Module Data:"
fi

# Fetch wind module data
fetch_weather_data "NAModule2" '"
Wind: \(.WindStrength) km/h from: \(.WindAngle)°
"'
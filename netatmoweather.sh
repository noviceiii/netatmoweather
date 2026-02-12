#!/bin/bash

# This script fetches weather data from a Netatmo weather station using the Netatmo API.
# @Version 1.3 - 12.02.2026
# - .1 - Added support for writing output to a file
# - .2 - better handling for config file
# - .3 - Fixed API base URL (api.netatmo.net → api.netatmo.com), added error handling

# Configuration file path
script_dir=$(dirname "$(realpath "$0")")
CONFIG_FILE="$script_dir/config.cfg"         # set path to config file

# Read security-relevant variables from config file
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Configuration file $CONFIG_FILE not found. Exiting."
    exit 1
fi

# ------------------------------------------------------------------------------------------------------------------------------------------- 


# Function to update tokens when the access token has expired
update_tokens() {
    local refresh_token="$1"
    
    # Execute a POST request to get new tokens
    response=$(curl -s -X POST \
      -H "Content-Type: application/x-www-form-urlencoded;charset=UTF-8" \
      -d "grant_type=refresh_token&refresh_token=$refresh_token&client_id=$APP_ID&client_secret=$CLIENT_SECRET" \
      "https://api.netatmo.com/oauth2/token")

    # Check for errors in the response
    local error=$(echo "$response" | jq -r '.error // empty')
    if [ -n "$error" ]; then
        local error_desc=$(echo "$response" | jq -r '.error_description // "Unknown error"')
        echo "Token refresh failed: $error - $error_desc" >&2
        echo "Please check your credentials and refresh token." >&2
        return 1
    fi

    # Extract the new access token, refresh token, and expiration time from the response
    NEW_ACCESS_TOKEN=$(echo "$response" | jq -r '.access_token')
    NEW_REFRESH_TOKEN=$(echo "$response" | jq -r '.refresh_token')
    EXPIRES_IN=$(echo "$response" | jq -r '.expires_in')

    # Validate that we got valid tokens
    if [ "$NEW_ACCESS_TOKEN" == "null" ] || [ -z "$NEW_ACCESS_TOKEN" ]; then
        echo "Failed to retrieve new access token. Response: $response" >&2
        return 1
    fi

    # Calculate the new expiration timestamp
    CURRENT_TIME=$(date +%s)
    EXPIRATION_TIMESTAMP=$((CURRENT_TIME + EXPIRES_IN))

    # Update the token information in the file
    echo "Access Token: $NEW_ACCESS_TOKEN" > "$TOKEN_STORE"
    echo "Access Token Expires: $EXPIRATION_TIMESTAMP" >> "$TOKEN_STORE"
    echo "Refresh Token: $NEW_REFRESH_TOKEN" >> "$TOKEN_STORE"
    echo "Refresh Token Expires: $EXPIRATION_TIMESTAMP" >> "$TOKEN_STORE"

    echo "Tokens have been updated successfully."
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

# Initialize token store file if it doesn't exist
if [ ! -f "$TOKEN_STORE" ]; then
    echo "Token store file not found. Initializing with initial tokens..."
    if ! update_tokens "$REFRESH_TOKEN_INITIAL"; then
        echo "Failed to initialize tokens. Please check your configuration." >&2
        exit 1
    fi
fi

# Load current token and expiration time
ACCESS_TOKEN=$(grep "Access Token:" "$TOKEN_STORE" | cut -d' ' -f3)
current_time=$(date +%s)
access_token_expires=$(grep "Access Token Expires:" "$TOKEN_STORE" | cut -d' ' -f4)
refresh_token=$(grep "Refresh Token:" "$TOKEN_STORE" | cut -d' ' -f3)

# Check if the access token has expired
if [ -z "$access_token_expires" ]; then
    echo "Invalid expiration time. Initializing with initial tokens..."
    if ! update_tokens "$REFRESH_TOKEN_INITIAL"; then
        echo "Failed to refresh tokens. Exiting." >&2
        exit 1
    fi
elif [ "$current_time" -ge "$access_token_expires" ]; then
    echo "Access token has expired. Updating tokens..."
    if ! update_tokens "$refresh_token"; then
        echo "Failed to refresh expired token. Exiting." >&2
        exit 1
    fi
    ACCESS_TOKEN=$(grep "Access Token:" "$TOKEN_STORE" | cut -d' ' -f3)  # Update ACCESS_TOKEN after refresh
else
    echo "Access token is still valid."
fi

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
#!/bin/bash

# Source the configuration file
source config.cfg

# Function to update tokens when the access token has expired
update_tokens() {
    local refresh_token="$1"
    
    # Execute a POST request to get new tokens
    response=$(curl -X POST \
      -H "Content-Type: application/x-www-form-urlencoded;charset=UTF-8" \
      -d "grant_type=refresh_token&refresh_token=$refresh_token&client_id=$APP_ID&client_secret=$CLIENT_SECRET" \
      "https://api.netatmo.com/oauth2/token")

    # Extract the new access token, refresh token, and expiration time from the response
    NEW_ACCESS_TOKEN=$(echo "$response" | jq -r '.access_token')
    NEW_REFRESH_TOKEN=$(echo "$response" | jq -r '.refresh_token')
    EXPIRES_IN=$(echo "$response" | jq -r '.expires_in')

    # Calculate the new expiration timestamp
    CURRENT_TIME=$(date +%s)
    EXPIRATION_TIMESTAMP=$((CURRENT_TIME + EXPIRES_IN))

    # Update the token information in the file
    echo "Access Token: $NEW_ACCESS_TOKEN" > "$TOKEN_STORE"
    echo "Access Token Expires: $EXPIRATION_TIMESTAMP" >> "$TOKEN_STORE"
    echo "Refresh Token: $NEW_REFRESH_TOKEN" >> "$TOKEN_STORE"
    echo "Refresh Token Expires: $EXPIRATION_TIMESTAMP" >> "$TOKEN_STORE"

    echo "Tokens have been updated."
}

# Function to fetch weather data from Netatmo API and display it
fetch_weather_data() {
    local module_type="$1"
    local data_fields="$2"
    
    local response=$(curl -s -X GET -H "Authorization: Bearer $ACCESS_TOKEN" "https://api.netatmo.net/api/getstationsdata?device_id=$DEVICE_ID" | jq -r ".body.devices[0] | if .type == \"NAMain\" and \"$module_type\" == \"main\" then .dashboard_data | $data_fields else (if .modules then .modules[] | select(.type == \"$module_type\") | .dashboard_data | $data_fields else empty end) end")

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
    update_tokens "$REFRESH_TOKEN_INITIAL"
fi

# Load current token and expiration time
ACCESS_TOKEN=$(grep "Access Token:" "$TOKEN_STORE" | cut -d' ' -f3)
current_time=$(date +%s)
access_token_expires=$(grep "Access Token Expires:" "$TOKEN_STORE" | cut -d' ' -f4)
refresh_token=$(grep "Refresh Token:" "$TOKEN_STORE" | cut -d' ' -f3)

# Check if the access token has expired
if [ -z "$access_token_expires" ]; then
    echo "Invalid expiration time. Initializing with initial tokens..."
    update_tokens "$REFRESH_TOKEN_INITIAL"
elif [ "$current_time" -ge "$access_token_expires" ]; then
    echo "Access token has expired. Updating tokens..."
    update_tokens "$refresh_token"
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
Temperature: \(.Temperature)°C Humidity: \(.Humidity)%, 
"'

if [ "$OUTPUT_TYPE" != "file" ]; then
    echo "Rain Module Data:"
fi

# Fetch rain module data
fetch_weather_data "NAModule3" '"
Rain: \(.Rain) mm, 
"'

if [ "$OUTPUT_TYPE" != "file" ]; then
    echo "Wind Module Data:"
fi

# Fetch wind module data
fetch_weather_data "NAModule2" '"
Wind: \(.WindStrength) km/h from: \(.WindAngle)°
"'
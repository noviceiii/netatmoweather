#!/bin/bash

# Read configuration file
config_file="config.conf"
if [ ! -f "$config_file" ]; then
    echo "Configuration file $config_file not found."
    exit 1
fi

# Source the configuration file
source "$config_file"

# Function to make API calls
api_call() {
    local method=$1
    local endpoint=$2
    local params=$3

    local curl_command=$(cat <<EOF
curl -s -X $method \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "$endpoint$params"
EOF
)

    echo "API Call Command:"
    echo "$curl_command"
    echo

    eval "$curl_command" | jq
}

# Fetch weather data and parse directly
echo "Fetching and parsing weather data..."

# Main device data
echo "Main Device Data:"
curl -s -X GET -H "Authorization: Bearer $ACCESS_TOKEN" "https://api.netatmo.net/api/getstationsdata?device_id=$DEVICE_ID" | jq '.body.devices[0].dashboard_data | "Temp: \(.Temperature)°C, Luftfeuchtigkeit: \(.Humidity)%, Luftdruck: \(.Pressure) mbar, CO2: \(.CO2) ppm, Geräuschpegel: \(.Noise) dB"'

# Outdoor module data
echo "Outdoor Module Data:"
curl -s -X GET -H "Authorization: Bearer $ACCESS_TOKEN" "https://api.netatmo.net/api/getstationsdata?device_id=$DEVICE_ID" | jq '.body.devices[0].modules[] | select(.type == "NAModule1") | "Temp (outside): \(.dashboard_data.Temperature)°C, Luftfeuchtigkeit (außen): \(.dashboard_data.Humidity)%"'

# Rain module data
echo "Rain Module Data:"
curl -s -X GET -H "Authorization: Bearer $ACCESS_TOKEN" "https://api.netatmo.net/api/getstationsdata?device_id=$DEVICE_ID" | jq '.body.devices[0].modules[] | select(.type == "NAModule3") | "Rain: \(.dashboard_data.Rain) mm"'

# Wind module data
echo "Wind Module Data:"
curl -s -X GET -H "Authorization: Bearer $ACCESS_TOKEN" "https://api.netatmo.net/api/getstationsdata?device_id=$DEVICE_ID" | jq '.body.devices[0].modules[] | select(.type == "NAModule2") | "Wind: \(.dashboard_data.WindStrength) km/h, Direction: \(.dashboard_data.WindAngle)°"'
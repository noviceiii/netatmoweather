# Netatmo Weather Data Script

This script fetches weather data from Netatmo devices using their API. It includes token management to handle access token expiration and can output the fetched data either to the screen or to a specified text file.

## Prerequisites

- **curl** - For making HTTP requests to the Netatmo API.
- **jq** - For parsing JSON responses. Install with `sudo apt-get install jq` on Debian-based systems.

## Setup

1. **Clone or download the repository** containing the netatmo script.
2. **Create a Netatmo App** at https://dev.netatmo.com/apps
   - Create a new app if you don't have one
   - Make sure the app has the **`read_station`** scope enabled
   - Note your Client ID (APP_ID) and Client Secret
3. **Generate tokens**:
   - Go to https://dev.netatmo.com/apps and select your app
   - Click on "Token Generator"
   - Select the `read_station` scope
   - Generate a refresh token - this will be your REFRESH_TOKEN_INITIAL
4. **Find your Device ID**:
   - Log in to your Netatmo account at https://my.netatmo.com
   - Go to Settings > Manage my Home
   - Find your weather station and note its MAC address (format: xx:xx:xx:xx:xx:xx)
5. **Create a configuration file**:
   - Copy `config.example.cfg` to `config.cfg`
   - Use full paths in the config file
   - Update the values with your credentials:
     - `REFRESH_TOKEN_INITIAL` - from step 3
     - `APP_ID` - your Client ID from step 2
     - `CLIENT_SECRET` - your Client Secret from step 2
     - `DEVICE_ID` - your weather station MAC address from step 4
     - `TOKEN_STORE` - full path where token info will be stored
     - `OUTPUT_FILE` - full path where weather data will be written (if using file output)

## API Changes (v1.3)

This version includes important updates to work with the latest Netatmo API:
- Fixed API base URL: Changed from `api.netatmo.net` to `api.netatmo.com`
- Added comprehensive error handling for API responses
- Improved token refresh error messages
- Better diagnostics when API calls fail

## Troubleshooting

If you're not receiving weather data:
1. **Check your token**: Make sure your refresh token is valid and has the `read_station` scope
2. **Verify Device ID**: Ensure your DEVICE_ID matches your weather station's MAC address
3. **Check API credentials**: Verify APP_ID and CLIENT_SECRET are correct
4. **Look for error messages**: The script now provides detailed error messages if API calls fail
5. **Token file**: Delete your TOKEN_STORE file to force a fresh token initialization
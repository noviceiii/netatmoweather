# Netatmo Weather Data Script

This script fetches the current values of a Netatmo weather station using the Netatmo API. It manages the OAuth tokens on its own and writes the values either to the screen or to a text file, for example as an overlay text for a webcam or timelapse.

## Prerequisites

- **bash**, **curl**, **realpath** (coreutils)
- **jq** - For parsing JSON responses. Install with `sudo apt-get install jq` on Debian-based systems.
- **flock** (util-linux, optional) - Prevents two runs at the same time. Without it the script works, but must not be started in parallel.

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
   - Copy `config.example.cfg` to `config.cfg` and protect it: `chmod 600 config.cfg`
   - Use full paths in the config file
   - Update the values with your credentials

## Configuration

| Setting | Required | Default | Meaning |
|---|---|---|---|
| `REFRESH_TOKEN_INITIAL` | yes | | Refresh token from the Token Generator, used for the first run |
| `APP_ID` | yes | | Client ID of your Netatmo app |
| `CLIENT_SECRET` | yes | | Client secret of your Netatmo app |
| `DEVICE_ID` | yes | | MAC address of the weather station |
| `TOKEN_STORE` | yes | | Full path of the file holding the current tokens |
| `OUTPUT_TYPE` | no | `screen` | `screen` or `file` |
| `OUTPUT_FILE` | for `file` | | Full path of the output file |
| `MAIN_MODULE` | no | `enable` | Show the indoor main station |
| `OUTDOOR_MODULE` | no | `enable` | Show the outdoor module |
| `RAIN_MODULE` | no | `enable` | Show the rain gauge |
| `WIND_MODULE` | no | `enable` | Show the wind gauge |
| `OUTPUT_SEPARATOR` | no | not set | Text between the modules in file output |
| `VERBOSE` | no | `no` | `yes` prints status messages to stderr |

A config file of version 1.3 keeps working without changes.

## Usage

```
./netatmoweather.sh
./netatmoweather.sh --version
./netatmoweather.sh --help
```

Screen output (`OUTPUT_TYPE="screen"`):

```
Main Device Data:
Temperature: 21.4°C Humidity: 45% Pressure: 1013.2 mb CO2: 512 ppm Noise: 38 dB
Outdoor Module Data:
Out. Temp.: 12.3°C Humidity: 80%
Rain Module Data:
Rain: 0 mm
Wind Module Data:
Wind: 5 km/h from: 180°
```

File output (`OUTPUT_TYPE="file"`) is a single line without a line break at the end:

```
Temperature: 21.4°C Humidity: 45% Pressure: 1013.2 mb CO2: 512 ppm Noise: 38 dB, Out. Temp.: 12.3°C Humidity: 80%, Rain: 0 mm  Wind: 5 km/h from: 180°
```

- A value the station does not deliver is shown as `n/a`.
- A module that is disabled, missing or not reachable is left out. Missing and unreachable modules are reported as a warning.
- Weather data goes to stdout or to the file. Warnings, errors and status messages go to stderr.
- The output file is replaced in one step and only after a successful request. If the API cannot be reached, the previous content stays in place.

### Cron example

Every 10 minutes, errors are appended to a log file:

```
*/10 * * * * /path/to/netatmoweather.sh >/dev/null 2>>/path/to/netatmoweather.log
```

Netatmo updates the station data about every 10 minutes, shorter intervals bring no newer values.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Data fetched, at least one module delivered values |
| 1 | Configuration or dependency problem, output file not writable, another instance running |
| 2 | No valid access token (refresh failed) |
| 3 | Weather data could not be fetched, existing output left unchanged |

## Token handling

- The access token is renewed 5 minutes before it expires, and once more if the API rejects it.
- Netatmo invalidates a refresh token as soon as it has been used. The script therefore checks that the token store is writable before it spends the token, and replaces the store in one step.
- The token store is created with mode 600. Secrets are passed to curl on stdin and do not show up in the process list.
- If the stored refresh token is rejected, the script tries `REFRESH_TOKEN_INITIAL` from the config file. To recover, generate a new token, enter it in `config.cfg` and run the script again. Deleting the token store is not necessary.

## Changes in version 1.4

- 1.4.0 - Startup checks for tools and settings; `.gitignore` now really excludes `config.cfg`
- 1.4.1 - Hardened token handling (atomic store, lock, safety margin, secrets off the command line)
- 1.4.2 - One API call per run instead of one per module, atomic output file, exit codes, retry after a rejected token
- 1.4.3 - `n/a` for missing values, warnings for unreachable modules, switches for every module, `OUTPUT_SEPARATOR`, `VERBOSE`
- 1.4.4 - Documentation

Things that behave differently than in version 1.3:

- Status messages such as "Access token is still valid." are only printed with `VERBOSE="yes"`.
- File output has a `, ` between main and outdoor module (it was missing) and no separator at the end of the line.
- Missing modules are reported on stderr instead of stdout.
- The line `Refresh Token Expires` is no longer written to the token store. An existing store is read without changes.

## API Changes (v1.3)

- Fixed API base URL: Changed from `api.netatmo.net` to `api.netatmo.com`
- Added comprehensive error handling for API responses

## Troubleshooting

1. **Run with `VERBOSE="yes"`** to see what the script does.
2. **Exit code 2 / "Token refresh failed"**: Generate a new refresh token with the `read_station` scope and enter it as `REFRESH_TOKEN_INITIAL`. Check APP_ID and CLIENT_SECRET.
3. **"No data for any enabled module"**: Check that DEVICE_ID matches the MAC address of your station.
4. **A module is reported as not reachable**: Check its batteries and the distance to the main station.
5. **"Cannot create lock file" / "Cannot write to the directory of the token store"**: The directory of TOKEN_STORE must exist and be writable for the user running the script.

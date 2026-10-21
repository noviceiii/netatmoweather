# Netatmo Weather Data Script

This script fetches the current values of a Netatmo weather station using the Netatmo API. It manages the OAuth tokens on its own and writes the values either to the screen or to a text file, for example as an overlay text for a webcam or timelapse.

## Prerequisites

- **bash**, **curl**, **coreutils** (`realpath`, `mktemp`, `stat`)
- **jq** - For parsing JSON responses
- **flock** (util-linux, optional) - Prevents two runs at the same time. Without it the script works, but must not be started in parallel.

On Raspberry Pi OS / Debian (Bullseye or newer) everything is available with:

```
sudo apt-get install curl jq
```

## Setup

1. **Clone the repository**, e.g. `git clone https://github.com/noviceiii/netatmoweather.git /opt/netatmoweather`
2. **Create a Netatmo App** at https://dev.netatmo.com/apps
   - Create a new app if you don't have one
   - Make sure the app has the **`read_station`** scope enabled
   - Note your Client ID (APP_ID) and Client Secret
3. **Generate tokens**:
   - Go to https://dev.netatmo.com/apps and select your app
   - Click on "Token Generator"
   - Select the `read_station` scope
   - Generate a refresh token - this will be your REFRESH_TOKEN_INITIAL
   - Use one token for one installation only: every refresh invalidates the previous token, so two installations with the same token log each other out.
4. **Find your Device ID**:
   - Log in to your Netatmo account at https://my.netatmo.com
   - Go to Settings > Manage my Home
   - Find your weather station and note the MAC address of the main (indoor) station, e.g. `70:ee:50:12:34:56`
5. **Create a configuration file**:
   - `cp config.example.cfg config.cfg && chmod 600 config.cfg`
   - Use full paths in the config file
   - Update the values with your credentials
6. **First run**: `./netatmoweather.sh` should print the values of your station. Run it as the user that runs it from cron later, because that user owns the token store.

## Configuration

| Setting | Required | Default | Meaning |
|---|---|---|---|
| `REFRESH_TOKEN_INITIAL` | yes | | Refresh token from the Token Generator, used for the first run |
| `APP_ID` | yes | | Client ID of your Netatmo app |
| `CLIENT_SECRET` | yes | | Client secret of your Netatmo app |
| `DEVICE_ID` | yes | | MAC address of the main station (`xx:xx:xx:xx:xx:xx`) |
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

Add the line with `crontab -e` as the user that owns the token store. Every 10 minutes, errors are appended to a log file:

```
*/10 * * * * /path/to/netatmoweather.sh >/dev/null 2>>/path/to/netatmoweather.log
```

Netatmo updates the station data about every 10 minutes, shorter intervals bring no newer values.

### Use with timelapse

[timelapse](https://github.com/noviceiii/timelapse) shows the content of a text file in its picture overlay. Set `OUTPUT_TYPE="file"` here, and in the timelapse config `WEATHER_ENABLED=1`, `WFILE` = the same path as `OUTPUT_FILE`, and `[WEATHER]` in `OVERLAY_TEXT`. Because the file is replaced in one step, timelapse never reads a half written file.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Data fetched, at least one module delivered values |
| 1 | Configuration or dependency problem, output file or lock file not writable, another instance running |
| 2 | No valid access token (refresh failed, or the new tokens could not be stored) |
| 3 | Weather data could not be fetched, existing output left unchanged |

## Token handling

- The access token is renewed 5 minutes before it expires, and once more if the API rejects it.
- Netatmo invalidates a refresh token as soon as it has been used. The script therefore checks that the token store is writable before it spends the token, and replaces the store in one step.
- The token store is created with mode 600 and synced to disk before it replaces the old one, so a power cut right after a refresh does not lose the new token. If the new tokens cannot be stored, the script stops and does not spend another token.
- The token refresh is never retried automatically: a retry after a lost answer would send a token that is already invalid.
- Secrets are passed to curl on stdin and do not show up in the process list. They are never written to stdout, stderr or the log.
- If the stored refresh token is rejected, the script tries `REFRESH_TOKEN_INITIAL` from the config file. To recover, generate a new token, enter it in `config.cfg` and run the script again. Deleting the token store is not necessary.

## Version history

- 1.1 - Output to a file
- 1.2 - Better handling of the config file
- 1.3 - API base URL changed from `api.netatmo.net` to `api.netatmo.com`, error handling for API responses
- 1.4.0 - Startup checks for tools and settings; `.gitignore` now really excludes `config.cfg`
- 1.4.1 - Hardened token handling (atomic store, lock, safety margin, secrets off the command line)
- 1.4.2 - One API call per run instead of one per module, atomic output file, exit codes, retry after a rejected token
- 1.4.3 - `n/a` for missing values, warnings for unreachable modules, switches for every module, `OUTPUT_SEPARATOR`, `VERBOSE`
- 1.4.4 - Documentation
- 1.4.5 - Safer token store (complete write, sync, no second refresh after a store error), cleanup on interrupt, unpredictable temp file names, DEVICE_ID check, connect timeout, permission warning for `config.cfg`
- 1.4.6 - Fix crash and wrong titles when modules are unreachable

### Differences to version 1.3

- Status messages such as "Access token is still valid." are only printed with `VERBOSE="yes"`.
- File output has a `, ` between main and outdoor module (it was missing) and no separator at the end of the line.
- Missing modules are reported on stderr instead of stdout.
- The line `Refresh Token Expires` is no longer written to the token store. An existing store is read without changes.
- A `DEVICE_ID` that is not a MAC address is rejected (exit code 1), and a `config.cfg` that others can read causes a warning on every run.

## Troubleshooting

1. **Run with `VERBOSE="yes"`** to see what the script does.
2. **Exit code 2 / "Token refresh failed"**: Generate a new refresh token with the `read_station` scope and enter it as `REFRESH_TOKEN_INITIAL`. Check APP_ID and CLIENT_SECRET.
3. **"No data for any enabled module"**: Check that DEVICE_ID matches the MAC address of your station.
4. **A module is reported as not reachable**: Check its batteries and the distance to the main station.
5. **"Cannot create lock file" / "Cannot write to the directory of the token store"**: The directory of TOKEN_STORE must exist and be writable for the user running the script.
6. **"The new tokens are kept in ..."**: The token store could not be replaced. Fix the cause (permissions, disk full), then move the named file to TOKEN_STORE. It holds the only valid refresh token.
7. **"can be read by other users"**: `chmod 600 config.cfg`.
8. **Tokens become invalid every few hours**: Another installation or tool uses the same Netatmo app and token. Give each installation its own token.

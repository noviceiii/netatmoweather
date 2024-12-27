# Netatmo Weather Data Script

This script fetches weather data from Netatmo devices using their API. It includes token management to handle access token expiration and can output the fetched data either to the screen or to a specified text file.

## Prerequisites

- **curl** - For making HTTP requests to the Netatmo API.
- **jq** - For parsing JSON responses. Install with `sudo apt-get install jq` on Debian-based systems.

## Setup

1. **Clone or download the repository** containing this script.
2. **Create a configuration file**:
   - Rename config.example.conf to `config.cfg`.
   - Change accordingly.
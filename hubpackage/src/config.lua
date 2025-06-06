-- config.lua (Centralized Configuration for Reolink Edge Driver)

local M = {}

-- Known Device Credentials (baked in)
M.DEFAULT_USER = "admin"
M.DEFAULT_PASS = "Doggies44"

-- Snapshot Refresh (seconds)
M.SNAPSHOT_REFRESH_INTERVAL = 300

-- Fallback Static IPs for Manual Discovery
M.STATIC_IP_LIST = {
  -- "192.168.1.10",
  -- "10.0.0.20"
}

-- Optional subnets to actively scan for Reolink devices
M.REOLINK_SUBNETS = {
  -- "192.168.1",
  -- "10.0.0"
}
M.REOLINK_SCAN_ENABLED = false

-- Use NVR for Stream Relay (with fallback if needed)
M.USENVRSTREAM = true
M.NVR_IP = "10.0.0.67"

-- Home Assistant Proxy (optional fallback for snapshot)
M.HA_LOCAL_URL = "http://homeassistant.local:8123"
M.HA_LOCAL_TOKEN = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiIwZWI4MzEyMjAyYTA0MzE1YjE1NmQ3ZGJiMWFhYjU1YSIsImlhdCI6MTc0NjgzNTU3MywiZXhwIjoyMDYyMTk1NTczfQ.VUmVWcIUQeEl9KFkETuFvNyztJftYJiGlJ3B6uQHkQ0"

-- Retry Configuration
M.MAX_RETRIES = 3
M.RETRY_DELAY = 2  -- seconds

-- Logging Toggles
M.EMIT_STANDARD_EVENTS = true
M.EMIT_CUSTOM_EVENTS = true

-- Secure Transport Preference
M.ALLOW_HTTPS = true
M.FORCE_HTTP = false

-- ONVIF Event Polling Interval (seconds)
M.BACKOFF_BASE = 10

-- Verbose logging toggle
M.DEBUG_MODE = false

-- Default Device Profile Map
M.DEFAULT_PROFILES = {
  doorbell = "snapshot-tile-profile-doorbell",  -- corresponds to snapshot-tile-profile-doorbell.yaml
  ptz = "snapshot-tile-profile",                -- used for PTZ and general camera tiles
  nvr = "snapshot-tile-profile",                -- currently reusing the same profile for NVRs
  standard = "snapshot-tile-profile"            -- fallback for anything unclassified
}

return M

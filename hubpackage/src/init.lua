-- init.lua (Enhanced Lifecycle Handler with Snapshot/Stream Integration)

local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local log = require "log"
local cosock = require "cosock"
local http = cosock.asyncify("socket.http")

local event_handlers = require "event_handlers"
local common = require "common"
local commands = require "commands"
local onvif_events = require "onvif_events"
local discover = require "discover"
local config = require "config"
local capability_handlers = require "capability_handlers"
local semaphore = require "semaphore"

-- Custom capabilities
local cap_doorbell = capabilities["pianodream12480.doorbell"]
local cap_twoWayAudio = capabilities["pianodream12480.twoWayAudio"]

-- Emit RTSP stream for live viewer tap, plus periodic fallback snapshot refresh for tiles
local function emit_video_stream(device)
  local rtsp_url = commands.get_stream_url(device)

  -- Emit RTSP for live stream viewer
  device:emit_event(capabilities.videoStream.stream({
    url = rtsp_url,
    protocol = "rtsp"
  }))
  log.info("📡 RTSP stream emitted for " .. device.label)

  -- Schedule periodic snapshot refresh every 15 minutes for tile view fallback
  device.thread:call_with_delay(900, function()
    log.debug("🕒 Periodic snapshot refresh for: " .. device.label)
    commands.refresh_snapshot(device)
  end)

  -- NOTE: If this is an NVR cycling channels, consider emitting the snapshot from NVR to corresponding camera devices in the future
  -- Example: map NVR channel X to virtual device and update its tile too (deferred, pending prototype validation)
end

-- Trigger snapshot on doorbell ring (if motion doesn't catch it)
local function handle_doorbell_press(device)
  if config.EMIT_STANDARD_EVENTS then
    device:emit_event(capabilities.button.button.pushed({ state_change = true }))
    log.info("🔔 Standard doorbell event emitted for SmartThings TV/Fridge")
  end
  if config.EMIT_CUSTOM_EVENTS then
    device:emit_event(cap_doorbell.button("pressed"))
    log.info("🔔 Custom doorbell event emitted")
  end

  -- Always refresh snapshot on button press to update tile view
  commands.refresh_snapshot(device)
end

-- Lifecycle Init
local function init_device(driver, device)
  log.info("⚙️ Device init started for: " .. device.label)
  device:set_field("init_retries", 0)

  -- Set default NVR channel if applicable
  if not device:get_field("nvr_channel") then
    device:set_field("nvr_channel", 0)
  end

  device.thread:queue_event(function()
    commands.smart_initialize(device)
    emit_video_stream(device)
    -- Start ONVIF PullPoint subscription for doorbell and motion events
    onvif_events.subscribe(device, function(evt)
      if evt == "VisitorAlarm" then
        handle_doorbell_press(device)
      elseif evt == "MotionAlarm" then
        event_handlers.handle_motion_trigger(device)
      end
    end)
  end, device)
end

-- Discovery Handler
local newly_added = {}
local devcreate_sem = semaphore()

local function discovery_handler(driver, _, should_continue)
  log.info("🔍 Starting ONVIF discovery phase")

  local known_devices = {}
  for _, device in ipairs(driver:get_devices()) do
    known_devices[device.device_network_id] = true
  end

  discover.discover(10, function(cam_meta)
    local urn = cam_meta.urn or cam_meta.ip or ("unknown_" .. os.time())
    if not known_devices[urn] and not newly_added[urn] then
      log.info("🆕 New device found: " .. urn)

      local profile = config.DEFAULT_PROFILES[cam_meta.profile_hint or "standard"]

      local metadata = {
        type = "LAN",
        device_network_id = urn,
        label = cam_meta.label or "ONVIF Device",
        profile = profile,
        manufacturer = cam_meta.vendname or "Reolink",
        model = cam_meta.hardware or cam_meta.label or "Unknown",
        vendor_provided_label = cam_meta.label
      }

      newly_added[urn] = cam_meta

      devcreate_sem:acquire(function()
        local success, err = pcall(function()
          driver:try_create_device(metadata)
        end)
        if success then
          log.info("✅ Provisional device creation submitted for: " .. metadata.label)
        else
          log.error("❌ Device creation failed: " .. tostring(err))
        end
      end)
    end
  end)
end

-- Device Added
local function device_added(driver, device)
  local urn = device.device_network_id
  local cam_meta = newly_added[urn]

  if cam_meta then
    log.info("💾 Hydrating discovery metadata for device: " .. urn)
    device:set_field("onvif_disco", cam_meta, { persist = true })
    newly_added[urn] = nil
  else
    log.warn("⚠️ No discovery metadata found for: " .. urn)
  end

  device:emit_event(capabilities.motionSensor.motion("inactive"))
  device:emit_event(capabilities.refresh.refresh())
  device:emit_component_event(device.profile.components.info, capabilities["partyvoice23922.onvifstatus"].status("Not configured"))
  devcreate_sem:release()
end

-- Device Removed
local function device_removed(driver, device)
  log.info("🗑️ Device removed: " .. device.label)
  device:set_field("onvif_subscribed", false)
end

-- Driver Definition
local onvif_driver = Driver("Reolink ONVIF Enhanced", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init = init_device,
    added = device_added,
    infoChanged = event_handlers.info_changed,
    removed = device_removed
  },
  capability_handlers = capability_handlers
})

log.info("🚀 Reolink ONVIF Driver loaded")
onvif_driver:run()

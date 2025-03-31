-- audio.lua
local cosock = require "cosock"
local socket = require "cosock.socket"
local log = require "log"
local capabilities = require "st.capabilities"

-- RTSP client state
local rtsp_clients = {}

-- Construct RTSP URL for audio streaming
local function get_rtsp_url(device, stream_type)
    local ip = device.preferences.ipAddress
    local username = device.preferences.userid
    local password = device.preferences.password
    if stream_type == "main" then
        return string.format("rtsp://%s:%s@%s/h264Preview_01_main", username, password, ip)
    else
        return string.format("rtsp://%s:%s@%s/h264Preview_01_sub", username, password, ip)
    end
end

-- Send RTSP request and get response
local function send_rtsp_request(client, request)
    local ok, err = client:send(request .. "\r\n")
    if not ok then
        log.error("Failed to send RTSP request: " .. (err or "unknown error"))
        return nil, err
    end

    local response = ""
    while true do
        local line, err = client:receive("*l")
        if not line then
            log.error("Failed to receive RTSP response: " .. (err or "unknown error"))
            return nil, err
        end
        response = response .. line .. "\r\n"
        if line == "" then break end
    end
    return response
end

-- Start audio stream (ONVIF Profile T, G.711 codec)
local function start_audio_stream(device)
    local device_id = device.device_network_id
    if rtsp_clients[device_id] then
        log.warn("Audio stream already active for device: " .. device_id)
        return
    end

    local rtsp_url = get_rtsp_url(device, device.preferences.stream)
    log.info("Starting audio stream: " .. rtsp_url)

    -- Parse RTSP URL
    local ip = rtsp_url:match("rtsp://.-@(.+):")
    local port = rtsp_url:match(":(%d+)/") or "554"
    local path = rtsp_url:match("rtsp://.+/(.+)$") or "h264Preview_01_main"

    -- Connect to RTSP server
    local client, err = socket.tcp()
    if not client then
        log.error("Failed to create TCP socket: " .. (err or "unknown error"))
        return
    end

    client:settimeout(5)
    local ok, err = client:connect(ip, tonumber(port))
    if not ok then
        log.error("Failed to connect to RTSP server: " .. (err or "unknown error"))
        client:close()
        return
    end

    -- RTSP handshake
    local cseq = 1
    local session_id = nil

    -- OPTIONS
    local options_req = string.format(
        "OPTIONS rtsp://%s:%s/%s RTSP/1.0\r\nCSeq: %d\r\nUser-Agent: SmartThings\r\n",
        ip, port, path, cseq
    )
    local response, err = send_rtsp_request(client, options_req)
    if not response then
        client:close()
        return
    end
    cseq = cseq + 1

    -- DESCRIBE
    local describe_req = string.format(
        "DESCRIBE rtsp://%s:%s/%s RTSP/1.0\r\nCSeq: %d\r\nUser-Agent: SmartThings\r\nAccept: application/sdp\r\n",
        ip, port, path, cseq
    )
    response, err = send_rtsp_request(client, describe_req)
    if not response then
        client:close()
        return
    end
    cseq = cseq + 1

    -- SETUP (request audio stream)
    local setup_req = string.format(
        "SETUP rtsp://%s:%s/%s/trackID=1 RTSP/1.0\r\nCSeq: %d\r\nUser-Agent: SmartThings\r\nTransport: RTP/AVP;unicast;client_port=50000-50001\r\n",
        ip, port, path, cseq
    )
    response, err = send_rtsp_request(client, setup_req)
    if not response then
        client:close()
        return
    end
    session_id = response:match("Session: (%S+)")
    if not session_id then
        log.error("Failed to get RTSP session ID")
        client:close()
        return
    end
    cseq = cseq + 1

    -- PLAY
    local play_req = string.format(
        "PLAY rtsp://%s:%s/%s RTSP/1.0\r\nCSeq: %d\r\nUser-Agent: SmartThings\r\nSession: %s\r\nRange: npt=0.000-\r\n",
        ip, port, path, cseq, session_id
    )
    response, err = send_rtsp_request(client, play_req)
    if not response then
        client:close()
        return
    end
    cseq = cseq + 1

    -- Store client for later teardown
    rtsp_clients[device_id] = {
        client = client,
        session_id = session_id,
        cseq = cseq
    }

    -- Emit event
    device:emit_event(capabilities["pianodream12480.audioStream"].streamStatus("active"))
    log.info("Audio stream started successfully for device: " .. device_id)
end

-- Stop audio stream
local function stop_audio_stream(device)
    local device_id = device.device_network_id
    local client_info = rtsp_clients[device_id]
    if not client_info then
        log.warn("No active audio stream for device: " .. device_id)
        return
    end

    log.info("Stopping audio stream for device: " .. device_id)

    -- TEARDOWN
    local teardown_req = string.format(
        "TEARDOWN rtsp://%s:%s/h264Preview_01_main RTSP/1.0\r\nCSeq: %d\r\nUser-Agent: SmartThings\r\nSession: %s\r\n",
        device.preferences.ipAddress, "554", client_info.cseq, client_info.session_id
    )
    local response, err = send_rtsp_request(client_info.client, teardown_req)
    if not response then
        log.warn("Failed to send TEARDOWN: " .. (err or "unknown error"))
    end

    -- Close connection
    client_info.client:close()
    rtsp_clients[device_id] = nil

    -- Emit event
    device:emit_event(capabilities["pianodream12480.audioStream"].streamStatus("inactive"))
    log.info("Audio stream stopped successfully for device: " .. device_id)
end

-- Lifecycle handler to clean up on device removal
local function device_removed(driver, device)
    stop_audio_stream(device)
end

return {
    start_audio_stream = start_audio_stream,
    stop_audio_stream = stop_audio_stream,
    device_removed = device_removed
}
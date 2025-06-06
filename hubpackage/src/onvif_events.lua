local log = require "log"
local http = require "socket.http"
local ltn12 = require "ltn12"
local socket = require "cosock.socket"
local config = require "config"

local M = {}

local function send_soap_request(device, url, body)
    local response = {}
    local res, status = http.request {
        url = url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/soap+xml; charset=utf-8",
            ["Content-Length"] = tostring(#body)
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(response),
        timeout = 10
    }

    if not res then
        log.error("❌ HTTP request failed: " .. tostring(status))
        return nil
    end

    return table.concat(response)
end

local function send_soap_request_with_retry(device, url, body, retries)
    retries = retries or 3
    for attempt = 1, retries do
        local response = send_soap_request(device, url, body)
        if response then
            return response
        else
            if config.DEBUG_MODE then
                log.warn("Retrying SOAP request (" .. attempt .. "/" .. retries .. ") for " .. device.label)
            end
            socket.sleep(2 ^ attempt)  -- Exponential backoff
        end
    end
    log.error("❌ All retries failed for SOAP request on " .. device.label)
    return nil
end

-- Reset Subscriptions
function M.reset_subscription(device)
    device:set_field("onvif_subscribed", false)
    log.info("🔄 ONVIF subscription reset for " .. device.label)
end

-- Subscribe to PullPoint
function M.subscribe(device, event_callback)
    if device:get_field("onvif_subscribed") then
        if config.DEBUG_MODE then
            log.debug("🔄 Already subscribed to ONVIF PullPoint for " .. device.label)
        end
        return
    end

    local ip = device.preferences.ipAddress or device.device_network_id
    local event_service = string.format("http://%s:8000/onvif/event_service", ip)

    log.info("🔗 Subscribing to ONVIF PullPoint at " .. event_service)

    local subscribe_body = [[
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
          <s:Body>
            <wsnt:CreatePullPointSubscription xmlns:wsnt="http://docs.oasis-open.org/wsn/b-2"/>
          </s:Body>
        </s:Envelope>
    ]]

    local response = send_soap_request_with_retry(device, event_service, subscribe_body)
    if not response then
        log.error("⚠️ Failed to subscribe to PullPoint for " .. device.label)
        return
    end

    device:set_field("onvif_subscribed", true)
    device:set_field("pull_failures", 0)
    log.info("✅ PullPoint subscription successful for " .. device.label)

    M.pull_events_loop(device, event_service, event_callback)
end

-- Pull Events Loop with Failure Tracking
function M.pull_events_loop(device, event_service, event_callback)
    local pull_body = [[
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
          <s:Body>
            <wsnt:PullMessages xmlns:wsnt="http://docs.oasis-open.org/wsn/b-2">
              <wsnt:Timeout>PT10S</wsnt:Timeout>
              <wsnt:MessageLimit>10</wsnt:MessageLimit>
            </wsnt:PullMessages>
          </s:Body>
        </s:Envelope>
    ]]

    device.thread:call_with_delay(config.BACKOFF_BASE, function()
        local response = send_soap_request_with_retry(device, event_service, pull_body)
        if response then
            local failures = 0
            device:set_field("pull_failures", failures)

            if response:find("VisitorAlarm") then
                log.info("🚨 Doorbell Press Detected on " .. device.label)
                event_callback("VisitorAlarm")
            end
            if response:find("MotionAlarm") then
                log.info("🚨 Motion Detected on " .. device.label)
                event_callback("MotionAlarm")
            end
            if response:find("TamperAlarm") then
                log.info("🚨 Tamper Event on " .. device.label)
                event_callback("TamperAlarm")
            end
            if response:find("Person") then
                log.info("🚨 Person Detection on " .. device.label)
                event_callback("Person")
            end
            if response:find("Vehicle") then
                log.info("🚨 Vehicle Detection on " .. device.label)
                event_callback("Vehicle")
            end
            if response:find("Animal") or response:find("Pet") then
                log.info("🚨 Animal Detection on " .. device.label)
                event_callback("Animal")
            end
        else
            local failures = (device:get_field("pull_failures") or 0) + 1
            device:set_field("pull_failures", failures)
            if config.DEBUG_MODE then
                log.warn("⚠️ No events pulled (" .. failures .. " failures) for " .. device.label)
            end
            if failures >= 5 then
                log.error("❌ Too many PullPoint failures. Resetting subscription for " .. device.label)
                M.reset_subscription(device)
                return
            end
        end

        M.pull_events_loop(device, event_service, event_callback)
    end)
end

return M

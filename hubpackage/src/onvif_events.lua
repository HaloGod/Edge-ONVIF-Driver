-- src/onvif_events.lua
local log = require "log"
local capabilities = require "st.capabilities"
local socket = require "cosock.socket"
local http = require "socket.http"
local ltn12 = require "ltn12"
local xml2lua = require "xml2lua"  -- Assuming this is available via the common module
local common = require "common"

-- Import event handlers from init.lua
local init = require "init"

-- Custom capabilities
local onvif_status = capabilities["pianodream12480.onvifStatus"]

-- Constants
local SUBSCRIPTION_TIMEOUT = "PT60M"  -- 60 minutes
local PULL_INTERVAL = 10  -- Pull events every 10 seconds
local MAX_RETRIES = 3
local RETRY_DELAY = 5  -- seconds

-- Function to build a SOAP request
local function build_soap_request(action, body)
    return [[
    <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
        <s:Header>
            <Action s:mustUnderstand="1">]] .. action .. [[</Action>
        </s:Header>
        <s:Body>]] .. body .. [[</s:Body>
    </s:Envelope>
    ]]
end

-- Function to parse SOAP response
local function parse_soap_response(response_body)
    local xml_str = table.concat(response_body)
    local parsed_xml = common.xml_to_table(xml_str)
    if not parsed_xml then
        log.error("Failed to parse SOAP response XML: " .. xml_str)
        return nil
    end
    return parsed_xml
end

-- Function to subscribe to ONVIF events using PullPoint
local function subscribe(device)
    local device_id = device.id
    local device_label = device.label
    local prefs = device:get_field('effective_prefs')
    local ip = prefs.ipAddress
    local port = prefs.port
    local userid = prefs.userid
    local password = prefs.password
    local url = "http://" .. ip .. ":" .. port .. "/onvif/Events"

    log.info(string.format("Subscribing to ONVIF events for device %s (%s) at %s:%s", device_label, device_id, ip, port))

    -- Create a PullPoint subscription
    local subscribe_body = [[
        <CreatePullPointSubscription xmlns="http://www.onvif.org/ver10/events/wsdl">
            <InitialTerminationTime>]] .. SUBSCRIPTION_TIMEOUT .. [[</InitialTerminationTime>
        </CreatePullPointSubscription>
    ]]
    local subscribe_request = build_soap_request("http://www.onvif.org/ver10/events/wsdl/EventPortType/CreatePullPointSubscriptionRequest", subscribe_body)

    local subscription_url
    for attempt = 1, MAX_RETRIES do
        log.debug(string.format("Attempt %d/%d: Sending CreatePullPointSubscription request to %s:%s for device %s", attempt, MAX_RETRIES, ip, port, device_label))
        local response_body = {}
        local res, code, headers = http.request {
            url = url,
            method = "POST",
            headers = {
                ["Content-Type"] = "application/soap+xml",
                ["Content-Length"] = tostring(#subscribe_request)
            },
            source = ltn12.source.string(subscribe_request),
            sink = ltn12.sink.table(response_body),
            user = userid,
            password = password,
            authentication = "digest"
        }

        if res and code == 200 then
            local parsed_response = parse_soap_response(response_body)
            if parsed_response then
                local body = parsed_response["s:Envelope"]["s:Body"]
                local subscription_ref = body["CreatePullPointSubscriptionResponse"]["SubscriptionReference"]
                if subscription_ref and subscription_ref["Address"] then
                    subscription_url = subscription_ref["Address"]
                    log.info(string.format("Successfully subscribed to ONVIF events for device %s (%s). Subscription URL: %s", device_label, device_id, subscription_url))
                    break
                else
                    log.error(string.format("CreatePullPointSubscription response missing SubscriptionReference for device %s (%s)", device_label, device_id))
                end
            end
        else
            log.error(string.format("Failed to subscribe to ONVIF events for device %s (%s) on attempt %d/%d: HTTP %s", device_label, device_id, attempt, MAX_RETRIES, tostring(code)))
            log.debug("Response: " .. (table.concat(response_body) or "no response"))
        end

        if attempt < MAX_RETRIES then
            log.debug(string.format("Retrying subscription for device %s (%s) in %d seconds...", device_label, device_id, RETRY_DELAY))
            socket.sleep(RETRY_DELAY)
        end
    end

    if not subscription_url then
        log.error(string.format("Failed to subscribe to ONVIF events for device %s (%s) after %d attempts", device_label, device_id, MAX_RETRIES))
        device:emit_event(onvif_status.status("error"))
        return
    end

    -- Store subscription URL in device state
    device:set_field('subscription_url', subscription_url, { persist = true })
    device:emit_event(onvif_status.status("connected"))

    -- Start a task to pull events periodically
    cosock.spawn(function()
        while true do
            log.debug(string.format("Pulling events for device %s (%s) from %s", device_label, device_id, subscription_url))
            local pull_body = [[
                <PullMessages xmlns="http://www.onvif.org/ver10/events/wsdl">
                    <Timeout>PT10S</Timeout>
                    <MessageLimit>10</MessageLimit>
                </PullMessages>
            ]]
            local pull_request = build_soap_request("http://www.onvif.org/ver10/events/wsdl/PullPointSubscription/PullMessagesRequest", pull_body)

            local response_body = {}
            local res, code, headers = http.request {
                url = subscription_url,
                method = "POST",
                headers = {
                    ["Content-Type"] = "application/soap+xml",
                    ["Content-Length"] = tostring(#pull_request)
                },
                source = ltn12.source.string(pull_request),
                sink = ltn12.sink.table(response_body),
                user = userid,
                password = password,
                authentication = "digest"
            }

            if res and code == 200 then
                local parsed_response = parse_soap_response(response_body)
                if parsed_response then
                    local body = parsed_response["s:Envelope"]["s:Body"]
                    local pull_response = body["PullMessagesResponse"]
                    if pull_response and pull_response["NotificationMessage"] then
                        local messages = pull_response["NotificationMessage"]
                        -- Handle single message or array of messages
                        if type(messages) ~= "table" or not messages[1] then
                            messages = { messages }
                        end

                        for _, msg in ipairs(messages) do
                            local topic = msg["Topic"]
                            local event_name = msg["Message"]["Message"]["Data"]["SimpleItem"]["_attr"]["Name"]
                            local event_value = msg["Message"]["Message"]["Data"]["SimpleItem"]["_attr"]["Value"]
                            log.info(string.format("Received event for device %s (%s): Topic=%s, Name=%s, Value=%s", device_label, device_id, tostring(topic), tostring(event_name), tostring(event_value)))

                            -- Determine device type and event rules
                            local cam_func = device:get_field('onvif_func') or {}
                            if device_label:match("Doorbell") then
                                cam_func.motion_eventrule = cam_func.motion_eventrule or { item = "MotionAlarm" }
                                cam_func.linecross_eventrule = cam_func.linecross_eventrule or { item = "LineCrossAlarm" }
                                cam_func.tamper_eventrule = cam_func.tamper_eventrule or { item = "TamperAlarm" }
                                cam_func.visitor_eventrule = cam_func.visitor_eventrule or { item = "VisitorAlarm" }
                            elseif device_label:match("TrackMix") then
                                cam_func.motion_eventrule = cam_func.motion_eventrule or { item = "MotionAlarm" }
                                cam_func.linecross_eventrule = cam_func.linecross_eventrule or { item = "LineCrossAlarm" }
                                cam_func.tamper_eventrule = cam_func.tamper_eventrule or { item = "TamperAlarm" }
                                -- TrackMix may not have visitor events
                            else
                                -- NVR or other device
                                cam_func.motion_eventrule = cam_func.motion_eventrule or { item = "MotionAlarm" }
                                cam_func.linecross_eventrule = cam_func.linecross_eventrule or { item = "LineCrossAlarm" }
                                cam_func.tamper_eventrule = cam_func.tamper_eventrule or { item = "TamperAlarm" }
                            end
                            device:set_field('onvif_func', cam_func, { persist = true })

                            -- Route events to appropriate handlers
                            if event_name == cam_func.motion_eventrule.item then
                                log.debug(string.format("Routing Motion event for device %s (%s)", device_label, device_id))
                                init.handle_motion_event(device, cam_func, msg)
                            elseif event_name == cam_func.linecross_eventrule.item then
                                log.debug(string.format("Routing LineCross event for device %s (%s)", device_label, device_id))
                                init.handle_linecross_event(device, cam_func, msg)
                            elseif event_name == cam_func.tamper_eventrule.item then
                                log.debug(string.format("Routing Tamper event for device %s (%s)", device_label, device_id))
                                init.handle_tamper_event(device, cam_func, msg)
                            elseif event_name == cam_func.visitor_eventrule.item then
                                log.debug(string.format("Routing Visitor event for device %s (%s)", device_label, device_id))
                                init.handle_visitor_event(device, cam_func, msg)
                            else
                                log.warn(string.format("Unknown event name %s for device %s (%s)", event_name, device_label, device_id))
                            end
                        end
                    else
                        log.debug(string.format("No events received in this pull for device %s (%s)", device_label, device_id))
                    end
                end
            else
                log.error(string.format("Failed to pull events for device %s (%s): HTTP %s", device_label, device_id, tostring(code)))
                log.debug("Response: " .. (table.concat(response_body) or "no response"))
                -- Attempt to resubscribe if the subscription has expired
                log.info(string.format("Attempting to resubscribe for device %s (%s)", device_label, device_id))
                subscribe(device)
            end

            socket.sleep(PULL_INTERVAL)
        end
    end, "onvif_event_pull_task_" .. device_id)
end

return {
    subscribe = subscribe
}
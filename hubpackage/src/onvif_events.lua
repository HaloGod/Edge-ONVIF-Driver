-- src/onvif_events.lua
local log = require "log"
local capabilities = require "st.capabilities"
local socket = require "socket" -- Changed from cosock.socket
local http = require "socket.http"
local ltn12 = require "ltn12"
local xml2lua = require "xml2lua"
local common = require "common"
local event_handlers = require "event_handlers"

local onvif_status = capabilities["pianodream12480.onvifStatus"]
local SUBSCRIPTION_TIMEOUT = "PT60M"
local PULL_INTERVAL = 10
local MAX_RETRIES = 3
local RETRY_DELAY = 5

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

local function parse_soap_response(response_body)
    local xml_str = table.concat(response_body)
    local parsed_xml = common.xml_to_table(xml_str)
    if not parsed_xml then
        log.error("Failed to parse SOAP response")
        return nil
    end
    return parsed_xml
end

local function subscribe(device)
    local device_id = device.id
    local device_label = device.label
    local prefs = device:get_field('effective_prefs')
    if not prefs then
        log.error("No effective_prefs for " .. device_label)
        device:emit_event(onvif_status.status("error"))
        return
    end
    local ip = prefs.ipAddress
    local port = prefs.port
    local userid = prefs.userid
    local password = prefs.password
    if not ip or not port or not userid or not password then
        log.error("Incomplete preferences for " .. device_label)
        device:emit_event(onvif_status.status("error"))
        return
    end
    local url = "http://" .. ip .. ":" .. port .. "/onvif/Events"
    log.info("Subscribing to ONVIF events for " .. device_label)

    local subscribe_body = [[
        <CreatePullPointSubscription xmlns="http://www.onvif.org/ver10/events/wsdl">
            <InitialTerminationTime>]] .. SUBSCRIPTION_TIMEOUT .. [[</InitialTerminationTime>
        </CreatePullPointSubscription>
    ]]
    local subscribe_request = build_soap_request("http://www.onvif.org/ver10/events/wsdl/EventPortType/CreatePullPointSubscriptionRequest", subscribe_body)

    local subscription_url
    for attempt = 1, MAX_RETRIES do
        local response_body = {}
        http.TIMEOUT = 15
        local res, code = http.request {
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
            if parsed_response and parsed_response["s:Envelope"]["s:Body"]["CreatePullPointSubscriptionResponse"]["SubscriptionReference"] then
                subscription_url = parsed_response["s:Envelope"]["s:Body"]["CreatePullPointSubscriptionResponse"]["SubscriptionReference"]["Address"]
                log.info("Subscribed to ONVIF events for " .. device_label)
                break
            end
        end
        log.warn("Subscription failed for " .. device_label .. ": HTTP " .. tostring(code))
        if attempt < MAX_RETRIES then
            socket.sleep(RETRY_DELAY)
        end
    end
    if not subscription_url then
        log.error("Subscription failed after " .. MAX_RETRIES .. " attempts for " .. device_label)
        device:emit_event(onvif_status.status("error"))
        return
    end

    device:set_field('subscription_url', subscription_url, { persist = true })
    device:emit_event(onvif_status.status("connected"))

    local function pull_events()
        log.debug("Pulling events for " .. device_label)
        local pull_body = [[
            <PullMessages xmlns="http://www.onvif.org/ver10/events/wsdl">
                <Timeout>PT10S</Timeout>
                <MessageLimit>10</MessageLimit>
            </PullMessages>
        ]]
        local pull_request = build_soap_request("http://www.onvif.org/ver10/events/wsdl/PullPointSubscription/PullMessagesRequest", pull_body)
        local response_body = {}
        http.TIMEOUT = 15
        local res, code = http.request {
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
            if parsed_response and parsed_response["s:Envelope"]["s:Body"]["PullMessagesResponse"] then
                local messages = parsed_response["s:Envelope"]["s:Body"]["PullMessagesResponse"]["NotificationMessage"]
                if messages then
                    if type(messages) ~= "table" or not messages[1] then
                        messages = { messages }
                    end
                    for _, msg in ipairs(messages) do
                        local topic = msg["Topic"]
                        local event_name = msg["Message"]["Message"]["Data"]["SimpleItem"]["_attr"]["Name"]
                        local event_value = msg["Message"]["Message"]["Data"]["SimpleItem"]["_attr"]["Value"]
                        log.info("Event for " .. device_label .. ": Name=" .. tostring(event_name))
                        local cam_func = device:get_field('onvif_func') or {}
                        if device_label:match("Doorbell") then
                            cam_func.motion_eventrule = { item = "MotionAlarm" }
                            cam_func.linecross_eventrule = { item = "LineCrossAlarm" }
                            cam_func.tamper_eventrule = { item = "TamperAlarm" }
                            cam_func.visitor_eventrule = { item = "VisitorAlarm" }
                        else
                            cam_func.motion_eventrule = { item = "MotionAlarm" }
                            cam_func.linecross_eventrule = { item = "LineCrossAlarm" }
                            cam_func.tamper_eventrule = { item = "TamperAlarm" }
                        end
                        device:set_field('onvif_func', cam_func, { persist = true })
                        if event_name == cam_func.motion_eventrule.item then
                            event_handlers.handle_motion_event(device, cam_func, msg)
                        elseif event_name == cam_func.linecross_eventrule.item then
                            event_handlers.handle_linecross_event(device, cam_func, msg)
                        elseif event_name == cam_func.tamper_eventrule.item then
                            event_handlers.handle_tamper_event(device, cam_func, msg)
                        elseif event_name == cam_func.visitor_eventrule.item then
                            event_handlers.handle_visitor_event(device, cam_func, msg)
                        end
                    end
                end
            end
        else
            log.warn("Event pull failed for " .. device_label .. ": HTTP " .. tostring(code))
            subscribe(device)
            return
        end
        device.thread:call_with_delay(PULL_INTERVAL, pull_events, "onvif_event_pull_task_" .. device_id)
    end
    device.thread:call_with_delay(0, pull_events, "onvif_event_pull_task_" .. device_id)
end

return {
    subscribe = subscribe
}
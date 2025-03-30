--[[
  Copyright 2022 Todd Austin, enhanced 2025 by suggestions for dMac

  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
  except in compliance with the License. You may obtain a copy of the License at:

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software distributed under the
  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
  either express or implied. See the License for the specific language governing permissions
  and limitations under the License.


  DESCRIPTION
  
  ONVIF Driver authorization-related routines with enhancements for robustness and compatibility


--]]

local cosock = require "cosock"
local socket = require "cosock.socket"
local log = require "log"

local base64 = require "base64"
local sha1 = require "sha1"
local md5 = require "md5"
-- Note: For SHA256 support, you'd need to add a sha256 library (e.g., LuaCrypto); placeholder used here
local sha256 = sha256 or { binary = function(input) log.warn("SHA256 not implemented, falling back to SHA1"); return sha1.binary(input) end }

local client_nonce = {}
local MAX_NONCE_LIFE = 300    -- in seconds


local function refresh_client_nonce(nonce_len)
    local client_nonce = {}
    local binary_nonce = ''
        
    for byte = 1, nonce_len do
        local num = math.random(0, 255)
        binary_nonce = binary_nonce .. string.char(num)
    end
    
    client_nonce.binary = binary_nonce
    client_nonce.base64 = base64.encode(binary_nonce)
    client_nonce.hex = ''
    
    for i = 1, #binary_nonce do
        client_nonce.hex = client_nonce.hex .. string.format('%02x', binary_nonce:byte(i))
    end
    
    local hub_datetime = os.date("!*t")
    client_nonce.epochtime = socket.gettime()
    local created = string.format('%02d-%02d-%02dT%02d:%02d:%02d.000Z', hub_datetime.year, hub_datetime.month, hub_datetime.day, hub_datetime.hour, hub_datetime.min, hub_datetime.sec)
    client_nonce.created = created

    return client_nonce
end

local function get_client_nonce(device, length, authtype)
    if authtype == 'http' then
        local client_nonce = device:get_field('onvif_cnonce')
        if client_nonce and client_nonce.epochtime and client_nonce.binary then
            if (socket.gettime() - client_nonce.epochtime) <= MAX_NONCE_LIFE then
                return client_nonce
            end
        else
            log.warn("Invalid or missing client nonce, refreshing")
        end
    end
    client_nonce = refresh_client_nonce(length)
    device:set_field('onvif_cnonce', client_nonce)
    return client_nonce
end

-- Create Security Header XML for WS Security Username token
local function build_UsernameToken(device)
    local userid = device.preferences.userid
    local password = device.preferences.password
    local algo = device.preferences.authAlgo or "sha1" -- Default to SHA1, configurable via preference
    
    local WSUSERNAMETOKEN_NONCE_LEN = device.preferences.wsNonceLen or 22 -- Configurable nonce length
    local client_nonce = get_client_nonce(device, WSUSERNAMETOKEN_NONCE_LEN, 'wss')
    
    local digest_input = client_nonce.binary .. client_nonce.created .. password
    local base64_digest
    if algo:lower() == "sha256" then
        base64_digest = base64.encode(sha256.binary(digest_input))
    else
        base64_digest = base64.encode(sha1.binary(digest_input))
    end
    
    local UsernameToken = 
        '      <UsernameToken><Username>' .. userid .. '</Username>' ..
        '<Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">' ..
        base64_digest .. '</Password>' ..
        '<Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">' ..
        client_nonce.base64 ..'</Nonce>' ..
        '<Created xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">' ..
        client_nonce.created .. '</Created></UsernameToken>\n'
    
    local SecurityHeader_p1 = [[
    <Security s:mustUnderstand="1" xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">
]]
    local SecurityHeader_p2 = [[
    </Security>
]]

    local authinfo = { type = 'wss' }
    device:set_field('onvif_authinfo', authinfo)
    
    local security_header = SecurityHeader_p1 .. UsernameToken .. SecurityHeader_p2
    log.debug('wss authorization created:')
    log.debug(security_header)
    
    return security_header
end

-- Create HTTP Header for HTTP Authorizations 
local function build_authheader(device, method, fullurl, authdata)
    if authdata.type == 'Digest' then
        if authdata.algorithm and string.lower(authdata.algorithm) ~= 'md5' then
            log.error('Unsupported authentication algorithm:', authdata.algorithm)
            return nil, "Unsupported algorithm"
        end

        local uri = fullurl:match('http://[^/]+(.+)')
        if not uri then
            log.error("Failed to extract URI from:", fullurl)
            return nil, "Invalid URL"
        end

        local userid = device.preferences.userid
        local password = device.preferences.password
        local authinfo = device:get_field('onvif_authinfo') or {}
        
        local HTTPDIGEST_CNONCE_LEN = device.preferences.httpNonceLen or 4 -- Configurable nonce length
        if authdata.qop then
            if authdata.nonce == authinfo.priornonce then
                authinfo.nonce_count = (authinfo.nonce_count or 0) + 1
            else
                authinfo.nonce_count = 1
            end
        end
        
        local ha1 = md5.sumhexa(userid .. ':' .. authdata.realm .. ':' .. password)
        local ha2 = md5.sumhexa(method .. ':' .. uri)
        
        local response, cnonce, h_nonce_count
        if authdata.qop then
            cnonce = get_client_nonce(device, HTTPDIGEST_CNONCE_LEN, 'http')
            h_nonce_count = string.format('%08x', authinfo.nonce_count or 1)
            authinfo.priornonce = authdata.nonce
            response = md5.sumhexa(ha1 .. ':' .. authdata.nonce .. ':' .. h_nonce_count .. ':' .. cnonce.hex .. ':' .. authdata.qop .. ':' .. ha2)
        else
            response = md5.sumhexa(ha1 .. ':' .. authdata.nonce .. ':' .. ha2)
        end
        
        -- Initialize optional HTTP Authorization header fields
        local opaque = authdata.opaque and ', opaque="' .. authdata.opaque .. '"' or ''
        local qop = ''
        local algorithm = authdata.algorithm and 'algorithm=MD5, ' or ''
        local clientnonce = ''
        local nc = ''
        
        if authdata.qop then
            qop = ', qop=' .. authdata.qop .. ', '
            clientnonce = 'cnonce="' .. cnonce.hex .. '", '
            nc = 'nc=' .. h_nonce_count
        end
        
        local authheader = 'Digest ' .. 
                          'username="' .. userid .. '", ' ..
                          'realm="' .. authdata.realm .. '", ' ..
                          algorithm ..
                          'nonce="' .. authdata.nonce .. '", ' ..
                          'uri="' .. uri .. '", ' ..
                          'response="' .. response .. '"' ..
                          opaque ..
                          qop ..
                          clientnonce ..
                          nc 
        
        log.debug('Constructed auth header:', authheader)
        
        authinfo.type = 'http'
        authinfo.authdata = authdata
        authinfo.authheader = authheader
        device:set_field('onvif_authinfo', authinfo)
        
        return authheader
    elseif authdata.type == 'Basic' then
        local userid = device.preferences.userid
        local password = device.preferences.password
        local auth_string = base64.encode(userid .. ':' .. password)
        local authheader = 'Basic ' .. auth_string
        
        local authinfo = { type = 'basic', authheader = authheader }
        device:set_field('onvif_authinfo', authinfo)
        log.debug('Constructed Basic auth header:', authheader)
        return authheader
    else
        log.error('Unsupported authorization type:', authdata.type or "unknown")
        return nil, "Unsupported auth type"
    end
end

return {
    gen_nonce = refresh_client_nonce, -- Updated to match function name
    build_UsernameToken = build_UsernameToken,
    build_authheader = build_authheader
}
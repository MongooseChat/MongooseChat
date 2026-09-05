--[[
================================================================================
    MongooseChat - Objective-boundary incident reporter

    A graceful degradation is only acceptable when it preserves the mod's
    roleplay invariants, and it must never disappear into DEBUG-only output.
    This module gives server and client code one small, always-on reporting
    surface:

      * print a stable incident code for live operators;
      * append the incident to a server-side daily file;
      * forward client-only incidents to the server without forwarding chat
        text or other sensitive payloads;
      * rate-limit identical reports while retaining a suppressed count.

    The reporter is deliberately dependency-light and never throws back into
    chat routing. If its own file/transport path fails, the console remains the
    final report.
================================================================================
]]

local MC_Core = require("MC_Core")

local MC_Incident = {}

local REPORT_WINDOW_MS = 5000
local MAX_DETAIL_LENGTH = 240
local recent = {}
local remoteRecent = {}
local writerFailureReported = false

-- Client-originated codes are an allowlist. A modified client may submit the
-- command directly, so the server never accepts arbitrary log labels.
local CLIENT_CODES = {
    API_DISPATCH_FAILED          = true,
    ANON_LOCAL_PLAYER_UNAVAILABLE = true,
    ANON_MASK_CACHE_UNAVAILABLE   = true,
    ANON_MASK_UNAVAILABLE         = true,
    ANON_POSITION_UNAVAILABLE     = true,
    ANON_RADIO_SPEAKER_UNAVAILABLE = true,
    ANON_VISIBILITY_UNAVAILABLE   = true,
    BABBLE_HINT_FAILED            = true,
    BUBBLE_MODEL_RENDER_UNAVAILABLE = true,
    BUBBLE_COLOR_FALLBACK         = true,
    BUBBLE_IDENTITY_UNAVAILABLE   = true,
    BUBBLE_POSITION_UNAVAILABLE   = true,
    BUBBLE_STYLE_FALLBACK         = true,
    BUBBLE_STYLE_UNAVAILABLE      = true,
    CHANNEL_INVALID               = true,
    CHAT_LAYOUT_FALLBACK          = true,
    CHAT_PAYLOAD_FALLBACK         = true,
    CHAT_PAYLOAD_INVALID          = true,
    CHAT_STYLE_FALLBACK           = true,
    CHAT_INPUT_HOOK_UNAVAILABLE   = true,
    CHAT_INPUT_LIMIT_UNAVAILABLE  = true,
    CHAT_INPUT_OPERATION_FAILED   = true,
    IDENTITY_COLOR_SYNC_EXHAUSTED = true,
    CLIENT_RENDER_FAILED          = true,
    DEAF_TRAIT_UNAVAILABLE        = true,
    IDENTITY_MUTATION_ACK_STALE   = true,
    IDENTITY_MUTATION_IDENTITY_UNAVAILABLE = true,
    IDENTITY_MUTATION_QUEUE_FULL  = true,
    IDENTITY_MUTATION_REQUEST_FAILED = true,
    IDENTITY_MUTATION_REQUEST_MALFORMED = true,
    IDENTITY_MUTATION_RESPONSE_MALFORMED = true,
    LANGADMIN_DIALOG_UNAVAILABLE  = true,
    LANGADMIN_OPERATION_FAILED    = true,
    LORENOTE_BUBBLE_ATTACH_FAILED = true,
    LORENOTE_BUBBLE_REMOVE_FAILED = true,
    LORENOTE_SCAN_UNAVAILABLE     = true,
    LORENOTE_TICK_FAILED          = true,
    NAMEPLATE_LOCAL_PLAYER_UNAVAILABLE = true,
    NAMEPLATE_PERCEPTION_UNAVAILABLE = true,
    NAMEPLATE_POSITION_UNAVAILABLE = true,
    NAMEPLATE_ROSTER_UNAVAILABLE  = true,
    RADIO_DISCOVERY_UNAVAILABLE   = true,
    RADIO_METADATA_INVALID        = true,
    RADIO_POSITION_UNAVAILABLE    = true,
    RADIO_WEATHER_UNAVAILABLE     = true,
    ROLL_RENDER_FALLBACK          = true,
    QSHOUT_BOUNDARY_UNAVAILABLE   = true,
    QSHOUT_ROUTE_FAILED           = true,
    QSHOUT_STATE_UNAVAILABLE      = true,
    SANDBOX_CONFIG_FALLBACK       = true,
    SANDBOX_RELOAD_FAILED         = true,
    SANDBOX_VALUE_FALLBACK        = true,
    SERVER_COMMAND_UNHANDLED      = true,
    SIGN_GESTURE_FAILED           = true,
    UNKNOWN_SLASH_COMMAND_BLOCKED = true,
    VANILLA_CHAT_HOOK_UNAVAILABLE = true,
    VANILLA_ADMIN_UNVERIFIED      = true,
    VANILLA_CHAT_SHAPE_UNKNOWN    = true,
    VANILLA_CHAT_UNVERIFIED       = true,
    VANILLA_RADIO_UNVERIFIED      = true,
    WELCOME_MESSAGE_FAILED        = true,
}

local function cleanCode(code)
    if type(code) ~= "string" then return "INVALID_INCIDENT_CODE" end
    code = code:upper():gsub("[^A-Z0-9_]", "_"):sub(1, 64)
    if code == "" then return "INVALID_INCIDENT_CODE" end
    return code
end

local selfDiagnostic

local function cleanDetail(detail)
    if detail == nil then return "" end
    local ok, rendered = pcall(tostring, detail)
    if not ok then
        if selfDiagnostic then
            selfDiagnostic("REPORT_DETAIL_FALLBACK",
                "unprintable incident detail redacted")
        end
        return "<unprintable detail>"
    end
    rendered = rendered:gsub("[%c]", " "):gsub("%s+", " ")
    return rendered:sub(1, MAX_DETAIL_LENGTH)
end

local selfReported = {}

local function rawPrint(line)
    return pcall(print, line)
end

-- The reporter cannot recursively call MC_Incident.report when one of its
-- own dependencies degrades. Emit a bounded, once-per-condition console
-- incident instead; the original report continues toward disk/transport.
selfDiagnostic = function(code, detail)
    code = cleanCode(code)
    detail = cleanDetail(detail)
    local key = code .. "\0" .. detail
    if selfReported[key] then return end
    selfReported[key] = true
    local line = "[MongooseChat][INCIDENT][" .. code .. "]"
    if detail ~= "" then line = line .. " " .. detail end
    rawPrint(line)
end

local function finiteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function nowMs()
    local ok, value = pcall(MC_Core.getTimeMs)
    if ok and finiteNumber(value) and value > 0 then return value end

    selfDiagnostic("REPORT_CLOCK_UNAVAILABLE",
        "stage=rate-limit; duplicate suppression disabled")
    return 0
end

local function safeDate(format, fallback)
    local ok, value = pcall(os.date, format)
    if ok and type(value) == "string" then return value end
    selfDiagnostic("REPORT_CLOCK_FALLBACK",
        "stage=date-format; substitute=" .. tostring(fallback))
    return fallback
end

local function serverRuntime()
    local ok, value = pcall(function() return isServer() end)
    if not ok or type(value) ~= "boolean" then
        selfDiagnostic("REPORT_RUNTIME_UNAVAILABLE", "surface=isServer")
        return false
    end
    return value == true
end

local function clientRuntime()
    local ok, value = pcall(function() return isClient() end)
    if not ok or type(value) ~= "boolean" then
        selfDiagnostic("REPORT_RUNTIME_UNAVAILABLE", "surface=isClient")
        return false
    end
    return value == true
end

local function appendServerReport(line)
    local ok = pcall(function()
        local date = safeDate("%Y-%m-%d", "undated")
        local writer = getFileWriter("MongooseChat/incidents-" .. date .. ".log", true, true)
        if not writer then error("getFileWriter returned nil") end
        writer:writeln(line)
        writer:close()
    end)
    if not ok and not writerFailureReported then
        writerFailureReported = true
        rawPrint("[MongooseChat][INCIDENT][REPORT_WRITE_FAILED] stage=durable-write")
    end
end

local function rateDecision(bucket, key)
    local now = nowMs()
    local entry = bucket[key]
    if entry and now > 0 and entry.at > 0 and (now - entry.at) < REPORT_WINDOW_MS then
        entry.suppressed = entry.suppressed + 1
        return false, 0
    end
    local suppressed = entry and entry.suppressed or 0
    bucket[key] = { at = now, suppressed = 0 }
    return true, suppressed
end

-- Report a local incident. `detail` must describe state, never carry the
-- player's message body. Returns true when a report was emitted and false
-- when an identical report was folded into the rate-limit window.
function MC_Incident.report(code, detail)
    code = cleanCode(code)
    detail = cleanDetail(detail)

    local key = code .. "\0" .. detail
    local emit, suppressed = rateDecision(recent, key)
    if not emit then return false end
    if suppressed > 0 then
        detail = detail .. (detail ~= "" and " " or "")
            .. "(suppressed " .. tostring(suppressed) .. " repeats)"
    end

    local line = "[MongooseChat][INCIDENT][" .. code .. "]"
    if detail ~= "" then line = line .. " " .. detail end
    rawPrint(line)

    if serverRuntime() then
        appendServerReport(safeDate("%Y-%m-%dT%H:%M:%S", "time-unavailable")
            .. " " .. line)
    elseif clientRuntime() then
        local ok = pcall(sendClientCommand, "MongooseChat", "FallbackIncident", {
            code = code,
            detail = detail,
        })
        if not ok then
            selfDiagnostic("REPORT_FORWARD_FAILED", "stage=client-transport")
        end
    end
    return true
end

-- Server boundary for a client-forwarded incident. Call only from the
-- authoritative OnClientCommand handler.
function MC_Incident.acceptClientReport(player, args)
    if type(args) ~= "table" then return false end
    local code = cleanCode(args.code)
    if not CLIENT_CODES[code] then return false end

    local sourceOK, source = pcall(function() return player:getUsername() end)
    if not sourceOK or type(source) ~= "string" or source == ""
        or #source > 64 or source:find("[%c]") or source:match("^%s*$") then
        MC_Incident.report("CLIENT_INCIDENT_ATTRIBUTION_FAILED",
            "forwarded client incident rejected")
        return false
    end
    local key = source .. "\0" .. code
    local emit, suppressed = rateDecision(remoteRecent, key)
    if not emit then return false end
    local detail = ""
    if suppressed > 0 then
        detail = "(suppressed " .. tostring(suppressed) .. " repeats)"
    end
    -- A client can invoke this command directly. Its detail field is
    -- therefore untrusted and is intentionally discarded: accepting free
    -- text would let a modified client inject chat/private data into the
    -- durable operator log despite the code allowlist.
    return MC_Incident.report(code, "client=" .. source
        .. (detail ~= "" and " " .. detail or ""))
end

return MC_Incident

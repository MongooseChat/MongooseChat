-- MC_Json -- recursive JSON encoder/decoder for MongooseChat persistence.
--
-- WHY THIS EXISTS
-- MC_Lang's MC_Languages.json uses a shallow `{"languages":{"key":"val"}}` shape
-- that a manual gsub+gmatch round-trip handles fine. MC_Acquisitions.json is
-- four levels deep (root -> users -> user -> language -> token -> record) and
-- the gmatch pattern trick doesn't scale to that. Rather than write a bespoke
-- nested marshaller per data type, this module is a small general JSON pair
-- that any Mongoose persistence layer can lean on.
--
-- The implementation is intentionally narrow:
--   - encode handles strings, numbers, booleans, nil, and tables. Tables that
--     contain only integer keys 1..n serialize as arrays; everything else
--     serializes as objects. No mixed-key support; that's a sign the data
--     shape is wrong, not that the encoder should paper over it.
--   - decode is a recursive descent parser over a position pointer. It handles
--     the standard escapes (\\ \" \n \r \t \b \f and a degenerate \u that
--     emits the 4 hex chars literally; our data is UTF-8 already and doesn't
--     use \u). Numbers go through tonumber. null becomes nil.
--   - Both sides go through pcall in the caller. Malformed input returns nil
--     rather than throwing through the callsite.
--
-- KAHLUA NOTES
-- PZ's Lua VM doesn't expose `next` as a global. Anything in here that needs
-- "is this table empty" or "is this table an array" uses pairs() with an early
-- return. Same workaround as MC_Core.isEmpty and the inline copy in MC_Babble.
--
-- PUBLIC API
--   M.encode(value)             -> string  (or nil on unencodable type)
--   M.decode(jsonStr)           -> value   (nil on malformed input)
--
-- Note: decoding a top-level JSON `null` also returns nil -- indistinguishable
-- at this API from a parse failure. No caller currently needs to tell the two
-- apart (every store here is an object or array at the top level); one that
-- does would need to check the input string itself before decoding.

local M = {}

-- ENCODING

local function escapeString(s)
    -- Order matters: escape backslashes first so we don't double-escape the
    -- backslashes we add for the other replacements.
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"',  '\\"')
    s = s:gsub('\n', '\\n')
    s = s:gsub('\r', '\\r')
    s = s:gsub('\t', '\\t')
    s = s:gsub('\b', '\\b')
    s = s:gsub('\f', '\\f')
    return s
end

-- Distinguish array-shaped tables from object-shaped ones. An array here is
-- defined as "every key is an integer in 1..#t and there are no gaps". This is
-- the JavaScript-array contract; mixed tables don't round-trip through JSON
-- cleanly and the caller is expected not to produce them.
local function isArray(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" then return false end
        n = n + 1
    end
    if n == 0 then return false end   -- empty table; treat as object (safer default)
    for i = 1, n do
        if t[i] == nil then return false end
    end
    return true
end

-- Forward declaration so encode can recurse through encodeValue.
local encodeValue

local function encodeArray(t)
    local parts = {}
    for i, v in ipairs(t) do parts[i] = encodeValue(v) end
    return "[" .. table.concat(parts, ",") .. "]"
end

local function encodeObject(t)
    local parts = {}
    for k, v in pairs(t) do
        -- JSON keys must be strings; coerce non-string keys explicitly so we
        -- don't accidentally emit invalid JSON like `{1:"a"}`.
        local keyStr = (type(k) == "string") and k or tostring(k)
        parts[#parts + 1] = '"' .. escapeString(keyStr) .. '":' .. encodeValue(v)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

encodeValue = function(v)
    local t = type(v)
    if t == "nil" then
        return "null"
    elseif t == "boolean" then
        return v and "true" or "false"
    elseif t == "number" then
        -- Guard against NaN, +/-Inf, which aren't valid JSON. Coerce to 0 so
        -- the encoder never produces a parse-poisoning literal like `nan`.
        if v ~= v then return "0" end
        if v == math.huge or v == -math.huge then return "0" end
        -- Integer-shaped numbers serialize without a decimal point; floats use
        -- %.14g to keep precision without trailing-zero noise.
        if math.floor(v) == v and math.abs(v) < 1e15 then
            return string.format("%d", v)
        end
        return string.format("%.14g", v)
    elseif t == "string" then
        return '"' .. escapeString(v) .. '"'
    elseif t == "table" then
        if isArray(v) then return encodeArray(v) end
        return encodeObject(v)
    end
    -- Unknown type (function, userdata, thread). Emit null rather than crash;
    -- the caller can inspect the encoded output to spot the issue.
    return "null"
end

function M.encode(value)
    return encodeValue(value)
end

-- DECODING
--
-- Recursive descent over a position pointer. Each parse function advances
-- the pointer past whatever it consumed and returns the parsed value, or
-- raises a Lua error via the caller's pcall on a structural problem. We use
-- error() inside the parser because the caller wraps decode() in pcall, so
-- the error becomes a clean nil-return at the API boundary.

local function parseError(msg, pos)
    error("MC_Json decode: " .. msg .. " at pos " .. tostring(pos), 0)
end

local function decodeImpl(str)
    if type(str) ~= "string" or str == "" then return nil end

    local pos = 1
    local n = #str

    local function skipWS()
        while pos <= n do
            local c = str:sub(pos, pos)
            if c == " " or c == "\t" or c == "\n" or c == "\r" then
                pos = pos + 1
            else
                return
            end
        end
    end

    -- Forward declaration for mutual recursion.
    local parseValue

    local function parseString()
        if str:sub(pos, pos) ~= '"' then parseError("expected string", pos) end
        pos = pos + 1
        local parts = {}
        while pos <= n do
            local c = str:sub(pos, pos)
            if c == '"' then
                pos = pos + 1
                return table.concat(parts)
            elseif c == "\\" then
                local esc = str:sub(pos + 1, pos + 1)
                if     esc == '"'  then parts[#parts + 1] = '"'
                elseif esc == '\\' then parts[#parts + 1] = '\\'
                elseif esc == '/'  then parts[#parts + 1] = '/'
                elseif esc == 'n'  then parts[#parts + 1] = '\n'
                elseif esc == 'r'  then parts[#parts + 1] = '\r'
                elseif esc == 't'  then parts[#parts + 1] = '\t'
                elseif esc == 'b'  then parts[#parts + 1] = '\b'
                elseif esc == 'f'  then parts[#parts + 1] = '\f'
                elseif esc == 'u'  then
                    -- We don't decode \uXXXX into UTF-8 because that would
                    -- require surrogate-pair handling. Our encoder doesn't
                    -- emit \u -- we keep raw UTF-8 strings -- so this branch
                    -- only fires on hand-edited or third-party JSON. Emit
                    -- the 4 hex chars literally as a placeholder; better than
                    -- crashing.
                    parts[#parts + 1] = str:sub(pos + 2, pos + 5)
                    pos = pos + 4
                else
                    parts[#parts + 1] = esc
                end
                pos = pos + 2
            else
                parts[#parts + 1] = c
                pos = pos + 1
            end
        end
        parseError("unterminated string", pos)
    end

    local function parseNumber()
        local startp = pos
        if str:sub(pos, pos) == "-" then pos = pos + 1 end
        while pos <= n do
            local c = str:sub(pos, pos)
            -- Number characters: digits, decimal point, exponent markers, sign.
            if c:match("[%d%.eE%+%-]") then
                pos = pos + 1
            else
                break
            end
        end
        local s = str:sub(startp, pos - 1)
        local num = tonumber(s)
        if not num then parseError("bad number '" .. s .. "'", startp) end
        return num
    end

    local function parseObject()
        pos = pos + 1   -- consume {
        local obj = {}
        skipWS()
        if str:sub(pos, pos) == "}" then pos = pos + 1; return obj end
        while pos <= n do
            skipWS()
            local key = parseString()
            skipWS()
            if str:sub(pos, pos) ~= ":" then parseError("expected ':'", pos) end
            pos = pos + 1
            skipWS()
            local val = parseValue()
            obj[key] = val
            skipWS()
            local c = str:sub(pos, pos)
            if c == "," then
                pos = pos + 1
            elseif c == "}" then
                pos = pos + 1
                return obj
            else
                parseError("expected ',' or '}'", pos)
            end
        end
        parseError("unterminated object", pos)
    end

    local function parseArray()
        pos = pos + 1   -- consume [
        local arr = {}
        skipWS()
        if str:sub(pos, pos) == "]" then pos = pos + 1; return arr end
        while pos <= n do
            skipWS()
            local val = parseValue()
            arr[#arr + 1] = val
            skipWS()
            local c = str:sub(pos, pos)
            if c == "," then
                pos = pos + 1
            elseif c == "]" then
                pos = pos + 1
                return arr
            else
                parseError("expected ',' or ']'", pos)
            end
        end
        parseError("unterminated array", pos)
    end

    parseValue = function()
        skipWS()
        if pos > n then parseError("unexpected end of input", pos) end
        local c = str:sub(pos, pos)
        if c == "{" then return parseObject() end
        if c == "[" then return parseArray() end
        if c == '"' then return parseString() end
        if c == "t" and str:sub(pos, pos + 3) == "true"  then pos = pos + 4; return true end
        if c == "f" and str:sub(pos, pos + 4) == "false" then pos = pos + 5; return false end
        if c == "n" and str:sub(pos, pos + 3) == "null"  then pos = pos + 4; return nil end
        if c:match("[%-%d]") then return parseNumber() end
        parseError("unexpected character '" .. c .. "'", pos)
    end

    local result = parseValue()
    skipWS()
    if pos <= n then parseError("trailing content", pos) end
    return result
end

function M.decode(jsonStr)
    -- Wrap the implementation in pcall so structural errors return nil rather
    -- than propagating through the callsite. Callers that want diagnostic info
    -- can use MC_Core.safe + their own logging.
    local ok, result = pcall(decodeImpl, jsonStr)
    if not ok then return nil end
    return result
end

return M

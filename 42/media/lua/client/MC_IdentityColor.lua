-- PZ can execute a client module again while old callbacks and shared modules
-- are still alive. Keep one process-session API table whose private closures
-- own the cache; the global registry contains functions only, never identity
-- rows, names, colours, or session data.
local SINGLETON_KEY = "__MONGOOSECHAT_IDENTITY_COLOR_V1"
local singleton = rawget(_G, SINGLETON_KEY)
if type(singleton) == "table" and type(singleton.module) == "function" then
    local ok, existing = pcall(singleton.module)
    if ok and type(existing) == "table"
        and type(existing.applySync) == "function"
        and type(existing.currentBorderSource) == "function" then
        local themeOk, theme = pcall(require, "MC_Theme")
        if themeOk and type(theme) == "table"
            and type(theme.setIdentityColorProvider) == "function" then
            theme.setIdentityColorProvider(existing.currentBorderSource)
        end
        return existing
    end
end
rawset(_G, SINGLETON_KEY, nil)

local MC_IdentityColor = {}
local refreshThemeProvider

local cache = {}
local activeSession = nil
local sessionGeneration = 0

local function cleanString(v, max)
    return type(v) == "string" and v ~= "" and #v <= max
        and not v:find("[%c]") and v or nil
end

local function cleanColor(v)
    if type(v) ~= "table" then return nil end
    local out = {}
    for i = 1, 3 do
        local n = v[i]
        if type(n) ~= "number" or n ~= math.floor(n) or n < 0 or n > 255 then
            return nil
        end
        out[i] = n
    end
    return out
end

local function cleanRow(args)
    if type(args) ~= "table" then return nil end
    local username = cleanString(args.username, 64)
    local characterName = cleanString(args.characterName, 128)
    local color = cleanColor(args.color)
    local revision = args.revision
    if not username or not characterName or not color
        or type(revision) ~= "number" or revision ~= math.floor(revision)
        or revision < 0 or revision > 2147483647
        or (args.origin ~= "chosen" and args.origin ~= "natural") then
        return nil
    end
    return { username=username, characterName=characterName, color=color,
        origin=args.origin, revision=revision }
end

function MC_IdentityColor.clear()
    cache = {}
    activeSession = nil
    sessionGeneration = sessionGeneration + 1
    if refreshThemeProvider then refreshThemeProvider() end
end

function MC_IdentityColor.applySync(args)
    if type(args) ~= "table" or args.protocol ~= 1 then return false end
    local session = cleanString(args.session, 80)
    local row = cleanRow(args)
    if not session or not row then return false end
    if activeSession ~= session then
        cache = {}
        activeSession = session
        sessionGeneration = sessionGeneration + 1
    end
    local old = cache[row.username]
    if old and row.revision <= old.revision then return false end
    cache[row.username] = row
    if refreshThemeProvider then refreshThemeProvider() end
    return true
end

function MC_IdentityColor.applySnapshot(args)
    if type(args) ~= "table" or args.protocol ~= 1 then return false end
    local session = cleanString(args.session, 80)
    if not session or type(args.rows) ~= "table" then return false end
    local replacement, count = {}, 0
    for key, raw in pairs(args.rows) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 or key > 512 then return false end
        local row = cleanRow(raw)
        if not row or replacement[row.username] then return false end
        if activeSession == session and cache[row.username]
            and row.revision < cache[row.username].revision then return false end
        replacement[row.username] = row
        count = count + 1
    end
    if count > 512 then return false end
    for i = 1, count do if args.rows[i] == nil then return false end end
    if activeSession ~= session then
        sessionGeneration = sessionGeneration + 1
    end
    cache, activeSession = replacement, session
    if refreshThemeProvider then refreshThemeProvider() end
    return true
end

function MC_IdentityColor.get(username)
    local row = type(username) == "string" and cache[username] or nil
    return row and { row.color[1], row.color[2], row.color[3] } or nil
end

-- The only Admin hover resolver. It is fed the already-visible engine author
-- and the entitlement result proved by MC_Client. It returns presentation
-- data only: the exact character label and its hue, never account metadata.
function MC_IdentityColor.resolveAdminPresentation(author, entitled)
    if entitled ~= true or type(author) ~= "string" or author == "" then return nil end
    local exact = cache[author]
    if exact then return { name = exact.characterName,
        color = { exact.color[1], exact.color[2], exact.color[3] } } end
    local found
    for _, row in pairs(cache) do
        if row.characterName == author then
            if found then return nil end
            found = row
        end
    end
    return found and { name = found.characterName,
        color = { found.color[1], found.color[2], found.color[3] } } or nil
end

-- Prove whether vanilla's visible Admin author denotes the local player.
-- Account spelling is exact. A character label counts only when it resolves
-- uniquely in the entitled cache and that row is the local account's row.
function MC_IdentityColor.isAdminAuthorLocal(author, entitled)
    if entitled ~= true or type(author) ~= "string" or author == ""
        or type(getPlayer) ~= "function" then return false end
    local ok, player = pcall(getPlayer)
    if not ok or not player then return false end
    local nameOk, username = pcall(function() return player:getUsername() end)
    if not nameOk or type(username) ~= "string" or username == "" then return false end
    -- The engine author itself is enough proof for an exact local account
    -- spelling; colour sync may not have arrived yet. Character labels still
    -- need the entitled cache's exact uniqueness proof below.
    if author == username then return true end
    local found
    for account, row in pairs(cache) do
        if row.characterName == author then
            if found then return false end
            found = account
        end
    end
    return found == username
end

function MC_IdentityColor.current()
    if type(getPlayer) ~= "function" then return nil end
    local ok, player = pcall(getPlayer)
    if not ok or not player then return nil end
    local nameOk, username = pcall(function() return player:getUsername() end)
    return nameOk and MC_IdentityColor.get(username) or nil
end

-- Stable UI seam. Returns a fresh validated RGB table or nil.
MC_IdentityColor.currentColor = MC_IdentityColor.current

-- Privacy-small live-change stamp for the window rim. Generation changes at
-- reconnect/session reset; revision changes for an accepted hue update. No
-- session token, account name, character label, origin, or colour is exposed.
function MC_IdentityColor.currentStamp()
    if type(getPlayer) ~= "function" then return nil end
    local ok, player = pcall(getPlayer)
    if not ok or not player then return nil end
    local nameOk, username = pcall(function() return player:getUsername() end)
    local row = nameOk and cache[username] or nil
    if not row then return nil end
    return { generation = sessionGeneration, revision = row.revision }
end

-- Narrow trusted seam for the shared border compositor. It carries only the
-- current viewer's validated colour and non-secret change stamps.
function MC_IdentityColor.currentBorderSource()
    if type(getPlayer) ~= "function" then return nil end
    local ok, player = pcall(getPlayer)
    if not ok or not player then return nil end
    local nameOk, username = pcall(function() return player:getUsername() end)
    local row = nameOk and cache[username] or nil
    if not row then return nil end
    return { color={ row.color[1], row.color[2], row.color[3] },
        generation=sessionGeneration, revision=row.revision }
end

-- Re-resolve Theme when trusted state changes. PZ can rebuild a shared module
-- table while the client module survives; registering only against the table
-- captured at first load leaves every renderer on the new table at chalk.
-- This keeps the seam live without exposing any cache field to Theme.
refreshThemeProvider = function()
    local ok, theme = pcall(require, "MC_Theme")
    if ok and type(theme) == "table"
        and type(theme.setIdentityColorProvider) == "function" then
        theme.setIdentityColorProvider(MC_IdentityColor.currentBorderSource)
    end
end
refreshThemeProvider()

-- Store only a closure returning the canonical API table. Identity state stays
-- in this module's private locals and cannot be read from the registry itself.
rawset(_G, SINGLETON_KEY, { module=function() return MC_IdentityColor end })

return MC_IdentityColor

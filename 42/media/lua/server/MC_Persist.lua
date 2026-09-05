--[[
================================================================================
    MongooseChat -- Crash-Safe Persistence Layer (A/B generation slots)

    THE PROBLEM THIS SOLVES
    -----------------------
    PZ's Lua sandbox exposes getFileWriter/getFileReader but no rename and
    no delete, so a classic atomic write (write tmp, fsync, rename over the
    target) is impossible. Writing a save file in place means a crash
    mid-write truncates the ONLY copy; on the next boot the decode fails
    and the loader "starts empty" -- for the acquisition DB that is weeks
    of accumulated player vocabulary silently wiped.

    THE SCHEME
    ----------
    Two slot files per store:

        MongooseChat/<name>_a.txt
        MongooseChat/<name>_b.txt

    B42.20 only permits Lua writers to create ini/cfg/txt/log files, so JSON
    envelopes live in .txt containers. Writes alternate between the slots,
    each wrapped in an envelope carrying a monotonically increasing generation
    counter:

        { "mcPersist": 1, "gen": N, "savedAt": <epoch>, "data": <payload> }

    The loader reads both slots and returns the payload of the highest
    valid generation. A torn write can corrupt at most the slot being
    written; the other slot still holds the previous good generation, so
    the worst case is losing one flush interval -- the same exposure the
    dirty-flag design already accepts -- instead of everything.

    Each write is read back and byte-compared against what was intended
    (catches disk-full truncation and silent write failures). On verify
    failure the slot pointer does not advance, so the next flush retries
    over the same bad slot and the good slot is never touched.

    Some B42.19 dedicated-server sandboxes accept the .txt extension but not a
    namespaced writer path. If the canonical write is refused before commit,
    the same envelope is written to root-level <name>_a.txt / <name>_b.txt.
    Both .txt pairs are active inputs and the highest verified generation wins
    on reboot, so moving between 42.19 and 42.20 cannot roll state backward.

    LEGACY MIGRATION
    ----------------
    Stores created before this layer used a single <legacyFile>. Builds before
    B42.20 also wrote A/B envelopes to bare <name>_a.json / <name>_b.json files.
    The loader retains read-only support for both generations of JSON storage.
    A verified save migrates recovered data to the writable .txt pair without
    altering the JSON evidence.

    CORRUPTION POLICY
    -----------------
    Corruption events print ALWAYS-ON console warnings (not dbg) -- a
    server operator must see them with DEBUG off. If no slot or legacy
    snapshot is recoverable, the store becomes unavailable and refuses
    writes for the rest of the session. This preserves every damaged file
    for post-mortem inspection and prevents an unreadable established
    store from being mistaken for a fresh empty one.

    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local MC_Core = require("MC_Core")
local MC_Json = require("MC_Json")
local MC_Incident = require("MC_Incident")

local MC_Persist = {}

local dbg = MC_Core.debugger("PERSIST")

local ENVELOPE_MARK = 1  -- bump only if the envelope shape itself changes
local SLOT_DIRECTORY = "MongooseChat/"
local WRITABLE_SLOT_EXTENSION = ".txt"
local READ_ONLY_SLOT_EXTENSION = ".json"
local SLOT_NAMES = { "a", "b" }

local function warn(fmt, ...)
    -- Always-on, never in the happy path: corruption (bad slot data), IO
    -- failure (a read/write call erroring), or a caller-contract violation
    -- (save() before load(), a non-table payload, a throwing validate) --
    -- three categories, never boot/runtime log noise.
    print("[MongooseChat][PERSIST] WARNING: " .. string.format(fmt, ...))
end

-- Raw file helpers (pcall-wrapped around the PZ file API)

-- Read entire file as a string. Returns (nil, nil) when absent and
-- (nil, reason) when the engine's file API itself failed; callers must not
-- confuse "could not inspect persistence" with a fresh store.
local function readAll(fileName)
    local ok, content = pcall(function()
        local reader = getFileReader(fileName, false)
        if not reader then return nil end
        local parts = {}
        local line = reader:readLine()
        while line ~= nil do
            parts[#parts + 1] = line
            line = reader:readLine()
        end
        reader:close()
        return table.concat(parts, "\n")
    end)
    if not ok then
        warn("read of '%s' threw: %s", fileName, tostring(content))
        return nil, tostring(content)
    end
    return content, nil
end

-- Write a string to a file (truncating). Returns true on apparent success.
local function writeAll(fileName, content)
    local writer
    local ok, err = MC_Core.safeExec(function()
        writer = getFileWriter(fileName, true, false)
        if not writer then return end
        writer:write(content)
        writer:close()
    end)
    if not ok then
        warn("write of '%s' failed: %s", fileName, tostring(err))
        return false
    end
    -- B42.20 returns nil (rather than throwing) when a filename fails its Lua
    -- writer policy. Treat that as an ordinary failed commit boundary: warning
    -- + structured incident at the caller, without manufacturing a Lua stack.
    if not writer then
        warn("write of '%s' failed: getFileWriter returned nil", fileName)
        return false
    end
    return true
end

-- Envelope handling

-- Decode a slot's raw text into a validated envelope.
-- Returns envelope table on success; nil, reason on failure.
local function decodeEnvelope(raw, validate)
    if raw == nil or raw == "" then return nil, "empty" end
    local ok, parsed = pcall(MC_Json.decode, raw)
    if not ok then return nil, "decode error: " .. tostring(parsed) end
    if type(parsed) ~= "table" then return nil, "not a table" end
    if parsed.mcPersist ~= ENVELOPE_MARK then return nil, "missing/unknown envelope mark" end
    if type(parsed.gen) ~= "number"
       or parsed.gen ~= parsed.gen
       or parsed.gen == math.huge
       or parsed.gen == -math.huge
       or parsed.gen < 0
       or parsed.gen % 1 ~= 0 then
        return nil, "missing/invalid generation"
    end
    if type(parsed.savedAt) ~= "number"
       or parsed.savedAt ~= parsed.savedAt
       or parsed.savedAt == math.huge
       or parsed.savedAt == -math.huge
       or parsed.savedAt < 0
       or parsed.savedAt % 1 ~= 0 then
        return nil, "missing/invalid savedAt"
    end
    if type(parsed.data) ~= "table" then return nil, "missing data" end
    if validate then
        -- pcall'd: a throwing validate is treated the same as one that
        -- returns false, not left to crash the loader (see spec.validate's
        -- own contract note in MC_Persist.open below).
        local vOk, vResult = pcall(validate, parsed.data)
        if not vOk then return nil, "validate threw: " .. tostring(vResult) end
        if vResult ~= true then return nil, "payload failed validation" end
    end
    return parsed
end

-- Store object

local Store = {}
Store.__index = Store

--[[
    MC_Persist.open(spec) -> store

    spec = {
        name       = "MC_Acquisitions",        -- REQUIRED. Writable slots become
                                               -- MongooseChat/<name>_a.txt /
                                               -- MongooseChat/<name>_b.txt
        legacyFile = "MC_Acquisitions.json",   -- optional pre-A/B single file,
                                               -- read-only migration fallback
        validate   = function(data) ... end,   -- optional payload sanity check
                                               -- on both load and save.
                                               -- May throw; both boundaries
                                               -- pcall-guard it and refuse.
        onIncident = function(code, detail) end,-- optional structured reporter
                                               -- override. With no override,
                                               -- MC_Incident is always used.
                                               -- May throw without affecting
                                               -- IO; the default reporter then
                                               -- receives the original event.
    }
]]
function MC_Persist.open(spec)
    assert(type(spec) == "table" and type(spec.name) == "string" and spec.name ~= "",
        "MC_Persist.open: spec.name (string) is required")
    assert(spec.name:match("^[A-Za-z0-9_-]+$") ~= nil,
        "MC_Persist.open: spec.name must be a safe file stem")
    local self = setmetatable({}, Store)
    self.name      = spec.name
    self.slotFiles = {
        a = SLOT_DIRECTORY .. spec.name .. "_a" .. WRITABLE_SLOT_EXTENSION,
        b = SLOT_DIRECTORY .. spec.name .. "_b" .. WRITABLE_SLOT_EXTENSION,
    }
    self.compatibilitySlotFiles = {
        a = spec.name .. "_a" .. WRITABLE_SLOT_EXTENSION,
        b = spec.name .. "_b" .. WRITABLE_SLOT_EXTENSION,
    }
    self.activeSlotFiles = self.slotFiles
    -- B42.20's reader still accepts JSON, but its writer rejects the extension.
    -- These pre-B42.20 A/B files are therefore migration/recovery inputs only.
    self.readOnlySlotFiles = {
        a = spec.name .. "_a" .. READ_ONLY_SLOT_EXTENSION,
        b = spec.name .. "_b" .. READ_ONLY_SLOT_EXTENSION,
    }
    self.legacy    = spec.legacyFile
    self.validate  = spec.validate
    self.incidentSink = (type(spec.onIncident) == "function") and spec.onIncident or nil
    self.lastGen   = 0        -- highest generation known good
    self.nextSlot  = "a"      -- slot the next save() targets
    self.pinned    = false    -- true => both slots corrupt (forensic marker)
    self.loaded    = false
    self.loadStatus = "unloaded" -- ready | fresh | unavailable | unloaded
    return self
end

-- Optional structured reporting override. Passing nil restores the always-on
-- MC_Incident default; it never disables persistence reporting.
function Store:setIncidentSink(fn)
    self.incidentSink = (type(fn) == "function") and fn or nil
end

function Store:_incident(code, detail)
    local fullDetail = "name=" .. tostring(self.name) .. " " .. tostring(detail or "")
    if self.incidentSink then
        local ok = pcall(self.incidentSink, code, fullDetail)
        if ok then return end
        -- A custom observer must not be able to swallow the underlying
        -- persistence incident. Do not copy its arbitrary exception into the
        -- durable report.
        fullDetail = fullDetail .. " custom-sink=failed"
    end
    local ok = pcall(MC_Incident.report, code, fullDetail)
    if not ok then
        -- MC_Incident is itself designed never to throw, but retain a final
        -- stable console boundary if that invariant is ever broken.
        print("[MongooseChat][INCIDENT][PERSIST_INCIDENT_REPORT_FAILED]"
            .. " original-code=" .. tostring(code))
    end
end

--[[
    store:load() -> data|nil, source

    Reads both writable .txt A/B pairs first. If neither has a valid
    generation, the pre-B42.20 .json A/B pair and then the pre-A/B single JSON
    file remain available as read-only migration/recovery inputs. `source` is
    one of:
        "a" | "b"                   -- canonical namespaced .txt A/B load
        "compatibility-a" | "compatibility-b"
                                      -- root-level B42.19 .txt fallback
        "legacy-a" | "legacy-b"     -- pre-B42.20 JSON A/B migration
        "legacy"                    -- pre-A/B single-file migration
        "legacy-recovery"           -- stale single-file disaster recovery
        nil                         -- no files exist; caller may start fresh
        "unavailable"               -- files could not be trusted; fail closed

    Also positions the write cursor (generation counter + target slot) so a
    subsequent save() lands on the slot NOT holding the data just loaded.
]]
function Store:load()
    self.loaded = true

    local function inspectPair(files, format)
        local pair = {
            files = files,
            format = format,
            raw = {},
            readFault = {},
            env = {},
            reason = {},
            corrupt = {},
        }
        for _, slot in ipairs(SLOT_NAMES) do
            pair.raw[slot], pair.readFault[slot] = readAll(files[slot])
            pair.env[slot], pair.reason[slot] =
                decodeEnvelope(pair.raw[slot], self.validate)
            if not pair.env[slot] and pair.raw[slot] ~= nil then
                pair.corrupt[slot] = true
                warn("store '%s': %s slot %s ('%s') is unreadable (%s).",
                    self.name, format, slot:upper(), files[slot],
                    tostring(pair.reason[slot]))
                self:_incident("PERSIST_SLOT_CORRUPT",
                    "format=" .. format .. " slot=" .. slot:upper()
                        .. " reason=" .. tostring(pair.reason[slot]))
            elseif pair.readFault[slot] then
                self:_incident("PERSIST_SLOT_READ_FAILED",
                    "format=" .. format .. " slot=" .. slot:upper()
                        .. " reason=" .. tostring(pair.readFault[slot]))
            end
        end
        return pair
    end

    local function pairReadFailed(pair)
        return pair.readFault.a ~= nil or pair.readFault.b ~= nil
    end

    local function pairHasFile(pair)
        return pair.raw.a ~= nil or pair.raw.b ~= nil
    end

    local function chooseWinner(pair)
        if pair.env.a and pair.env.b then
            if pair.env.a.gen == pair.env.b.gen then
                warn("store '%s': equal generations in both %s slots (%d); "
                    .. "preferring A.", self.name, pair.format, pair.env.a.gen)
                self:_incident("PERSIST_GENERATION_TIE",
                    "format=" .. pair.format
                        .. " generation=" .. tostring(pair.env.a.gen)
                        .. " winner=A")
                return "a"
            end
            return (pair.env.b.gen > pair.env.a.gen) and "b" or "a"
        end
        if pair.env.a then return "a" end
        if pair.env.b then return "b" end
        return nil
    end

    local function failReadFault(format)
        warn("store '%s': at least one %s A/B slot could not be inspected; "
            .. "refusing recovery and writes for this session.",
            self.name, format)
        self.loadStatus = "unavailable"
        self:_incident("PERSIST_STORE_UNAVAILABLE",
            "reason=slot-read-failed format=" .. format)
        return nil, "unavailable"
    end

    local writable = inspectPair(self.slotFiles, "writable-txt")
    if pairReadFailed(writable) then
        return failReadFault(writable.format)
    end

    local compatibility = inspectPair(
        self.compatibilitySlotFiles, "compatibility-txt")
    if pairReadFailed(compatibility) then
        return failReadFault(compatibility.format)
    end

    local writableWinner = chooseWinner(writable)
    local compatibilityWinner = chooseWinner(compatibility)
    local activePair, activeWinner, activeSource =
        writable, writableWinner, "canonical"
    if compatibilityWinner and (not writableWinner
        or compatibility.env[compatibilityWinner].gen
            > writable.env[writableWinner].gen)
    then
        activePair, activeWinner, activeSource =
            compatibility, compatibilityWinner, "compatibility"
    end

    if activeWinner then
        self.activeSlotFiles = activePair.files
        self.lastGen  = activePair.env[activeWinner].gen
        self.nextSlot = (activeWinner == "a") and "b" or "a"
        if writable.corrupt.a or writable.corrupt.b
            or compatibility.corrupt.a or compatibility.corrupt.b
        then
            warn("store '%s': recovered generation %d from %s slot %s; "
                .. "the selected pair remains authoritative for the next save.",
                self.name, self.lastGen, activePair.format,
                activeWinner:upper())
            self:_incident("PERSIST_SLOT_RECOVERED",
                "format=" .. activePair.format
                    .. " winner=" .. activeWinner:upper()
                    .. " generation=" .. tostring(self.lastGen))
        end
        dbg("store '%s': loaded gen %d from %s slot %s",
            self.name, self.lastGen, activePair.format,
            activeWinner:upper())
        self.loadStatus = "ready"
        if activeSource == "canonical" then
            return activePair.env[activeWinner].data, activeWinner
        end
        return activePair.env[activeWinner].data,
            "compatibility-" .. activeWinner
    end

    -- If writable evidence exists but neither slot is valid, retain the
    -- established forensic policy. Recovery may overwrite slot A, while slot B
    -- remains untouched for operator inspection.
    if writable.corrupt.a and writable.corrupt.b then
        self.pinned   = true
        self.nextSlot = "a"
        warn("store '%s': BOTH canonical writable slots are corrupt. If JSON "
            .. "recovery succeeds, writes remain pinned to slot A; otherwise "
            .. "all writes are refused. Slot B ('%s') is preserved.",
            self.name, self.slotFiles.b)
        self:_incident("PERSIST_BOTH_SLOTS_CORRUPT",
            "format=" .. writable.format
                .. " slots=A,B forensic-preservation=enabled")
    elseif writable.corrupt.a then
        self.nextSlot = "a"
    elseif writable.corrupt.b then
        self.nextSlot = "b"
    elseif compatibility.corrupt.a or compatibility.corrupt.b then
        -- The canonical pair is clean/absent, so it is the safe recovery target.
        self.activeSlotFiles = self.slotFiles
        self.nextSlot = "a"
    end

    -- Pre-B42.20 A/B JSON slots are readable but no longer writable. They are a
    -- fallback only when the writable pair has no valid generation; once a
    -- verified .txt generation exists, migration is deliberately one-way.
    local readOnly = inspectPair(self.readOnlySlotFiles, "legacy-json")
    if pairReadFailed(readOnly) then
        return failReadFault(readOnly.format)
    end

    local readOnlyWinner = chooseWinner(readOnly)
    if readOnlyWinner then
        self.lastGen = readOnly.env[readOnlyWinner].gen
        local recovered = readOnly.corrupt.a or readOnly.corrupt.b
            or pairHasFile(writable) or pairHasFile(compatibility)
        if recovered then
            warn("store '%s': recovered generation %d from read-only JSON "
                .. "slot %s; the next verified save migrates it to '%s'.",
                self.name, self.lastGen, readOnlyWinner:upper(),
                self.slotFiles[self.nextSlot])
            self:_incident("PERSIST_SLOT_RECOVERED",
                "format=" .. readOnly.format
                    .. " winner=" .. readOnlyWinner:upper()
                    .. " generation=" .. tostring(self.lastGen))
        else
            self:_incident("PERSIST_LEGACY_MIGRATION",
                "legacy=" .. self.readOnlySlotFiles[readOnlyWinner]
                    .. " snapshot=pre-b42.20-ab"
                    .. " generation=" .. tostring(self.lastGen))
        end
        dbg("store '%s': loaded gen %d from read-only JSON slot %s",
            self.name, self.lastGen, readOnlyWinner:upper())
        self.loadStatus = "ready"
        return readOnly.env[readOnlyWinner].data,
            "legacy-" .. readOnlyWinner
    end

    if readOnly.corrupt.a and readOnly.corrupt.b then
        warn("store '%s': BOTH read-only JSON slots are corrupt; they are "
            .. "preserved for inspection.", self.name)
        self:_incident("PERSIST_BOTH_SLOTS_CORRUPT",
            "format=" .. readOnly.format
                .. " slots=A,B forensic-preservation=read-only")
    end

    -- Legacy single-file fallback. Two flavours:
    --   - clean first boot after upgrading (no A/B files)      -> "legacy"
    --   - disaster recovery (some A/B evidence was corrupt)   -> "legacy-recovery"
    local readFault = {}
    if self.legacy then
        local legacyRaw, legacyReadFault = readAll(self.legacy)
        if legacyReadFault then readFault.legacy = legacyReadFault end
        local legacyCorrupt = false
        if legacyRaw ~= nil and legacyRaw ~= "" then
            local ok, parsed = pcall(MC_Json.decode, legacyRaw)
            local valid = ok and type(parsed) == "table"
            if valid and self.validate then
                local validateOk, validateResult = pcall(self.validate, parsed)
                valid = validateOk and validateResult == true
                if not validateOk then
                    warn("store '%s': legacy validation threw: %s",
                        self.name, tostring(validateResult))
                end
            end
            if valid then
                local source = (writable.corrupt.a or writable.corrupt.b
                        or readOnly.corrupt.a or readOnly.corrupt.b)
                    and "legacy-recovery" or "legacy"
                if source == "legacy-recovery" then
                    warn("store '%s': falling back to legacy file '%s' -- this is a " ..
                         "PRE-MIGRATION snapshot and may be stale.",
                        self.name, self.legacy)
                    self:_incident("PERSIST_LEGACY_RECOVERY",
                        "legacy=" .. tostring(self.legacy) .. " snapshot=stale-possible")
                else
                    dbg("store '%s': migrating from legacy file '%s' " ..
                        "(left intact as a pre-migration snapshot)", self.name, self.legacy)
                    self:_incident("PERSIST_LEGACY_MIGRATION",
                        "legacy=" .. tostring(self.legacy)
                            .. " snapshot=pre-ab")
                end
                -- lastGen stays at 0 for a pre-A/B snapshot. Its first save
                -- writes generation 1 into the writable .txt pair.
                self.loadStatus = "ready"
                return parsed, source
            else
                legacyCorrupt = true
            end
        elseif legacyRaw == "" then
            legacyCorrupt = true
        end
        if legacyCorrupt then
            readFault.legacyInvalid = "decode/validation failed"
            warn("store '%s': legacy file '%s' is unreadable; store is unavailable.",
                self.name, self.legacy)
            self:_incident("PERSIST_LEGACY_CORRUPT",
                "legacy=" .. tostring(self.legacy) .. " reason=decode-or-validation")
        end
    end

    if writable.corrupt.a or writable.corrupt.b
        or compatibility.corrupt.a or compatibility.corrupt.b
        or readOnly.corrupt.a or readOnly.corrupt.b
        or readFault.legacy or readFault.legacyInvalid then
        warn("store '%s': no recoverable data found; store is unavailable.", self.name)
        self.loadStatus = "unavailable"
        self:_incident("PERSIST_STORE_UNAVAILABLE",
            "no-recoverable-generation")
        return nil, "unavailable"
    else
        dbg("store '%s': no save data found; starting fresh", self.name)
    end
    self.loadStatus = "fresh"
    return nil, nil
end

-- Read-only health signal for critical callers. "unavailable" means the
-- store could not prove itself fresh and had no recoverable generation.
function Store:getLoadStatus()
    return self.loadStatus
end

--[[
    store:save(data) -> ok

    Validates `data`, obtains a canonical envelope timestamp, encodes it in a
    generation envelope, writes it to the current target slot, reads it back,
    and byte-compares. Only on a verified write does the generation advance
    and the target slot alternate. On any failure the cursor stays put: the
    next save retries the same slot and the other slot's last good generation
    remains untouched.
]]
function Store:save(data)
    if type(data) ~= "table" then
        warn("store '%s': save() called with %s; refusing.", self.name, type(data))
        self:_incident("PERSIST_SAVE_REFUSED",
            "reason=payload-type type=" .. tostring(type(data)))
        return false
    end
    if not self.loaded then
        -- Saving before load() would start at gen 1 and could lose a higher
        -- generation already on disk to the verify-retry path. Refuse loudly:
        -- this is a programming error, not a runtime condition.
        warn("store '%s': save() before load(); refusing to risk on-disk data.", self.name)
        self:_incident("PERSIST_SAVE_REFUSED", "reason=store-not-loaded")
        return false
    end
    if self.loadStatus == "unavailable" then
        warn("store '%s': save() refused while load status is unavailable; "
            .. "preserving on-disk evidence until an operator recovers it.", self.name)
        self:_incident("PERSIST_SAVE_REFUSED", "reason=store-unavailable")
        return false
    end
    if self.validate then
        local validOk, validResult = pcall(self.validate, data)
        if not validOk or validResult ~= true then
            warn("store '%s': payload failed save-time validation; refusing.",
                self.name)
            self:_incident("PERSIST_SAVE_REFUSED",
                validOk and "reason=payload-validation"
                    or "reason=payload-validator-threw")
            return false
        end
    end

    local gen = self.lastGen + 1
    local okClock, savedAt = pcall(MC_Core.getTimeSeconds)
    if not okClock or type(savedAt) ~= "number"
        or savedAt ~= savedAt
        or savedAt <= -math.huge or savedAt >= math.huge
        or savedAt < 0 or savedAt % 1 ~= 0 then
        warn("store '%s': envelope clock unavailable; save refused.", self.name)
        self:_incident("PERSIST_CLOCK_UNAVAILABLE",
            "reason=envelope-timestamp")
        return false
    end
    local okEncode, encoded = pcall(MC_Json.encode, {
        mcPersist = ENVELOPE_MARK,
        gen       = gen,
        savedAt   = savedAt,
        data      = data,
    })
    if not okEncode then
        warn("store '%s': encode failed: %s", self.name, tostring(encoded))
        self:_incident("PERSIST_ENCODE_FAILED", tostring(encoded))
        return false
    end

    local target = self.activeSlotFiles[self.nextSlot]
    if not writeAll(target, encoded) then
        -- B42.19 may accept root-level .txt writers while rejecting the
        -- namespaced B42.20 path. Fall back only from the canonical pair; an
        -- already-selected compatibility pair failing is an ordinary IO fault.
        if self.activeSlotFiles == self.slotFiles then
            local compatibilityTarget =
                self.compatibilitySlotFiles[self.nextSlot]
            if writeAll(compatibilityTarget, encoded) then
                self.activeSlotFiles = self.compatibilitySlotFiles
                target = compatibilityTarget
                self:_incident("PERSIST_PATH_FALLBACK",
                    "slot=" .. tostring(self.nextSlot):upper()
                        .. " path=root-txt")
            else
                self:_incident("PERSIST_WRITE_FAILED",
                    "slot=" .. tostring(self.nextSlot):upper())
                return false
            end
        else
            self:_incident("PERSIST_WRITE_FAILED",
                "slot=" .. tostring(self.nextSlot):upper())
            return false
        end
    end

    -- Read-back verification. readLine strips newline characters, and JSON
    -- string values escape \n as \\n, so MC_Json output round-trips exactly.
    local readBack = readAll(target)
    if readBack ~= encoded then
        warn("store '%s': read-back verify FAILED for slot %s ('%s') -- " ..
             "written %d chars, read %s. Slot pointer not advanced; " ..
             "the other slot still holds generation %d.",
            self.name, self.nextSlot:upper(), target, #encoded,
            readBack and ("%d chars"):format(#readBack) or "nothing",
            self.lastGen)
        self:_incident("PERSIST_VERIFY_FAILED",
            "slot=" .. tostring(self.nextSlot):upper()
                .. " expected-chars=" .. tostring(#encoded))
        return false
    end

    self.lastGen = gen
    self.loadStatus = "ready"
    if not self.pinned then
        self.nextSlot = (self.nextSlot == "a") and "b" or "a"
    end
    dbg("store '%s': wrote gen %d to '%s' (verified, %d chars)",
        self.name, gen, target, #encoded)
    return true
end

return MC_Persist

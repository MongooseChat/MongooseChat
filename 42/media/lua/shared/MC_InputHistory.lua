--[[
================================================================================
    MongooseChat - Chat Input History (pure ring buffer)

    A per-session ring of SENT messages for the chat text entry's Up/Down
    recall. Pulled out of MC_Input.lua's textEntry.onKeyStart glue so the
    cycle/draft/dedup/cap logic can be driven directly by the offline test
    harness -- the widget-glue key hook itself (real GLFW key codes, the
    real ISTextEntryBox) stays in MC_Input.lua and is live-verify only.

    SESSION-MEMORY ONLY: an MC_InputHistory instance lives in RAM for as
    long as the client process does. It is never written to disk and
    starts EMPTY every login -- by design (see the commission's ruling),
    not an oversight.

    SEMANTICS:
    - add(text): record a message that was actually SENT. Empty text is
      ignored. A text identical to the most recent entry is NOT re-added
      (no duplicates-in-a-row), but every add() -- including that no-op
      dedup case -- ends any in-progress browse and clears the draft, since
      a real send means the box is blank again and browsing is over.
    - up(currentText): cycle one step OLDER. The first step away from the
      "not browsing" position (index 0) captures currentText as the draft,
      so down() can hand it back later. Returns the text to show, or nil
      if there is nowhere older to go (caller should leave the box alone).
    - down(): cycle one step NEWER. Returns the text to show (the restored
      draft once back at index 0), or nil if already at index 0 (nothing
      to change).
    - reset(): abandon the current browse (e.g. Escape) without touching
      the stored entries.

    Author: Kialae (Mongoose Server)
    License: MIT
================================================================================
]]

local MC_Core = require("MC_Core")

local dbg = MC_Core.debugger("INPUTHIST")

local MC_InputHistory = {}
MC_InputHistory.__index = MC_InputHistory

local DEFAULT_MAX_SIZE = 50

--[[
    MC_InputHistory.new(maxSize) -> ring

    maxSize defaults to 50 (the commissioned depth). entries[1] is always
    the most recently sent message; index 0 means "not browsing" (the live
    draft is whatever the caller currently has typed).
]]
function MC_InputHistory.new(maxSize)
    local self = setmetatable({}, MC_InputHistory)
    self.maxSize = maxSize or DEFAULT_MAX_SIZE
    self.entries = {}   -- most-recent-first
    self.index = 0       -- 0 = not browsing; 1..#entries while browsing
    self.draft = ""      -- in-progress text captured on the first Up
    return self
end

--[[
    Record a sent message. See module header for the dedup/reset rules.
]]
function MC_InputHistory:add(text)
    if not text or text == "" then return end

    if self.entries[1] ~= text then
        table.insert(self.entries, 1, text)
        while #self.entries > self.maxSize do
            table.remove(self.entries)
        end
        dbg("add: stored '%s', size=%d", text:sub(1, 30), #self.entries)
    else
        dbg("add: skipped duplicate-of-most-recent '%s'", text:sub(1, 30))
    end

    -- A send always ends browsing, whether or not this call actually
    -- inserted a new entry -- the box is blank again either way.
    self.index = 0
    self.draft = ""
end

--[[
    Cycle one step older. currentText is whatever's live in the box right
    now; captured as the draft only on the first step away from index 0.
    Returns the entry to show, or nil if already at the oldest (or there
    is no history at all) -- callers should leave the box untouched.
]]
function MC_InputHistory:up(currentText)
    if #self.entries == 0 or self.index >= #self.entries then
        return nil
    end
    if self.index == 0 then
        self.draft = currentText or ""
    end
    self.index = self.index + 1
    return self.entries[self.index]
end

--[[
    Cycle one step newer. Returns the entry to show (the restored draft
    once back down to index 0), or nil if not currently browsing.
]]
function MC_InputHistory:down()
    if self.index == 0 then
        return nil
    end
    self.index = self.index - 1
    if self.index == 0 then
        return self.draft
    end
    return self.entries[self.index]
end

--[[
    Abandon the current browse (e.g. Escape) without touching the stored
    entries.
]]
function MC_InputHistory:reset()
    self.index = 0
    self.draft = ""
end

--[[
    Number of stored entries (test/debug convenience).
]]
function MC_InputHistory:size()
    return #self.entries
end

return MC_InputHistory

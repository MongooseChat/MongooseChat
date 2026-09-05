-- Pure roster-diff helper for server-owned connection notices.
local MC_ConnectionNotifs = {}

local function sortedKeys(values)
    local keys = {}
    for key in pairs(values) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

function MC_ConnectionNotifs.diff(previous, current, initialized)
    if type(previous) ~= "table" or type(current) ~= "table" then
        return nil
    end
    if initialized ~= true then return {} end

    local changes = {}
    for _, key in ipairs(sortedKeys(current)) do
        if previous[key] == nil then
            changes[#changes + 1] = {
                kind = "join", displayName = current[key].displayName,
            }
        end
    end
    for _, key in ipairs(sortedKeys(previous)) do
        if current[key] == nil then
            changes[#changes + 1] = {
                kind = "leave", displayName = previous[key].displayName,
            }
        end
    end
    return changes
end

return MC_ConnectionNotifs

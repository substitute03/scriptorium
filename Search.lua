--- Search.lua
--- Global search across macro name and body.
local ADDON_NAME, ns = ...
local Data = ns.Data

local Search = {}
ns.Search = Search

local function contains(haystack, needle)
	if not haystack or haystack == "" then
		return false
	end
	return tostring(haystack):lower():find(needle, 1, true) ~= nil
end

--- Returns a list of { entry, path } matching the query.
function Search:Query(rawQuery)
	local results = {}
	local query = rawQuery and tostring(rawQuery):match("^%s*(.-)%s*$") or ""
	if query == "" then
		return results
	end
	local needle = query:lower()

	local entries = Data.db.global.entries
	for _, entry in pairs(entries) do
		if contains(entry.name, needle) or contains(entry.text, needle) then
			results[#results + 1] = {
				entry = entry,
				path = Data:GetEntryPath(entry.id),
			}
		end
	end

	table.sort(results, function(a, b)
		return a.entry.name:lower() < b.entry.name:lower()
	end)

	return results
end

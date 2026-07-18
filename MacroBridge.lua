--- MacroBridge.lua
--- Create Blizzard macros from repository entries.
local ADDON_NAME, ns = ...
local Compat = ns.Compat

local MacroBridge = {}
ns.MacroBridge = MacroBridge

local function findMacroByName(name, perCharacter)
	local accountMax, charMax = Compat.GetMacroLimits()
	local startIndex, endIndex
	if perCharacter then
		startIndex = accountMax + 1
		endIndex = accountMax + charMax
	else
		startIndex = 1
		endIndex = accountMax
	end
	for i = startIndex, endIndex do
		local macroName = GetMacroInfo(i)
		if macroName == name then
			return i
		end
	end
	return nil
end

--- Create a Blizzard macro from an entry.
--- @return ok boolean
--- @return message string
function MacroBridge:CreateFromEntry(entry, perCharacter)
	if not entry then
		return false, "No entry selected."
	end

	if Compat.IsInCombat() then
		return false, "Cannot create macros during combat."
	end

	local name = entry.name or "Scriptorium"
	-- Blizzard macro names are limited to 16 characters.
	if #name > 16 then
		name = name:sub(1, 16)
	end

	local accountMax, charMax = Compat.GetMacroLimits()
	local globalCount, charCount = Compat.GetNumMacros()

	if perCharacter then
		if charCount >= charMax then
			return false, string.format("Character macro limit reached (%d/%d).", charCount, charMax)
		end
	else
		if globalCount >= accountMax then
			return false, string.format("Global macro limit reached (%d/%d).", globalCount, accountMax)
		end
	end

	if findMacroByName(name, perCharacter) then
		local scope = perCharacter and "character" or "global"
		return false, string.format("A %s macro named \"%s\" already exists.", scope, name)
	end

	local icon = Compat.NormalizeIcon(entry.icon)
	local body = entry.text or ""

	local ok, result = pcall(function()
		return Compat.CreateMacro(name, icon, body, perCharacter)
	end)

	if not ok then
		return false, "Failed to create macro: " .. tostring(result)
	end

	if not result then
		return false, "Failed to create macro (unknown error)."
	end

	local scope = perCharacter and "character" or "global"
	return true, string.format("Created %s macro \"%s\".", scope, name)
end

--- MacroBridge.lua
--- Create Blizzard macros from repository entries, and import macros into folders.
local ADDON_NAME, ns = ...
local Compat = ns.Compat
local Data = ns.Data

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

--- List Blizzard macros in the given scope.
--- @param perCharacter boolean
--- @return macros { { index, name, icon, body }, ... }
function MacroBridge:ListMacros(perCharacter)
	local accountMax, charMax = Compat.GetMacroLimits()
	local startIndex, endIndex
	if perCharacter then
		startIndex = accountMax + 1
		endIndex = accountMax + charMax
	else
		startIndex = 1
		endIndex = accountMax
	end

	local macros = {}
	for i = startIndex, endIndex do
		local name, icon, body = GetMacroInfo(i)
		if name then
			macros[#macros + 1] = {
				index = i,
				name = name,
				icon = Compat.NormalizeIcon(icon),
				body = body or "",
			}
		end
	end
	return macros
end

--- Import one or more Blizzard macros into a folder as entries.
--- @param folderId string
--- @param macros table list of { name, icon, body }
--- @return created number
--- @return failed number
--- @return lastError string|nil
function MacroBridge:ImportToFolder(folderId, macros)
	if not folderId or folderId == Data:GetRootId() then
		return 0, 0, "Cannot import macros into the root folder."
	end
	if not Data:GetFolder(folderId) then
		return 0, 0, "Folder not found."
	end
	if not macros or #macros == 0 then
		return 0, 0, "No macros selected."
	end

	local created, failed, lastError = 0, 0, nil
	for _, macro in ipairs(macros) do
		local id, err = Data:CreateEntry(folderId, macro.name or "Imported Macro")
		if not id then
			failed = failed + 1
			lastError = tostring(err)
		else
			Data:UpdateEntry(id, {
				icon = macro.icon,
				text = macro.body or "",
				description = "Imported from Blizzard macro.",
			})
			created = created + 1
		end
	end
	return created, failed, lastError
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

--- MacroBridge.lua
--- Sync Blizzard macros into the repository mirror, and upsert Blizzard macros from macros.
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

local function truncateMacroName(name)
	name = name or "Scriptorium"
	if #name > 16 then
		return name:sub(1, 16)
	end
	return name
end

local function getPlayerName()
	if UnitNameUnmodified then
		return UnitNameUnmodified("player")
	end
	return UnitName("player")
end

local function getRealmName()
	if GetNormalizedRealmName then
		local normalized = GetNormalizedRealmName()
		if normalized and normalized ~= "" then
			return normalized
		end
	end
	local realm = GetRealmName and GetRealmName() or nil
	if realm and realm ~= "" then
		return realm:gsub("%s+", "")
	end
	return "Unknown"
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

--- Import/reconcile Blizzard macros into the managed folder tree.
--- Creates General Macros and Character Macros/<Realm>/<Character>, then reconciles.
--- @return summary table
function MacroBridge:SyncFromBlizzard()
	local rootId = Data:GetRootId()
	Data:PruneUnmanagedRootFolders()

	local generalId = Data:EnsureFolder(rootId, Data.GENERAL_MACROS_NAME)
	local gAdded, gUpdated, gRemoved = Data:ReconcileFolderMacros(generalId, self:ListMacros(false))

	local charRootId = Data:EnsureFolder(rootId, Data.CHARACTER_MACROS_NAME)
	local realmName = getRealmName()
	local charName = getPlayerName() or "Unknown"
	local realmId = Data:EnsureFolder(charRootId, realmName)
	local charId, charFolder = Data:EnsureFolder(realmId, charName)
	local _, classFile = UnitClass("player")
	if charFolder and classFile then
		charFolder.classFile = classFile
	end
	local cAdded, cUpdated, cRemoved = Data:ReconcileFolderMacros(charId, self:ListMacros(true))

	Data.db.global.version = 2

	return {
		generalFolderId = generalId,
		characterFolderId = charId,
		realmFolderId = realmId,
		characterRootId = charRootId,
		realmName = realmName,
		characterName = charName,
		general = { added = gAdded, updated = gUpdated, removed = gRemoved },
		character = { added = cAdded, updated = cUpdated, removed = cRemoved },
	}
end

--- Upsert a Blizzard macro from a repository macro (update if exists, create if not).
--- Never deletes Blizzard macros.
--- @return ok boolean
--- @return message string
function MacroBridge:UpsertFromEntry(entry, perCharacter)
	if not entry then
		return false, "No macro selected."
	end

	if Compat.IsInCombat() then
		return false, "Cannot create or update macros during combat."
	end

	local name = truncateMacroName(entry.name)
	local icon = Compat.NormalizeIcon(entry.icon)
	local body = entry.text or ""
	local existingIndex = findMacroByName(name, perCharacter)
	local scope = perCharacter and "character" or "global"

	if existingIndex then
		local ok, result = pcall(function()
			return Compat.EditMacro(existingIndex, name, icon, body)
		end)
		if not ok then
			return false, "Failed to update macro: " .. tostring(result)
		end
		return true, string.format("Updated %s macro \"%s\".", scope, name)
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

	local ok, result = pcall(function()
		return Compat.CreateMacro(name, icon, body, perCharacter)
	end)

	if not ok then
		return false, "Failed to create macro: " .. tostring(result)
	end

	if not result then
		return false, "Failed to create macro (unknown error)."
	end

	return true, string.format("Created %s macro \"%s\".", scope, name)
end

--- @deprecated Use UpsertFromEntry
function MacroBridge:CreateFromEntry(entry, perCharacter)
	return self:UpsertFromEntry(entry, perCharacter)
end

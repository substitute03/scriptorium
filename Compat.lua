--- Compat.lua
--- Cross-client helpers for Retail and Classic.
local ADDON_NAME, ns = ...
ns.Compat = ns.Compat or {}
local Compat = ns.Compat

local DEFAULT_ICON = "INV_MISC_QUESTIONMARK"

function Compat.IsRetail()
	return WOW_PROJECT_ID == WOW_PROJECT_MAINLINE
end

function Compat.IsClassicEra()
	return WOW_PROJECT_ID == WOW_PROJECT_CLASSIC
end

function Compat.DefaultIcon()
	return DEFAULT_ICON
end

function Compat.GetMacroLimits()
	local account = MAX_ACCOUNT_MACROS or 120
	local character = MAX_CHARACTER_MACROS or 18
	return account, character
end

function Compat.GetNumMacros()
	-- Returns globalCount, characterCount on all supported clients.
	return GetNumMacros()
end

function Compat.CreateMacro(name, icon, body, perCharacter)
	-- CreateMacro(name, iconFileName, body, perCharacter)
	icon = icon or DEFAULT_ICON
	body = body or ""
	if Compat.IsRetail() then
		return CreateMacro(name, icon, body, perCharacter and true or false)
	end
	return CreateMacro(name, icon, body, perCharacter and 1 or nil)
end

function Compat.EditMacro(index, name, icon, body)
	icon = icon or DEFAULT_ICON
	body = body or ""
	return EditMacro(index, name, icon, body)
end

function Compat.IsAddonLoaded(name)
	if C_AddOns and C_AddOns.IsAddOnLoaded then
		return C_AddOns.IsAddOnLoaded(name)
	end
	return IsAddOnLoaded(name)
end

function Compat.LoadAddon(name)
	if C_AddOns and C_AddOns.LoadAddOn then
		return C_AddOns.LoadAddOn(name)
	end
	return LoadAddOn(name)
end

function Compat.IsInCombat()
	return InCombatLockdown and InCombatLockdown()
end

function Compat.GetTime()
	return time()
end

function Compat.NormalizeIcon(icon)
	if not icon or icon == "" then
		return DEFAULT_ICON
	end
	-- Numeric file IDs (or digit strings) are valid retail icon keys.
	if type(icon) == "number" then
		return icon
	end
	if type(icon) == "string" then
		local asNumber = tonumber(icon)
		if asNumber then
			return asNumber
		end
		-- Strip Interface\Icons\ prefix if present for display consistency.
		icon = icon:gsub("^[Ii][Nn][Tt][Ee][Rr][Ff][Aa][Cc][Ee][/\\][Ii][Cc][Oo][Nn][Ss][/\\]", "")
		icon = icon:gsub("%.blp$", "")
	end
	return icon
end

function Compat.GetIconTexture(icon)
	icon = Compat.NormalizeIcon(icon)
	if type(icon) == "number" then
		return icon
	end
	return "Interface\\Icons\\" .. icon
end

local function rawSpellTexture(spell)
	if spell == nil or spell == "" then
		return nil
	end
	local iconID
	if C_Spell and C_Spell.GetSpellTexture then
		iconID = C_Spell.GetSpellTexture(spell)
	elseif GetSpellTexture then
		iconID = GetSpellTexture(spell)
	end
	if type(iconID) == "number" and iconID > 0 then
		return iconID
	end
	if type(iconID) == "string" and iconID ~= "" then
		return iconID
	end
	return nil
end

local function rawSpellName(spellID)
	if C_Spell and C_Spell.GetSpellName then
		return C_Spell.GetSpellName(spellID)
	end
	if GetSpellInfo then
		return GetSpellInfo(spellID)
	end
	return nil
end

--- Title-Case a string ("frost bolt" / "stealth" → "Frost Bolt" / "Stealth").
local function titleCase(str)
	return (tostring(str):lower():gsub("(%a)([%w_']*)", function(first, rest)
		return first:upper() .. rest
	end))
end

--- Resolve a spell texture by name or spell ID (Tell Me When-style).
--- Always returns a single value (fileID or nil); never 0.
function Compat.GetSpellTexture(spell)
	if spell == nil or spell == "" then
		return nil
	end

	local iconID = rawSpellTexture(spell)
	if iconID then
		return iconID
	end

	-- Name variants (retail name lookup is often case-sensitive / data-gated).
	if type(spell) == "string" then
		local variants = {
			spell,
			spell:lower(),
			titleCase(spell),
			spell:upper(),
		}
		for i = 1, #variants do
			local v = variants[i]
			if C_Spell and C_Spell.GetSpellIDForSpellIdentifier then
				local sid = C_Spell.GetSpellIDForSpellIdentifier(v)
				if sid then
					if C_Spell.RequestLoadSpellData then
						C_Spell.RequestLoadSpellData(sid)
					end
					iconID = rawSpellTexture(sid)
					if iconID then
						return iconID
					end
				end
			end
			iconID = rawSpellTexture(v)
			if iconID then
				return iconID
			end
		end
	end

	if C_Spell and C_Spell.GetSpellInfo then
		local info = C_Spell.GetSpellInfo(spell)
		if info then
			local id = info.iconID or info.originalIconID
			if type(id) == "number" and id > 0 then
				return id
			end
		end
	end
	return nil
end

function Compat.GetItemTexture(item)
	if item == nil or item == "" then
		return nil
	end
	local icon
	if C_Item and C_Item.GetItemIconByID then
		icon = C_Item.GetItemIconByID(item)
	elseif GetItemIcon then
		icon = GetItemIcon(item)
	end
	if type(icon) == "number" and icon > 0 then
		return icon
	end
	if type(icon) == "string" and icon ~= "" then
		return icon
	end
	return nil
end

--- True if SetTexture accepts this value as a real (non-green) icon.
--- Rejects nil/0 and numeric IDs that are not valid texture file IDs.
function Compat.IsDisplayableIcon(tex)
	if tex == nil or tex == false or tex == "" or tex == 0 then
		return false
	end
	if type(tex) == "number" and tex < 10000 then
		-- Spell/item IDs are small; real icon FileDataIDs are much larger.
		-- Using a spell ID as a texture produces the neon green square.
		return false
	end
	if not Compat._texProbe then
		local f = CreateFrame("Frame")
		f:Hide()
		Compat._texProbe = f:CreateTexture(nil, "ARTWORK")
	end
	local probe = Compat._texProbe
	probe:SetTexture(nil)
	probe:SetTexture(tex)
	local applied = probe:GetTexture()
	probe:SetTexture(nil)
	return applied ~= nil
end

------------------------------------------------------------------------
-- Macro icon pool (same source as the Blizzard macro UI)
------------------------------------------------------------------------

function Compat.CollectMacroIcons()
	if Compat._macroIconList then
		return Compat._macroIconList
	end
	local icons = {}
	local seen = {}
	local function addAll(list)
		if not list then
			return
		end
		for i = 1, #list do
			local icon = list[i]
			if icon and not seen[icon] then
				seen[icon] = true
				icons[#icons + 1] = icon
			end
		end
	end

	if GetMacroIcons then
		local t = {}
		GetMacroIcons(t)
		addAll(t)
	end
	if GetMacroItemIcons then
		local t = {}
		GetMacroItemIcons(t)
		addAll(t)
	end

	if #icons == 0 and GetNumMacroIcons and GetMacroIconInfo then
		local n = GetNumMacroIcons() or 0
		for i = 1, n do
			local icon = GetMacroIconInfo(i)
			if icon and not seen[icon] then
				seen[icon] = true
				icons[#icons + 1] = icon
			end
		end
	end

	if #icons == 0 then
		icons[1] = DEFAULT_ICON
	end
	Compat._macroIconList = icons
	Compat._macroIconSet = seen
	seen[DEFAULT_ICON] = true
	-- Common file ID for INV_MISC_QUESTIONMARK
	seen[134400] = true
	return icons
end

function Compat.IsMacroSelectableIcon(tex)
	Compat.CollectMacroIcons()
	if not tex then
		return false
	end
	if Compat._macroIconSet[tex] then
		return true
	end
	local norm = Compat.NormalizeIcon(tex)
	if Compat._macroIconSet[norm] then
		return true
	end
	if type(norm) == "string" then
		local path = "Interface\\Icons\\" .. norm
		if Compat._macroIconSet[path] then
			return true
		end
		if GetFileIDFromPath then
			local fid = GetFileIDFromPath(path)
			if fid and Compat._macroIconSet[fid] then
				return true
			end
		end
	end
	return false
end

--- Instant icon search: direct spell/item lookup + filter the macro icon list.
--- (No background spell-ID indexing.)
function Compat.ResolveIconSearch(query)
	local results = {}
	local seen = {}
	local function add(tex)
		if not Compat.IsDisplayableIcon(tex) then
			return
		end
		if seen[tex] then
			return
		end
		seen[tex] = true
		results[#results + 1] = tex
	end

	if type(query) ~= "string" then
		return results
	end
	local q = query:match("^%s*(.-)%s*$") or ""
	if q == "" then
		return results
	end

	local icons = Compat.CollectMacroIcons()
	local id = tonumber(q)
	local needle = q:lower()
	local maxResults = 200

	-- Direct lookups (TMW-style: ask the game for this exact name/ID).
	if id then
		add(Compat.GetSpellTexture(id))
		add(Compat.GetItemTexture(id))
		if Compat._macroIconSet and Compat._macroIconSet[id] then
			add(id)
		end
	else
		add(Compat.GetSpellTexture(q))
		add(Compat.GetItemTexture(q))

		local titled = titleCase(q):gsub("%s+", "_")
		local rawUnderscore = q:gsub("%s+", "_")
		local guesses = {
			"Ability_" .. titled,
			"Ability_" .. rawUnderscore,
			"Spell_" .. titled,
			"Spell_" .. rawUnderscore,
			"INV_" .. titled,
			"INV_Misc_" .. titled,
			titled,
			rawUnderscore,
		}
		for i = 1, #guesses do
			local path = "Interface\\Icons\\" .. guesses[i]
			if GetFileIDFromPath then
				local fid = GetFileIDFromPath(path)
				if fid then
					add(fid)
				end
			end
			add(path)
		end
	end

	if q:find("[/\\]") then
		add(q)
	elseif q:find("_") or needle:find("^inv") or needle:find("^spell") or needle:find("^ability") then
		local path = "Interface\\Icons\\" .. q
		if GetFileIDFromPath then
			local fid = GetFileIDFromPath(path)
			if fid then
				add(fid)
			end
		end
		add(path)
	end

	-- Filter Blizzard's macro icon pool by texture path / id string.
	for i = 1, #icons do
		local icon = icons[i]
		local hay = tostring(icon):lower()
		if hay:find(needle, 1, true) then
			add(icon)
			if #results >= maxResults then
				return results
			end
		end
	end

	-- Player spellbook name matches (fast, no global index).
	if not id then
		local function consider(name, texture, spellID)
			if not name or not name:lower():find(needle, 1, true) then
				return
			end
			add(texture)
			if spellID then
				add(Compat.GetSpellTexture(spellID))
			end
		end

		if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines then
			local spellBank = (Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player) or 0
			for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
				local lineInfo = C_SpellBook.GetSpellBookSkillLineInfo(line)
				if lineInfo then
					local offset = lineInfo.itemIndexOffset or 0
					local num = lineInfo.numSpellBookItems or 0
					for i = offset + 1, offset + num do
						local name, texture, spellID
						if C_SpellBook.GetSpellBookItemInfo then
							local info = C_SpellBook.GetSpellBookItemInfo(i, spellBank)
							if info then
								name = info.name
								texture = info.iconID
								spellID = info.spellID
							end
						end
						if (not name) and C_SpellBook.GetSpellBookItemName then
							name = C_SpellBook.GetSpellBookItemName(i, spellBank)
						end
						if (not texture) and C_SpellBook.GetSpellBookItemTexture then
							texture = C_SpellBook.GetSpellBookItemTexture(i, spellBank)
						end
						consider(name, texture, spellID)
						if #results >= maxResults then
							return results
						end
					end
				end
			end
		elseif GetNumSpellTabs and GetSpellBookItemName then
			local book = BOOKTYPE_SPELL or "spell"
			for tab = 1, GetNumSpellTabs() do
				local _, _, offset, numSpells = GetSpellTabInfo(tab)
				for i = offset + 1, offset + (numSpells or 0) do
					local name = GetSpellBookItemName(i, book)
					local texture = GetSpellBookItemTexture and GetSpellBookItemTexture(i, book)
					consider(name, texture, nil)
					if #results >= maxResults then
						return results
					end
				end
			end
		end
	end

	return results
end

function Compat.RaiseFrame(frame)
	if not frame then
		return
	end
	frame:SetFrameStrata("TOOLTIP")
	local level = 200
	if ns.UI and ns.UI.frame and ns.UI.frame.frame then
		level = ns.UI.frame.frame:GetFrameLevel() + 50
	end
	frame:SetFrameLevel(level)
	frame:ClearAllPoints()
	frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
end

function Compat.ShowIconPicker(callback)
	if not callback then
		return false
	end

	-- Preferred: AceGUI picker owned by the UI module.
	if ns.UI and ns.UI.ShowIconPickerDialog then
		ns.UI:ShowIconPickerDialog(callback)
		return true
	end

	-- Legacy Blizzard MacroPopupFrame (Classic / older retail layout).
	if not Compat.IsAddonLoaded("Blizzard_MacroUI") then
		pcall(Compat.LoadAddon, "Blizzard_MacroUI")
	end

	if MacroPopupFrame then
		Compat.RaiseFrame(MacroPopupFrame)

		local okayBtn = MacroPopupFrame.BorderBox and MacroPopupFrame.BorderBox.OkayButton
			or MacroPopupFrame.OkayButton
		local original
		if okayBtn then
			original = okayBtn:GetScript("OnClick")
			okayBtn:SetScript("OnClick", function(self, ...)
				local icon
				if MacroPopupFrame.BorderBox
					and MacroPopupFrame.BorderBox.SelectedIconArea
					and MacroPopupFrame.BorderBox.SelectedIconArea.SelectedIconButton
				then
					icon = MacroPopupFrame.BorderBox.SelectedIconArea.SelectedIconButton:GetIconTexture()
				elseif MacroPopupFrame.selectedIconName then
					icon = MacroPopupFrame.selectedIconName
				elseif MacroPopupFrame.selectedIconTexture then
					icon = MacroPopupFrame.selectedIconTexture
				elseif GetMacroIconInfo and MacroPopupFrame.selectedIcon then
					icon = GetMacroIconInfo(MacroPopupFrame.selectedIcon)
				end
				okayBtn:SetScript("OnClick", original)
				MacroPopupFrame:Hide()
				if icon then
					callback(Compat.NormalizeIcon(icon))
				end
			end)
		end

		if IconSelectorPopupFrameModes then
			MacroPopupFrame.mode = IconSelectorPopupFrameModes.New
		else
			MacroPopupFrame.mode = "new"
		end
		local ok = pcall(function()
			MacroPopupFrame:Show()
		end)
		if ok and MacroPopupFrame:IsShown() then
			Compat.RaiseFrame(MacroPopupFrame)
			return true
		end
		if okayBtn then
			okayBtn:SetScript("OnClick", original)
		end
	end

	return false
end

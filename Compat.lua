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
	-- Strip Interface\Icons\ prefix if present for display consistency.
	if type(icon) == "string" then
		icon = icon:gsub("^[Ii][Nn][Tt][Ee][Rr][Ff][Aa][Cc][Ee]\\[Ii][Cc][Oo][Nn][Ss]\\", "")
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

--- Attempt to open Blizzard's icon picker when available.
--- callback(icon) receives a texture name or file ID.
function Compat.ShowIconPicker(callback)
	-- Retail / modern: IconSelectorPopupFrameTemplate-based frames vary by patch.
	-- Prefer MacroFrame's popup when macros UI is loaded; otherwise fall back.
	if IconPickerFrame and IconPickerFrame.SetCallback then
		IconPickerFrame:SetCallback(function(icon)
			callback(Compat.NormalizeIcon(icon))
		end)
		IconPickerFrame:Show()
		return true
	end

	-- Classic / shared: MacroPopupFrame (requires MacroFrame loaded).
	if not Compat.IsAddonLoaded("Blizzard_MacroUI") then
		pcall(Compat.LoadAddon, "Blizzard_MacroUI")
	end

	if MacroPopupFrame then
		-- Hook one-shot acceptance if possible.
		local original = MacroPopupFrame.OkayButton and MacroPopupFrame.OkayButton:GetScript("OnClick")
		if MacroPopupFrame.OkayButton then
			MacroPopupFrame.OkayButton:SetScript("OnClick", function(self, ...)
				local icon
				if MacroPopupFrame.selectedIconName then
					icon = MacroPopupFrame.selectedIconName
				elseif MacroPopupFrame.selectedIconTexture then
					icon = MacroPopupFrame.selectedIconTexture
				elseif GetMacroIconInfo and MacroPopupFrame.selectedIcon then
					icon = GetMacroIconInfo(MacroPopupFrame.selectedIcon)
				end
				if original then
					original(self, ...)
				else
					MacroPopupFrame:Hide()
				end
				MacroPopupFrame.OkayButton:SetScript("OnClick", original)
				if icon then
					callback(Compat.NormalizeIcon(icon))
				end
			end)
		end
		MacroPopupFrame:Show()
		return true
	end

	return false
end

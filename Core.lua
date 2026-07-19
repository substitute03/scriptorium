--- Core.lua
--- AceAddon lifecycle, slash commands, messaging.
local ADDON_NAME, ns = ...

local Scriptorium = LibStub("AceAddon-3.0"):NewAddon(
	"Scriptorium",
	"AceConsole-3.0",
	"AceEvent-3.0",
	"AceTimer-3.0"
)
ns.Addon = Scriptorium
_G.Scriptorium = Scriptorium

local Data = ns.Data
local Compat = ns.Compat

local defaults = Data:GetDefaults()

function Scriptorium:OnInitialize()
	self.db = LibStub("AceDB-3.0"):New("ScriptoriumDB", defaults, true)
	-- Force account-wide storage: always use the shared "Default" profile's global table.
	-- AceDB `global` is already account-wide; profiles are unused for repository data.
	Data:Init(self.db)

	self:RegisterChatCommand("scriptorium", "SlashCommand")
	self:RegisterChatCommand("scr", "SlashCommand")

	self:RegisterPopupDialogs()
end

function Scriptorium:OnEnable()
	-- UI is opened on demand via slash command.
end

function Scriptorium:SlashCommand(input)
	input = input and input:match("^%s*(.-)%s*$") or ""
	if input == "help" then
		self:Print("Commands:")
		self:Print("  /scriptorium — toggle the repository window")
		self:Print("  /scr — same as /scriptorium")
		return
	end
	if ns.UI and ns.UI.Toggle then
		ns.UI:Toggle()
	end
end

function Scriptorium:Notify(message, isError)
	local prefix = "|cffc4a35aScriptorium|r: "
	if isError then
		self:Print(prefix .. "|cffff6666" .. message .. "|r")
	else
		self:Print(prefix .. message)
	end
end

function Scriptorium:RegisterPopupDialogs()
	StaticPopupDialogs["SCRIPTORIUM_CONFIRM_DELETE"] = {
		text = "%s",
		button1 = YES,
		button2 = NO,
		OnAccept = function(dialog)
			if dialog.data and dialog.data.callback then
				dialog.data.callback()
			end
		end,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
		preferredIndex = 3,
	}

	StaticPopupDialogs["SCRIPTORIUM_PROMPT_NAME"] = {
		text = "%s",
		button1 = ACCEPT,
		button2 = CANCEL,
		hasEditBox = true,
		maxLetters = 100,
		OnAccept = function(dialog)
			local editBox = dialog.editBox or dialog.EditBox or (dialog.GetEditBox and dialog:GetEditBox())
			local text = editBox and editBox:GetText() or ""
			if dialog.data and dialog.data.callback then
				-- Callback may return false to keep the dialog open (e.g. validation error).
				if dialog.data.callback(text, dialog) == false then
					return true
				end
			end
		end,
		OnShow = function(dialog)
			local editBox = dialog.editBox or dialog.EditBox or (dialog.GetEditBox and dialog:GetEditBox())
			if editBox then
				if dialog.data and dialog.data.default then
					editBox:SetText(dialog.data.default)
					editBox:HighlightText()
				end
				editBox:SetFocus()
			end
			Scriptorium:SetPromptError(dialog, nil)
			Scriptorium:EnsurePromptHeight(dialog)
		end,
		EditBoxOnEnterPressed = function(editBox)
			local dialog = editBox:GetParent()
			local accept = dialog.button1 or dialog.Button1 or _G[dialog:GetName() .. "Button1"]
			if accept then
				accept:Click()
			end
		end,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
		preferredIndex = 3,
	}

	StaticPopupDialogs["SCRIPTORIUM_UNSAVED"] = {
		text = "You have unsaved changes. Discard them?",
		button1 = YES,
		button2 = NO,
		OnAccept = function(dialog)
			if dialog.data and dialog.data.callback then
				dialog.data.callback()
			end
		end,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
		preferredIndex = 3,
	}

	StaticPopupDialogs["SCRIPTORIUM_MACRO_SCOPE"] = {
		text = "Create Blizzard macro as:",
		button1 = "Global Macro",
		button2 = "Character Macro",
		button3 = CANCEL,
		OnAccept = function(dialog)
			if dialog.data and dialog.data.callback then
				dialog.data.callback(false) -- global
			end
		end,
		OnCancel = function(dialog)
			-- button2 maps to OnCancel in 2-button mode; with 3 buttons behaviour varies.
		end,
		OnAlt = function(dialog)
			-- unused
		end,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
		preferredIndex = 3,
	}
end

-- AceGUI Frame uses FULLSCREEN_DIALOG; raise StaticPopups above it.
function Scriptorium:RaisePopup(dialog)
	if not dialog then
		return
	end
	dialog:SetFrameStrata("TOOLTIP")
	local level = 110
	if ns.UI and ns.UI.frame and ns.UI.frame.frame then
		level = ns.UI.frame.frame:GetFrameLevel() + 10
	end
	dialog:SetFrameLevel(level)

    dialog:ClearAllPoints()
	dialog:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
end

function Scriptorium:ConfirmDelete(message, callback)
	local dialog = StaticPopup_Show("SCRIPTORIUM_CONFIRM_DELETE", message)
	if dialog then
		dialog.data = { callback = callback }
		self:RaisePopup(dialog)
	end
end

--- Tall enough for the prompt plus a one-line validation error.
local PROMPT_NAME_HEIGHT = 148

function Scriptorium:EnsurePromptHeight(dialog)
	if not dialog then
		return
	end
	dialog:SetHeight(PROMPT_NAME_HEIGHT)
	dialog.maxHeightSoFar = PROMPT_NAME_HEIGHT
end

--- Show or clear a red validation message inside a PromptName popup.
function Scriptorium:SetPromptError(dialog, message)
	if not dialog or not dialog.data then
		return
	end
	local textWidget = dialog.text or dialog.Text or (dialog.GetName and _G[dialog:GetName() .. "Text"])
	if not textWidget then
		return
	end
	local prompt = dialog.data.prompt or ""
	if message and message ~= "" then
		textWidget:SetText(prompt .. "\n\n|cffff5555" .. message .. "|r")
	else
		textWidget:SetText(prompt)
	end
	self:EnsurePromptHeight(dialog)
end

function Scriptorium:PromptName(message, default, callback)
	local dialog = StaticPopup_Show("SCRIPTORIUM_PROMPT_NAME", message)
	if dialog then
		-- StaticPopup_Show fires OnShow before we can assign data, so set the
		-- edit box text here after show rather than relying on OnShow alone.
		dialog.data = { default = default or "", callback = callback, prompt = message }
		local editBox = dialog.editBox or dialog.EditBox or (dialog.GetEditBox and dialog:GetEditBox())
		if editBox then
			editBox:SetText(default or "")
			editBox:HighlightText()
			editBox:SetFocus()
		end
		self:SetPromptError(dialog, nil)
		self:EnsurePromptHeight(dialog)
		self:RaisePopup(dialog)
	end
end

function Scriptorium:ConfirmUnsaved(callback)
	local dialog = StaticPopup_Show("SCRIPTORIUM_UNSAVED")
	if dialog then
		dialog.data = { callback = callback }
		self:RaisePopup(dialog)
	end
end

function Scriptorium:PromptMacroScope(callback)
	-- Use a simple custom chooser via AceGUI if StaticPopup 3-button is awkward.
	if ns.UI and ns.UI.ShowMacroScopeDialog then
		ns.UI:ShowMacroScopeDialog(callback)
		return
	end
	-- Fallback: global only via confirm-style (shouldn't happen).
	callback(false)
end

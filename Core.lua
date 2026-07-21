--- Core.lua
--- AceAddon lifecycle, slash commands, messaging, login sync.
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
local MacroBridge = ns.MacroBridge

local defaults = Data:GetDefaults()

function Scriptorium:OnInitialize()
	self.db = LibStub("AceDB-3.0"):New("ScriptoriumDB", defaults, true)
	Data:Init(self.db)

	self:RegisterChatCommand("scriptorium", "SlashCommand")
	self:RegisterChatCommand("scr", "SlashCommand")
end

function Scriptorium:OnEnable()
	self:RegisterEvent("PLAYER_LOGIN", "OnPlayerLogin")
	self:RegisterEvent("UPDATE_MACROS", "OnUpdateMacros")
end

function Scriptorium:OnPlayerLogin()
	if not Data:GetSyncOnLogin() then
		return
	end
	-- Macros may load after PLAYER_LOGIN; sync now and again shortly after.
	self:SyncMacros(false)
	self:ScheduleTimer(function()
		if Data:GetSyncOnLogin() then
			self:SyncMacros(false)
		end
	end, 1.5)
end

function Scriptorium:OnUpdateMacros()
	if not Data:GetSyncOnMacroUpdate() then
		return
	end
	-- Keep the mirror in sync whenever Blizzard macros change (source of truth).
	-- Debounce rapid UPDATE_MACROS bursts (e.g. bulk create).
	if self._syncPending then
		return
	end
	self._syncPending = true
	self:ScheduleTimer(function()
		self._syncPending = nil
		if Data:GetSyncOnMacroUpdate() then
			self:SyncMacros(false)
		end
	end, 0.25)
end

--- Reconcile the addon mirror from Blizzard macros (source of truth).
--- @param notify boolean|nil when true, print a status message (manual import)
function Scriptorium:SyncMacros(notify)
	local summary = MacroBridge:SyncFromBlizzard()

	if ns.UI and ns.UI.frame then
		ns.UI:RefreshAll()
	end

	if notify then
		local message = "Macros updated successfully."
		self:Notify(message)
		if ns.UI and ns.UI.SetStatus then
			ns.UI:SetStatus(message)
		end
	end

	return summary
end

function Scriptorium:SlashCommand(input)
	input = input and input:match("^%s*(.-)%s*$") or ""
	if input == "help" then
		self:Print("Commands:")
		self:Print("  /scriptorium — toggle the macro browser")
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

-- AceGUI Frame uses FULLSCREEN_DIALOG; raise dialogs above it.
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
	if not StaticPopupDialogs["SCRIPTORIUM_CONFIRM_DELETE"] then
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
	end
	local dialog = StaticPopup_Show("SCRIPTORIUM_CONFIRM_DELETE", message)
	if dialog then
		dialog.data = { callback = callback }
		self:RaisePopup(dialog)
	end
end

function Scriptorium:PromptMacroScope(callback)
	if ns.UI and ns.UI.ShowMacroScopeDialog then
		ns.UI:ShowMacroScopeDialog(callback)
		return
	end
	callback(false)
end

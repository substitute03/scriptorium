--- UI/AddressBar.lua
--- Windows Explorer-style folder address bar (breadcrumbs + editable path).
local ADDON_NAME, ns = ...

local Data = ns.Data
local Compat = ns.Compat

local AddressBar = {}
ns.AddressBar = AddressBar

local MAX_SUGGESTIONS = 10
local SUGGEST_ROW_HEIGHT = 18

local function addon()
	return ns.Addon
end

local function ui()
	return ns.UI
end

------------------------------------------------------------------------
-- Construction
------------------------------------------------------------------------

--- Create the address bar inside a host AceGUI widget's frame.
--- @param hostWidget AceGUI SimpleGroup (full width row cell)
function AddressBar:Create(hostWidget)
	if self.host then
		return self
	end

	local hostFrame = hostWidget.content or hostWidget.frame
	self.host = hostWidget
	self.editing = false
	self.suppressTextChanged = false
	self.suggestions = {}
	self.suggestIndex = 0
	self._folderId = Data:GetRootId()

	local bar = CreateFrame("Frame", nil, hostFrame, "BackdropTemplate")
	bar:SetPoint("TOPLEFT", hostFrame, "TOPLEFT", 0, 0)
	bar:SetPoint("BOTTOMRIGHT", hostFrame, "BOTTOMRIGHT", 0, 0)
	bar:SetBackdrop({
		bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 16,
		edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	bar:SetBackdropColor(0.08, 0.08, 0.08, 0.9)
	bar:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
	bar:EnableMouse(true)
	bar:SetScript("OnMouseDown", function()
		if not self.editing then
			self:EnterEditMode()
		end
	end)
	self.bar = bar

	-- Breadcrumb container (click-through to bar except on labels).
	local crumbs = CreateFrame("Frame", nil, bar)
	crumbs:SetPoint("TOPLEFT", bar, "TOPLEFT", 8, -4)
	crumbs:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -8, 4)
	crumbs:EnableMouse(false)
	self.crumbs = crumbs
	self.crumbButtons = {}

	-- Path edit box (hidden until edit mode).
	local edit = CreateFrame("EditBox", "ScriptoriumAddressEditBox", bar, "InputBoxTemplate")
	edit:SetPoint("TOPLEFT", bar, "TOPLEFT", 8, -4)
	edit:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -8, 4)
	edit:SetFontObject(ChatFontNormal)
	edit:SetAutoFocus(false)
	edit:SetMaxLetters(512)
	edit:SetTextInsets(2, 20, 3, 3)
	edit:Hide()
	-- Never let keystrokes reach action binds while typing in the path bar.
	if edit.SetPropagateKeyboardInput then
		edit:SetPropagateKeyboardInput(false)
	end
	edit:SetScript("OnEditFocusGained", function(box)
		self.editing = true
		if box.SetPropagateKeyboardInput then
			box:SetPropagateKeyboardInput(false)
		end
	end)
	edit:SetScript("OnEditFocusLost", function(box)
		if box.SetPropagateKeyboardInput then
			box:SetPropagateKeyboardInput(false)
		end
		-- Defer so suggestion clicks can run first.
		C_Timer.After(0.05, function()
			if self.editing and edit and not edit:HasFocus() then
				-- Keep editing if suggestions still have mouse focus.
				if self.suggestFrame and self.suggestFrame:IsMouseOver() then
					return
				end
				self:ExitEditMode(true)
			end
		end)
	end)
	edit:SetScript("OnTextChanged", function(box, userInput)
		if self.suppressTextChanged or not userInput then
			return
		end
		self:ClearError()
		self:UpdateSuggestions(box:GetText() or "")
	end)
	edit:SetScript("OnEnterPressed", function(box)
		self:OnEnterPressed()
	end)
	edit:SetScript("OnEscapePressed", function()
		if self.suggestFrame and self.suggestFrame:IsShown() then
			self:HideSuggestions()
			return
		end
		self:ExitEditMode(true)
	end)
	edit:SetScript("OnTabPressed", function(box)
		if self.suggestFrame and self.suggestFrame:IsShown() and self.suggestIndex > 0 then
			self:ApplySuggestion(self.suggestIndex, false)
			return
		end
		if self.suggestFrame and self.suggestFrame:IsShown() and #self.suggestions > 0 then
			self:ApplySuggestion(1, false)
		end
	end)
	edit:SetScript("OnKeyDown", function(box, key)
		if box.SetPropagateKeyboardInput then
			box:SetPropagateKeyboardInput(false)
		end
		if key == "UP" then
			self:MoveSuggestion(-1)
		elseif key == "DOWN" then
			self:MoveSuggestion(1)
		end
	end)
	self.edit = edit

	-- Autocomplete popup.
	local suggest = CreateFrame("Frame", "ScriptoriumAddressSuggest", UIParent, "BackdropTemplate")
	suggest:SetFrameStrata("TOOLTIP")
	suggest:SetToplevel(true)
	suggest:SetBackdrop({
		bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 16,
		edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	suggest:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
	suggest:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
	suggest:EnableMouse(true)
	suggest:Hide()
	self.suggestFrame = suggest
	self.suggestButtons = {}

	hostFrame:HookScript("OnSizeChanged", function()
		self:LayoutCrumbs()
	end)

	self:ShowBreadcrumbs(self._folderId)
	return self
end

function AddressBar:Destroy()
	self:HideSuggestions()
	if self.suggestFrame then
		self.suggestFrame:Hide()
		self.suggestFrame:SetParent(nil)
		self.suggestFrame = nil
	end
	self.host = nil
	self.bar = nil
	self.crumbs = nil
	self.edit = nil
	self.crumbButtons = nil
	self.suggestButtons = nil
	self.editing = false
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

function AddressBar:SetFolder(folderId, force)
	folderId = folderId or Data:GetRootId()
	self._folderId = folderId
	if self.editing and not force then
		return
	end
	self:ShowBreadcrumbs(folderId)
end

function AddressBar:IsEditing()
	return self.editing
end

function AddressBar:EnterEditMode()
	if not self.bar or not self.edit then
		return
	end
	self.editing = true
	self:ClearError()
	self.crumbs:Hide()
	local path = Data:GetFolderSlashPath(self._folderId, false)
	self.suppressTextChanged = true
	self.edit:SetText(path)
	self.suppressTextChanged = false
	self.edit:Show()
	-- Don't open a full suggestion list until the user types.
	self.edit:SetFocus()
	self.edit:HighlightText()
	self:HideSuggestions()
end

--- @param cancel boolean when true, discard typed path and restore crumbs
function AddressBar:ExitEditMode(cancel)
	if not self.editing then
		return
	end
	self.editing = false
	self:HideSuggestions()
	self:ClearError()
	if self.edit then
		self.edit:ClearFocus()
		self.edit:Hide()
	end
	if self.crumbs then
		self.crumbs:Show()
	end
	self:ShowBreadcrumbs(self._folderId)
end

------------------------------------------------------------------------
-- Breadcrumbs
------------------------------------------------------------------------

function AddressBar:ShowBreadcrumbs(folderId)
	if not self.crumbs then
		return
	end
	self.editing = false
	if self.edit then
		self.edit:Hide()
	end
	self.crumbs:Show()
	self:ClearError()

	local segments = Data:GetFolderBreadcrumbs(folderId)
	local buttons = self.crumbButtons
	for _, btn in ipairs(buttons) do
		btn:Hide()
	end

	local x = 0
	local index = 0
	local function acquire()
		index = index + 1
		local btn = buttons[index]
		if not btn then
			btn = CreateFrame("Button", nil, self.crumbs)
			btn:SetHeight(18)
			btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			btn.label:SetPoint("LEFT", 0, 0)
			btn.label:SetJustifyH("LEFT")
			btn:SetFontString(btn.label)
			btn:SetNormalFontObject(GameFontHighlightSmall)
			btn:SetHighlightFontObject(GameFontNormalSmall)
			btn:SetScript("OnEnter", function(b)
				b.label:SetTextColor(1, 0.82, 0)
			end)
			btn:SetScript("OnLeave", function(b)
				if b.isCurrent then
					b.label:SetTextColor(1, 0.82, 0)
				else
					b.label:SetTextColor(0.9, 0.9, 0.9)
				end
			end)
			btn:SetScript("OnClick", function(b)
				if b.folderId then
					local owner = ui()
					if owner and owner.SelectFolder then
						owner:ExpandFolderPath(b.folderId)
						owner:SelectFolder(b.folderId)
					end
				end
			end)
			buttons[index] = btn
		end
		return btn
	end

	for i, seg in ipairs(segments) do
		if i > 1 then
			local sep = acquire()
			sep.folderId = nil
			sep.isCurrent = false
			sep:EnableMouse(false)
			sep.label:SetText(" > ")
			sep.label:SetTextColor(0.6, 0.6, 0.6)
			sep:SetWidth(sep.label:GetStringWidth() + 2)
			sep:ClearAllPoints()
			sep:SetPoint("LEFT", self.crumbs, "LEFT", x, 0)
			sep:Show()
			x = x + sep:GetWidth()
		end

		local btn = acquire()
		btn.folderId = seg.id
		btn.isCurrent = (i == #segments)
		btn:EnableMouse(true)
		btn.label:SetText(seg.name)
		if btn.isCurrent then
			btn.label:SetTextColor(1, 0.82, 0)
		else
			btn.label:SetTextColor(0.9, 0.9, 0.9)
		end
		btn:SetWidth(math.max(12, btn.label:GetStringWidth() + 2))
		btn:ClearAllPoints()
		btn:SetPoint("LEFT", self.crumbs, "LEFT", x, 0)
		btn:Show()
		x = x + btn:GetWidth()
	end

	self._crumbWidth = x
end

function AddressBar:LayoutCrumbs()
	if self.editing or not self.crumbs then
		return
	end
	-- Re-show to reflow if host width changed (truncation could be added later).
	if self._folderId then
		self:ShowBreadcrumbs(self._folderId)
	end
end

------------------------------------------------------------------------
-- Navigation / validation
------------------------------------------------------------------------

function AddressBar:ClearError()
	if self.bar then
		self.bar:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
	end
end

function AddressBar:SetError(message)
	if self.bar then
		self.bar:SetBackdropBorderColor(1, 0.25, 0.25, 1)
	end
	local owner = ui()
	if owner and owner.SetStatus and message then
		owner:SetStatus(message)
	end
end

function AddressBar:OnEnterPressed()
	if self.suggestFrame and self.suggestFrame:IsShown() and self.suggestIndex > 0 then
		self:ApplySuggestion(self.suggestIndex, true)
		return
	end
	self:NavigateToTypedPath()
end

function AddressBar:NavigateToTypedPath()
	local text = self.edit and self.edit:GetText() or ""
	local folderId = Data:ResolveFolderPath(text)
	if not folderId then
		self:SetError("Path not found.")
		self:HideSuggestions()
		if self.edit then
			self.edit:SetFocus()
		end
		return
	end
	local owner = ui()
	if owner then
		owner:ExpandFolderPath(folderId)
		owner:SelectFolder(folderId)
	end
	self._folderId = folderId
	self:ExitEditMode(false)
end

------------------------------------------------------------------------
-- Autocomplete
------------------------------------------------------------------------

function AddressBar:HideSuggestions()
	if self.suggestFrame then
		self.suggestFrame:Hide()
	end
	self.suggestions = {}
	self.suggestIndex = 0
end

function AddressBar:UpdateSuggestions(text)
	local suggestions = Data:GetPathCompletions(text, MAX_SUGGESTIONS)
	self.suggestions = suggestions
	self.suggestIndex = 0
	if not self.editing or #suggestions == 0 then
		self:HideSuggestions()
		return
	end
	self:ShowSuggestions(suggestions)
end

function AddressBar:ShowSuggestions(suggestions)
	local frame = self.suggestFrame
	local bar = self.bar
	if not frame or not bar then
		return
	end

	local buttons = self.suggestButtons
	for _, btn in ipairs(buttons) do
		btn:Hide()
	end

	local width = math.max(180, bar:GetWidth() or 200)
	frame:SetWidth(width)
	frame:ClearAllPoints()
	frame:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -2)

	for i, item in ipairs(suggestions) do
		local btn = buttons[i]
		if not btn then
			btn = CreateFrame("Button", nil, frame)
			btn:SetHeight(SUGGEST_ROW_HEIGHT)
			btn:SetPoint("LEFT", 4, 0)
			btn:SetPoint("RIGHT", -4, 0)
			btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			btn.label:SetPoint("LEFT", 4, 0)
			btn.label:SetPoint("RIGHT", -4, 0)
			btn.label:SetJustifyH("LEFT")
			btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
			btn:SetScript("OnClick", function(b)
				if b.index then
					self:ApplySuggestion(b.index, true)
				end
			end)
			btn:SetScript("OnEnter", function(b)
				self.suggestIndex = b.index or 0
				self:HighlightSuggestion()
			end)
			buttons[i] = btn
		end
		btn.index = i
		btn.item = item
		btn.label:SetText(item.path)
		btn:ClearAllPoints()
		btn:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -4 - (i - 1) * SUGGEST_ROW_HEIGHT)
		btn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4 - (i - 1) * SUGGEST_ROW_HEIGHT)
		btn:Show()
	end

	frame:SetHeight(8 + #suggestions * SUGGEST_ROW_HEIGHT)
	frame:Show()
	if Compat.RaiseFrame then
		-- RaiseFrame also re-centers; only bump strata/level here.
		frame:SetFrameStrata("TOOLTIP")
		frame:SetToplevel(true)
		local level = 200
		local owner = ui()
		if owner and owner.frame and owner.frame.frame then
			level = owner.frame.frame:GetFrameLevel() + 50
		end
		frame:SetFrameLevel(level)
	end
	self:HighlightSuggestion()
end

function AddressBar:HighlightSuggestion()
	for i, btn in ipairs(self.suggestButtons or {}) do
		if btn:IsShown() then
			if i == self.suggestIndex then
				btn:LockHighlight()
				btn.label:SetTextColor(1, 0.82, 0)
			else
				btn:UnlockHighlight()
				btn.label:SetTextColor(1, 1, 1)
			end
		end
	end
end

function AddressBar:MoveSuggestion(delta)
	if not self.suggestFrame or not self.suggestFrame:IsShown() or #self.suggestions == 0 then
		return
	end
	local n = #self.suggestions
	if self.suggestIndex == 0 then
		self.suggestIndex = delta > 0 and 1 or n
	else
		self.suggestIndex = self.suggestIndex + delta
		if self.suggestIndex < 1 then
			self.suggestIndex = n
		elseif self.suggestIndex > n then
			self.suggestIndex = 1
		end
	end
	self:HighlightSuggestion()
end

--- @param navigate boolean when true, navigate to the suggestion folder
function AddressBar:ApplySuggestion(index, navigate)
	local item = self.suggestions and self.suggestions[index]
	if not item then
		return
	end
	self.suppressTextChanged = true
	if self.edit then
		self.edit:SetText(item.path)
		self.edit:SetCursorPosition(#item.path)
	end
	self.suppressTextChanged = false
	self:HideSuggestions()
	if navigate then
		local owner = ui()
		if owner then
			owner:ExpandFolderPath(item.folderId)
			owner:SelectFolder(item.folderId)
		end
		self._folderId = item.folderId
		self:ExitEditMode(false)
	else
		self:UpdateSuggestions(item.path)
		if self.edit then
			self.edit:SetFocus()
		end
	end
end

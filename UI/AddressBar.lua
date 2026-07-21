--- UI/AddressBar.lua
--- Single text-box address bar: breadcrumb display when idle, slash path when editing.
local ADDON_NAME, ns = ...

local Data = ns.Data
local Compat = ns.Compat

local AddressBar = {}
ns.AddressBar = AddressBar

local MAX_SUGGESTIONS = 10
local SUGGEST_ROW_HEIGHT = 18

local function ui()
	return ns.UI
end

------------------------------------------------------------------------
-- Construction
------------------------------------------------------------------------

--- Create the address bar; alignment is applied by UI:AlignAddressWithSearch.
--- @param hostWidget AceGUI SimpleGroup (kept for API compat; bar is reparented)
function AddressBar:Create(hostWidget)
	if self.bar then
		self:Destroy()
	end

	self.host = hostWidget
	self.editing = false
	self.suppressTextChanged = false
	self.suggestions = {}
	self.suggestIndex = 0
	self._folderId = Data:GetRootId()

	local parent = (hostWidget and (hostWidget.content or hostWidget.frame)) or UIParent
	local bar = CreateFrame("Frame", nil, parent, "BackdropTemplate")
	bar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
	bar:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
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
	self.bar = bar

	-- Colored breadcrumb display (EditBoxes cannot mix text colors).
	local display = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	display:SetPoint("LEFT", bar, "LEFT", 10, 0)
	display:SetPoint("RIGHT", bar, "RIGHT", -10, 0)
	display:SetJustifyH("LEFT")
	display:SetWordWrap(false)
	if display.SetMaxLines then
		display:SetMaxLines(1)
	end
	self.display = display

	-- Invisible hit target so clicks on the breadcrumb enter edit mode.
	local hit = CreateFrame("Button", nil, bar)
	hit:SetAllPoints(bar)
	hit:SetScript("OnClick", function()
		self:EnterEditMode()
	end)
	self.hit = hit

	-- Edit box used only while focused (unnamed to avoid reuse conflicts).
	local edit = CreateFrame("EditBox", nil, bar)
	edit:SetPoint("TOPLEFT", bar, "TOPLEFT", 8, -4)
	edit:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -8, 4)
	edit:SetFontObject(GameFontHighlightSmall)
	edit:SetAutoFocus(false)
	edit:SetMaxLetters(512)
	edit:SetTextInsets(2, 2, 0, 0)
	edit:SetTextColor(1, 1, 1)
	edit:Hide()
	if edit.SetPropagateKeyboardInput then
		edit:SetPropagateKeyboardInput(false)
	end

	edit:SetScript("OnEditFocusGained", function(box)
		if box.SetPropagateKeyboardInput then
			box:SetPropagateKeyboardInput(false)
		end
		if not self.editing then
			self:EnterEditMode()
		end
	end)
	edit:SetScript("OnEditFocusLost", function(box)
		C_Timer.After(0.05, function()
			if self.editing and edit and not edit:HasFocus() then
				if self.suggestFrame and self.suggestFrame:IsMouseOver() then
					return
				end
				self:ExitEditMode(true)
			end
		end)
	end)
	edit:SetScript("OnTextChanged", function(box, userInput)
		if self.suppressTextChanged or not userInput or not self.editing then
			return
		end
		self:ClearError()
		self:UpdateSuggestions(box:GetText() or "")
	end)
	edit:SetScript("OnEnterPressed", function()
		self:OnEnterPressed()
	end)
	edit:SetScript("OnEscapePressed", function()
		if self.suggestFrame and self.suggestFrame:IsShown() then
			self:HideSuggestions()
			return
		end
		self:ExitEditMode(true)
	end)
	edit:SetScript("OnTabPressed", function()
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

	self:ShowDisplayPath(self._folderId)
	return self
end

function AddressBar:Destroy()
	self:HideSuggestions()
	if self.suggestFrame then
		self.suggestFrame:Hide()
		self.suggestFrame:SetParent(nil)
		self.suggestFrame = nil
	end
	if self.bar then
		self.bar:Hide()
		self.bar:SetParent(nil)
		self.bar:ClearAllPoints()
		self.bar = nil
	end
	self.host = nil
	self.display = nil
	self.hit = nil
	self.edit = nil
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
	self.editing = false
	self:HideSuggestions()
	self:ClearError()
	self:ShowDisplayPath(folderId)
end

function AddressBar:IsEditing()
	return self.editing
end

local function ColoredBreadcrumbText(folderId)
	local segments = Data:GetFolderBreadcrumbs(folderId)
	if #segments == 0 then
		return ""
	end
	local parts = {}
	for i, seg in ipairs(segments) do
		if i > 1 then
			parts[#parts + 1] = "|cff999999 > |r"
		end
		if i == #segments then
			parts[#parts + 1] = "|cffffd100" .. seg.name .. "|r"
		else
			parts[#parts + 1] = "|cffffffff" .. seg.name .. "|r"
		end
	end
	return table.concat(parts)
end

--- Idle display: white ancestors, yellow current folder.
function AddressBar:ShowDisplayPath(folderId)
	folderId = folderId or self._folderId
	if self.display then
		self.display:SetText(ColoredBreadcrumbText(folderId))
		self.display:Show()
	end
	if self.hit then
		self.hit:Show()
	end
	if self.edit then
		self.suppressTextChanged = true
		self.edit:SetText("")
		self.edit:ClearFocus()
		self.edit:Hide()
		self.suppressTextChanged = false
	end
end

--- Focused edit: slash path in a plain text box (root name omitted).
function AddressBar:EnterEditMode()
	if not self.edit then
		return
	end
	self.editing = true
	self:ClearError()
	if self.display then
		self.display:Hide()
	end
	if self.hit then
		self.hit:Hide()
	end
	local path = Data:GetFolderSlashPath(self._folderId, false)
	self.suppressTextChanged = true
	self.edit:SetText(path)
	self.edit:SetTextColor(1, 1, 1)
	self.edit:Show()
	self.suppressTextChanged = false
	self.edit:SetFocus()
	self.edit:SetCursorPosition(#path)
	self:UpdateSuggestions(path)
end

--- @param cancel boolean when true, discard typed path and restore display
function AddressBar:ExitEditMode(cancel)
	if not self.editing then
		self:ShowDisplayPath(self._folderId)
		return
	end
	self.editing = false
	self:HideSuggestions()
	self:ClearError()
	self:ShowDisplayPath(self._folderId)
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
	-- Allow either slash paths or " > " display paths.
	local normalized = text:gsub("%s*>%s*", "/")
	local folderId = Data:ResolveFolderPath(normalized)
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
	frame:SetFrameStrata("TOOLTIP")
	frame:SetToplevel(true)
	local level = 200
	local owner = ui()
	if owner and owner.frame and owner.frame.frame then
		level = owner.frame.frame:GetFrameLevel() + 50
	end
	frame:SetFrameLevel(level)
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

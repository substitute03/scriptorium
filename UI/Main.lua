--- UI/Main.lua
--- Read-only macro browser: folder tree | macro list | macro viewer.
--- Blizzard macros are the source of truth; this UI mirrors and exports them.
local ADDON_NAME, ns = ...

local AceGUI = LibStub("AceGUI-3.0")
local Data = ns.Data
local Search = ns.Search
local MacroBridge = ns.MacroBridge
local Compat = ns.Compat
local AddressBar = ns.AddressBar

local UI = {}
ns.UI = UI

local function addon()
	return ns.Addon
end

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------

UI.selectedFolderId = nil
UI.selectedEntryId = nil
UI.searchQuery = ""
UI.statusText = ""

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

function UI:SetStatus(text)
	self.statusText = text or ""
	if self.frame then
		self.frame:SetStatusText(self.statusText)
	end
end

function UI:LoadMacroIntoViewer(entry)
	self.currentIcon = entry and Compat.NormalizeIcon(entry.icon) or Compat.DefaultIcon()
	self._suppressReadOnlyGuard = true
	self._lockedName = entry and entry.name or ""
	self._lockedBody = entry and entry.text or ""
	local hasMacro = entry ~= nil
	if self.nameEdit then
		self.nameEdit:SetText(self._lockedName)
		self:ApplyReadOnlyAppearance(self.nameEdit, hasMacro)
	end
	if self.bodyEdit then
		self.bodyEdit:SetText(self._lockedBody)
		self:ApplyReadOnlyAppearance(self.bodyEdit, hasMacro)
	end
	self._suppressReadOnlyGuard = false
	if self.iconWidget then
		self.iconWidget:SetImage(Compat.GetIconTexture(self.currentIcon))
		if self.iconWidget.SetDisabled then
			self.iconWidget:SetDisabled(not hasMacro)
		elseif self.iconWidget.image then
			if hasMacro then
				self.iconWidget.image:SetVertexColor(1, 1, 1)
			else
				self.iconWidget.image:SetVertexColor(0.5, 0.5, 0.5)
			end
		end
	end
	if self.macroButton then
		self.macroButton:SetDisabled(not hasMacro)
	end
end

--- Read-only fields: white + selectable when a macro is selected; greyed out otherwise.
function UI:ApplyReadOnlyAppearance(widget, active)
	if not widget then
		return
	end
	-- Do not use AceGUI SetDisabled for the active state — that blocks selection/copy.
	if widget.SetDisabled then
		widget:SetDisabled(false)
	end
	local editBox = widget.editbox or widget.editBox
	if editBox then
		if active then
			editBox:EnableMouse(true)
			if editBox.EnableKeyboard then
				editBox:EnableKeyboard(true)
			end
			editBox:SetTextColor(1, 1, 1)
		else
			editBox:ClearFocus()
			editBox:EnableMouse(false)
			if editBox.EnableKeyboard then
				editBox:EnableKeyboard(false)
			end
			editBox:SetTextColor(0.5, 0.5, 0.5)
		end
	end
	if widget.label then
		if active then
			widget.label:SetTextColor(1, 0.82, 0)
		else
			widget.label:SetTextColor(0.5, 0.5, 0.5)
		end
	end
	local scrollFrame = widget.scrollFrame
	if scrollFrame then
		scrollFrame:EnableMouse(active and true or false)
		scrollFrame:EnableMouseWheel(active and true or false)
	end
end

function UI:SetupReadOnlyFields()
	local nameEdit = self.nameEdit
	if nameEdit then
		if nameEdit.DisableButton then
			nameEdit:DisableButton(true)
		end
		self:ApplyReadOnlyAppearance(nameEdit, false)
		nameEdit:SetCallback("OnTextChanged", function(_, _, value)
			if self._suppressReadOnlyGuard then
				return
			end
			local locked = self._lockedName or ""
			if tostring(value or "") ~= locked then
				self._suppressReadOnlyGuard = true
				nameEdit:SetText(locked)
				self._suppressReadOnlyGuard = false
			end
		end)
	end

	local body = self.bodyEdit
	if body then
		body:DisableButton(true)
		self:ApplyReadOnlyAppearance(body, false)

		-- Allow click-to-focus/select when active, but block drag-insert of spells/items.
		local editBox = body.editBox
		if editBox then
			editBox:SetScript("OnMouseDown", nil)
			editBox:SetScript("OnReceiveDrag", nil)
			editBox:SetScript("OnTextChanged", function(eb, userInput)
				if self._suppressReadOnlyGuard or not userInput then
					return
				end
				local locked = self._lockedBody or ""
				if eb:GetText() ~= locked then
					self._suppressReadOnlyGuard = true
					local cursor = eb:GetCursorPosition()
					eb:SetText(locked)
					eb:SetCursorPosition(math.min(cursor or 0, #locked))
					self._suppressReadOnlyGuard = false
				end
			end)
		end

		local scrollFrame = body.scrollFrame
		if scrollFrame then
			scrollFrame:SetScript("OnReceiveDrag", nil)
			-- Keep AceGUI focus-on-click so the user can select text to copy when active.
			scrollFrame:SetScript("OnMouseUp", function(sf)
				if not self.selectedEntryId then
					return
				end
				local eb = sf.obj and sf.obj.editBox
				if eb then
					eb:SetFocus()
				end
			end)
		end
	end
end

------------------------------------------------------------------------
-- Selection
------------------------------------------------------------------------

function UI:SelectFolder(folderId)
	self.selectedFolderId = folderId or Data:GetRootId()
	self.selectedEntryId = nil
	self.searchQuery = self.searchEdit and self.searchEdit:GetText() or self.searchQuery
	self:LoadMacroIntoViewer(nil)
	self:RefreshTreeSelection()
	self:RefreshList()
	if AddressBar and AddressBar.SetFolder then
		AddressBar:SetFolder(self.selectedFolderId, true)
	end
end

function UI:ExpandFolderPath(folderId)
	if not folderId then
		return
	end
	local pathParts = {}
	local walk = folderId
	while walk do
		table.insert(pathParts, 1, walk)
		local folder = Data:GetFolder(walk)
		walk = folder and folder.parentId
	end
	self._userExpanded = self._userExpanded or {}
	for i = 1, #pathParts - 1 do
		self._userExpanded[table.concat(pathParts, "\001", 1, i)] = true
	end
end

function UI:SelectEntry(entryId)
	local entry = Data:GetEntry(entryId)
	if not entry then
		return
	end
	self.selectedEntryId = entryId
	self.selectedFolderId = entry.parentId
	self:LoadMacroIntoViewer(entry)
	self:RefreshTreeSelection()
	self:RefreshList()
	if AddressBar and AddressBar.SetFolder then
		AddressBar:SetFolder(self.selectedFolderId, true)
	end
end

------------------------------------------------------------------------
-- Refresh
------------------------------------------------------------------------

function UI:RefreshAll()
	self:RefreshTree()
	self:RefreshList()
	if AddressBar and AddressBar.SetFolder then
		AddressBar:SetFolder(self.selectedFolderId or Data:GetRootId(), true)
	end
	if self.selectedEntryId then
		local entry = Data:GetEntry(self.selectedEntryId)
		if entry then
			self:LoadMacroIntoViewer(entry)
		else
			self.selectedEntryId = nil
			self:LoadMacroIntoViewer(nil)
		end
	end
end

function UI:RefreshTree()
	if not self.treeGroup then
		return
	end
	self.treeGroup:SetTree(Data:BuildTree())
	self:RefreshTreeSelection()
	self:DecorateTreeRows()
end

function UI:ToggleFolderExpanded(uniquevalue)
	if not uniquevalue or not self.treeGroup then
		return
	end
	local status = (self.treeGroup.status or self.treeGroup.localstatus).groups
	local nowExpanded = not status[uniquevalue]
	status[uniquevalue] = nowExpanded or nil
	self._userExpanded = self._userExpanded or {}
	-- Store false (not nil) so a collapsed root is not re-opened as the default.
	self._userExpanded[uniquevalue] = nowExpanded and true or false
	self.treeGroup:RefreshTree()
end

local function SetTruncatedFolderLabel(fontString, folder, maxWidth)
	if not fontString or not folder then
		return false
	end
	local isRoot = folder.id == Data:GetRootId()
	local isLeaf = #(folder.children or {}) == 0
	local entryCount = 0
	if isLeaf and not isRoot then
		for _, entryId in ipairs(folder.entries or {}) do
			if Data:GetEntry(entryId) then
				entryCount = entryCount + 1
			end
		end
	end

	local function makeLabel(name)
		if isRoot then
			return "|cffffd100" .. name .. "|r"
		end
		if isLeaf then
			return string.format("%s (%d)", name, entryCount)
		end
		return name
	end

	local fullName = folder.name or ""
	fontString:SetText(makeLabel(fullName))
	if maxWidth <= 0 then
		return true
	end
	if (fontString:GetStringWidth() or 0) <= maxWidth then
		return false
	end

	local ellipsis = "…"
	fontString:SetText(makeLabel(ellipsis))
	if (fontString:GetStringWidth() or 0) > maxWidth then
		fontString:SetText(ellipsis)
		return true
	end

	local lo, hi = 0, #fullName
	while lo < hi do
		local mid = math.floor((lo + hi + 1) / 2)
		fontString:SetText(makeLabel(fullName:sub(1, mid) .. ellipsis))
		if (fontString:GetStringWidth() or 0) <= maxWidth then
			lo = mid
		else
			hi = mid - 1
		end
	end
	fontString:SetText(makeLabel(fullName:sub(1, lo) .. ellipsis))
	return true
end

local function LayoutTreeFolderLabel(button, textLeft)
	local fs = button.text
	if not fs then
		return
	end
	fs:ClearAllPoints()
	fs:SetPoint("LEFT", button, "LEFT", textLeft, 0)
	fs:SetPoint("RIGHT", button, "RIGHT", -4, 0)
	fs:SetJustifyH("LEFT")
	fs:SetJustifyV("MIDDLE")
	if fs.SetWordWrap then
		fs:SetWordWrap(false)
	end
	if fs.SetNonSpaceWrap then
		fs:SetNonSpaceWrap(false)
	end
	if fs.SetMaxLines then
		fs:SetMaxLines(1)
	end

	local folder = Data:GetFolder(button.value)
	button._scriptoriumFullName = folder and folder.name or nil
	local maxWidth = fs:GetWidth() or 0
	if maxWidth < 1 and button.GetWidth then
		maxWidth = math.max(0, (button:GetWidth() or 0) - textLeft - 4)
	end
	button._scriptoriumLabelTruncated = SetTruncatedFolderLabel(fs, folder, maxWidth)
end

local TREE_WIDTH_MIN = 160
local TREE_WIDTH_MAX = 600
local TREE_WIDTH_DEFAULT = 320

local function ApplyTreeWidth(tree, width)
	width = math.max(TREE_WIDTH_MIN, math.min(TREE_WIDTH_MAX, width or TREE_WIDTH_MIN))
	if not tree or not tree.treeframe then
		return width
	end
	tree.treeframe:SetWidth(width)
	local status = tree.status or tree.localstatus
	if status then
		status.treewidth = width
		if status.fullwidth then
			tree:OnWidthSet(status.fullwidth)
		end
	end
	tree:DoLayout()
	return width
end

function UI:EnsureTreeDragger()
	local tree = self.treeGroup
	if not tree or not tree.treeframe or not tree.frame then
		return
	end

	if tree.dragger then
		tree.dragger:EnableMouse(false)
		tree.dragger:Hide()
	end
	if tree.SetTreeWidth then
		local status = tree.status or tree.localstatus
		if status then
			status.treesizable = false
		end
	end

	local splitter = self._treeSplitter
	if not splitter then
		splitter = CreateFrame("Frame", nil, tree.frame, "BackdropTemplate")
		splitter:SetWidth(10)
		splitter:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			tile = true,
			tileSize = 16,
			insets = { left = 3, right = 3, top = 7, bottom = 7 },
		})
		splitter:SetBackdropColor(1, 1, 1, 0)
		splitter:EnableMouse(true)
		self._treeSplitter = splitter
	end

	splitter:SetParent(tree.frame)
	splitter:ClearAllPoints()
	splitter:SetPoint("TOPLEFT", tree.treeframe, "TOPRIGHT", -5, -2)
	splitter:SetPoint("BOTTOMLEFT", tree.treeframe, "BOTTOMRIGHT", -5, 2)
	splitter:SetFrameStrata(tree.frame:GetFrameStrata() or "FULLSCREEN_DIALOG")
	splitter:SetFrameLevel((tree.frame:GetFrameLevel() or 0) + 200)
	splitter:Show()

	splitter:SetScript("OnEnter", function(frame)
		if not frame.isDragging then
			frame:SetBackdropColor(1, 1, 1, 0.85)
		end
	end)
	splitter:SetScript("OnLeave", function(frame)
		if not frame.isDragging then
			frame:SetBackdropColor(1, 1, 1, 0)
		end
	end)
	splitter:SetScript("OnMouseDown", function(frame, button)
		if button ~= "LeftButton" then
			return
		end
		frame.isDragging = true
		frame:SetBackdropColor(1, 1, 1, 0.85)
		frame:SetScript("OnUpdate", function(self)
			if not IsMouseButtonDown("LeftButton") then
				self.isDragging = nil
				self:SetScript("OnUpdate", nil)
				self:SetBackdropColor(1, 1, 1, 0)
				UI:ForceLayout()
				UI:DecorateTreeRows()
				UI:EnsureTreeDragger()
				UI:EnsureContentsDragger()
				return
			end
			local left = tree.treeframe:GetLeft()
			if not left then
				return
			end
			local cursorX = GetCursorPosition() / tree.treeframe:GetEffectiveScale()
			ApplyTreeWidth(tree, cursorX - left)
			UI:ForceLayout()
			UI:EnsureContentsDragger()
		end)
	end)
	splitter:SetScript("OnMouseUp", function(frame, button)
		if button ~= "LeftButton" or not frame.isDragging then
			return
		end
		frame.isDragging = nil
		frame:SetScript("OnUpdate", nil)
		frame:SetBackdropColor(1, 1, 1, 0)
		UI:ForceLayout()
		UI:DecorateTreeRows()
		UI:EnsureTreeDragger()
		UI:EnsureContentsDragger()
	end)
end

local CONTENTS_WIDTH_MIN = 180
local ENTRY_WIDTH_MIN = 260

function UI:LayoutNavRow()
	if not self.navRow or not self.addressCol or not self.searchCol then
		return
	end
	local total = self.navRow.frame and self.navRow.frame:GetWidth() or 0
	if total < 50 then
		return
	end
	local searchW = 220
	local gap = 16
	local addressW = math.max(120, total - searchW - gap)
	self.addressCol:SetWidth(addressW)
	self.searchCol:SetWidth(searchW)
	if self.searchEdit then
		self.searchEdit:SetWidth(searchW)
	end
	self:AlignAddressWithSearch()
end

function UI:AlignAddressWithSearch()
	local host = self.addressHost and self.addressHost.frame
	local edit = self.searchEdit and self.searchEdit.editbox
	local col = self.addressCol and self.addressCol.frame
	if not host or not edit or not col then
		return
	end
	host:ClearAllPoints()
	host:SetPoint("LEFT", col, "LEFT", 0, 0)
	host:SetPoint("RIGHT", col, "RIGHT", 0, 0)
	host:SetPoint("TOP", edit, "TOP", 0, 0)
	host:SetPoint("BOTTOM", edit, "BOTTOM", 0, 0)
end

function UI:LayoutBodyHeight()
	local shell = self.shellGroup
	local nav = self.navRow
	local body = self.bodyGroup
	if not shell or not nav or not body or not shell.frame then
		return
	end
	local shellH = shell.frame:GetHeight() or 0
	local optionsH = (self.optionsRow and self.optionsRow.frame and self.optionsRow.frame:GetHeight()) or (self.optionsRowHeight or 0)
	local navH = (nav.frame and nav.frame:GetHeight()) or 44
	local gapH = self.navBottomGapHeight or 2
	local height = math.max(120, shellH - optionsH - navH - gapH - 6)
	body:SetHeight(height)
	if body.DoLayout then
		body:DoLayout()
	end
end

function UI:SyncPaneWidths()
	local list = self.listContainer
	local detail = self.detailContainer
	local content = self.contentGroup
	if not list or not detail or not content then
		return
	end
	local parent = content.content or content.frame
	if not parent or not parent.GetWidth then
		return
	end
	local total = parent:GetWidth() or 0
	if total < (CONTENTS_WIDTH_MIN + ENTRY_WIDTH_MIN + 8) then
		return
	end

	local gap = 4
	local maxList = total - ENTRY_WIDTH_MIN - gap
	local listW = self._contentsWidth or (total * 0.44)
	listW = math.max(CONTENTS_WIDTH_MIN, math.min(maxList, listW))
	self._contentsWidth = listW

	list:SetWidth(listW)
	detail:SetWidth(total - listW - gap)
	if content.DoLayout then
		content:DoLayout()
	end
	self:LayoutNavRow()
	self:LayoutBodyHeight()
end

function UI:EnsureContentsDragger()
	local list = self.listContainer
	local host = self.frame and self.frame.frame
	if not list or not list.frame or not host then
		return
	end

	local splitter = self._contentsSplitter
	if not splitter then
		splitter = CreateFrame("Frame", nil, host, "BackdropTemplate")
		splitter:SetWidth(10)
		splitter:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			tile = true,
			tileSize = 16,
			insets = { left = 3, right = 3, top = 7, bottom = 7 },
		})
		splitter:SetBackdropColor(1, 1, 1, 0)
		splitter:EnableMouse(true)
		self._contentsSplitter = splitter
	end

	splitter:SetParent(host)
	splitter:ClearAllPoints()
	splitter:SetPoint("TOPLEFT", list.frame, "TOPRIGHT", -5, 0)
	splitter:SetPoint("BOTTOMLEFT", list.frame, "BOTTOMRIGHT", -5, 0)
	splitter:SetFrameStrata(host:GetFrameStrata() or "FULLSCREEN_DIALOG")
	splitter:SetFrameLevel((host:GetFrameLevel() or 0) + 200)
	splitter:Show()

	splitter:SetScript("OnEnter", function(frame)
		if not frame.isDragging then
			frame:SetBackdropColor(1, 1, 1, 0.85)
		end
	end)
	splitter:SetScript("OnLeave", function(frame)
		if not frame.isDragging then
			frame:SetBackdropColor(1, 1, 1, 0)
		end
	end)
	splitter:SetScript("OnMouseDown", function(frame, button)
		if button ~= "LeftButton" then
			return
		end
		frame.isDragging = true
		frame:SetBackdropColor(1, 1, 1, 0.85)
		frame:SetScript("OnUpdate", function(self)
			if not IsMouseButtonDown("LeftButton") then
				self.isDragging = nil
				self:SetScript("OnUpdate", nil)
				self:SetBackdropColor(1, 1, 1, 0)
				UI:SyncPaneWidths()
				UI:ForceLayout()
				UI:EnsureContentsDragger()
				return
			end
			local left = list.frame:GetLeft()
			if not left then
				return
			end
			local cursorX = GetCursorPosition() / list.frame:GetEffectiveScale()
			UI._contentsWidth = cursorX - left
			UI:SyncPaneWidths()
			UI:EnsureContentsDragger()
		end)
	end)
	splitter:SetScript("OnMouseUp", function(frame, button)
		if button ~= "LeftButton" or not frame.isDragging then
			return
		end
		frame.isDragging = nil
		frame:SetScript("OnUpdate", nil)
		frame:SetBackdropColor(1, 1, 1, 0)
		UI:SyncPaneWidths()
		UI:ForceLayout()
		UI:EnsureContentsDragger()
	end)
end

local function ShowFolderTooltip(btn)
	local fullName = btn._scriptoriumFullName
	if not fullName or fullName == "" then
		local folder = btn.value and Data:GetFolder(btn.value)
		fullName = folder and folder.name
	end
	if not fullName then
		return
	end
	local tip = AceGUI.tooltip
	tip:SetOwner(btn, "ANCHOR_NONE")
	tip:ClearAllPoints()
	tip:SetPoint("LEFT", btn, "RIGHT", 4, 0)
	tip:SetText(fullName, 1, 0.82, 0, true)
	tip:Show()
end

local function HideFolderTooltip()
	if AceGUI.tooltip then
		AceGUI.tooltip:Hide()
	end
	GameTooltip:Hide()
end

function UI:DecorateTreeRows()
	local tree = self.treeGroup
	if not tree or not tree.buttons then
		return
	end
	local groupstatus = (tree.status or tree.localstatus).groups
	for _, button in ipairs(tree.buttons) do
		if button:IsShown() and button.value and not button._scriptoriumMenuHooked then
			button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
			local origOnClick = button:GetScript("OnClick")
			button:SetScript("OnClick", function(btn, mouseButton, ...)
				if mouseButton == "RightButton" then
					local folderId = btn.value
					if folderId then
						if folderId ~= self.selectedFolderId then
							self.selectedFolderId = folderId
							self.selectedEntryId = nil
							self:LoadMacroIntoViewer(nil)
							self:RefreshTreeSelection()
							self:RefreshList()
						end
						self:ShowFolderContextMenu(btn, folderId)
					end
					return
				end
				if origOnClick then
					origOnClick(btn, mouseButton, ...)
				end
				if btn.uniquevalue then
					self:RefreshTreeSelection()
				end
			end)
			button:SetScript("OnDoubleClick", function() end)
			button._scriptoriumMenuHooked = true
		end

		if button:IsShown() then
			button:SetScript("OnDoubleClick", function() end)
		end

		if button:IsShown() and button.value then
			if button.SetPushedTextOffset then
				button:SetPushedTextOffset(0, 0)
			end
			if button.SetClipsChildren then
				button:SetClipsChildren(true)
			end
			if not button._scriptoriumTipHooked then
				button:HookScript("OnEnter", function(btn)
					ShowFolderTooltip(btn)
				end)
				button:HookScript("OnLeave", function()
					HideFolderTooltip()
				end)
				button._scriptoriumTipHooked = true
			end
		end

		if button.toggle then
			button.toggle:SetScript("OnClick", nil)
			button.toggle:EnableMouse(false)
			button.toggle:Hide()
			button.toggle:SetAlpha(0)
		end

		local chevron = button._scriptoriumChevronBtn

		if button:IsShown() and button.value then
			local level = button.level or 1
			local levelIndent = (level == 1 and 8 or (8 * level))
			-- Nudge character folders in a bit further under their realm.
			if Data:IsCharacterFolder(button.value) then
				levelIndent = levelIndent + 10
			end
			local hasIcon = button.icon and button.icon:GetTexture()
			local hasChildren = button.treeline and button.treeline.hasChildren
			local chevronSize = 18
			local chevronGap = 2
			local iconSize = 14
			local iconGap = 2
			local textLeft

			local font = (level == 1) and GameFontNormal or GameFontHighlightSmall
			button:SetNormalFontObject(font)
			button:SetHighlightFontObject(font)
			if button.text and button.text.SetFontObject then
				button.text:SetFontObject(font)
			end

			if hasChildren then
				if not chevron then
					chevron = CreateFrame("Button", nil, button)
					chevron:SetSize(chevronSize, chevronSize)
					chevron:SetFrameLevel(button:GetFrameLevel() + 6)
					chevron:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight")
					chevron:SetScript("OnClick", function(btn)
						if btn.uniquevalue then
							self:ToggleFolderExpanded(btn.uniquevalue)
						end
					end)
					button._scriptoriumChevronBtn = chevron
				end
				chevron.uniquevalue = button.uniquevalue
				chevron:SetSize(chevronSize, chevronSize)
				local expanded = groupstatus and groupstatus[button.uniquevalue]
				chevron:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up")
				chevron:SetPushedTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Down")
				local rotation = expanded and math.rad(-90) or 0
				local normal = chevron:GetNormalTexture()
				if normal and normal.SetRotation then
					normal:SetRotation(rotation)
				end
				local pushed = chevron:GetPushedTexture()
				if pushed and pushed.SetRotation then
					pushed:SetRotation(rotation)
				end
				chevron:ClearAllPoints()
				chevron:SetPoint("LEFT", button, "LEFT", levelIndent, 0)
				chevron:Show()
				textLeft = levelIndent + chevronSize + chevronGap
			else
				if chevron then
					chevron:Hide()
				end
				if hasIcon then
					button.icon:ClearAllPoints()
					button.icon:SetSize(iconSize, iconSize)
					button.icon:SetPoint("LEFT", button, "LEFT", levelIndent, 0)
					textLeft = levelIndent + iconSize + iconGap
				else
					textLeft = levelIndent + chevronSize + chevronGap
				end
			end

			LayoutTreeFolderLabel(button, textLeft)
		else
			if chevron then
				chevron:Hide()
			end
			button._scriptoriumLabelTruncated = nil
		end
	end
end

function UI:RefreshTreeSelection()
	if not self.treeGroup or not self.selectedFolderId then
		return
	end
	local pathParts = {}
	local id = self.selectedFolderId
	while id do
		table.insert(pathParts, 1, id)
		local folder = Data:GetFolder(id)
		id = folder and folder.parentId
	end
	local unique = table.concat(pathParts, "\001")
	local status = self.treeGroup.status or self.treeGroup.localstatus
	if not status then
		return
	end
	status.groups = status.groups or {}

	-- Rebuild expand state: root (Macros) is expanded by default; other folders
	-- stay collapsed unless the user opened them or they lead to the selection.
	wipe(status.groups)
	local rootId = Data:GetRootId()
	self._userExpanded = self._userExpanded or {}
	if self._userExpanded[rootId] == nil then
		self._userExpanded[rootId] = true
	end

	for i = 1, #pathParts - 1 do
		status.groups[table.concat(pathParts, "\001", 1, i)] = true
	end
	for path, isOpen in pairs(self._userExpanded) do
		if isOpen then
			status.groups[path] = true
		end
	end
	status.selected = unique

	self._ignoreTreeSelect = true
	self.treeGroup:RefreshTree(true)
	self._ignoreTreeSelect = false
end

function UI:RefreshList()
	if not self.listGroup then
		return
	end
	self.listGroup:ReleaseChildren()

	local query = self.searchQuery and self.searchQuery:match("^%s*(.-)%s*$") or ""
	if query ~= "" then
		self:PopulateSearchResults(query)
		return
	end

	local folderId = self.selectedFolderId or Data:GetRootId()
	local isRoot = folderId == Data:GetRootId()

	if isRoot then
		local hint = AceGUI:Create("Label")
		hint:SetFullWidth(true)
		hint:SetText("Select a folder to view its macros.")
		self.listGroup:AddChild(hint)
		return
	end

	local _, entries = Data:GetSortedChildren(folderId)

	if #entries == 0 then
		local empty = AceGUI:Create("Label")
		empty:SetFullWidth(true)
		empty:SetText("No macros in this folder.")
		self.listGroup:AddChild(empty)
		return
	end

	for _, entry in ipairs(entries) do
		self:AddListRow({
			kind = "macro",
			id = entry.id,
			label = entry.name,
			icon = entry.icon,
			selected = (entry.id == self.selectedEntryId),
			onClick = function()
				self:SelectEntry(entry.id)
			end,
			onDouble = function()
				self:SelectEntry(entry.id)
			end,
		})
	end
end

function UI:PopulateSearchResults(query)
	local headerRow = AceGUI:Create("SimpleGroup")
	headerRow:SetFullWidth(true)
	headerRow:SetLayout("Flow")
	self.listGroup:AddChild(headerRow)

	local header = AceGUI:Create("Label")
	header:SetText("|cffffd100Search:|r " .. query)
	local textWidth = (header.label and header.label:GetStringWidth()) or 100
	header:SetWidth(math.min(240, math.max(70, textWidth + 10)))
	headerRow:AddChild(header)

	local clearIcon = AceGUI:Create("Icon")
	clearIcon:SetImage("Interface\\Buttons\\UI-StopButton")
	clearIcon:SetImageSize(14, 14)
	clearIcon:SetWidth(18)
	clearIcon:SetHeight(18)
	clearIcon:SetLabel(nil)
	clearIcon:SetCallback("OnClick", function()
		self:ClearSearch()
	end)
	clearIcon:SetCallback("OnEnter", function(widget)
		GameTooltip:SetOwner(widget.frame, "ANCHOR_RIGHT")
		GameTooltip:SetText("Clear search")
		GameTooltip:Show()
	end)
	clearIcon:SetCallback("OnLeave", function()
		GameTooltip:Hide()
	end)
	headerRow:AddChild(clearIcon)

	local headerGap = AceGUI:Create("Label")
	headerGap:SetFullWidth(true)
	headerGap:SetText(" ")
	headerGap:SetHeight(6)
	self.listGroup:AddChild(headerGap)

	local results = Search:Query(query)
	if #results == 0 then
		local empty = AceGUI:Create("Label")
		empty:SetFullWidth(true)
		empty:SetText("No matching macros.")
		self.listGroup:AddChild(empty)
		return
	end

	local groups = {}
	local order = {}
	for _, result in ipairs(results) do
		local entry = result.entry
		local parentId = entry.parentId or ""
		local group = groups[parentId]
		if not group then
			group = {
				path = result.path or Data:GetFolderPath(parentId) or "",
				entries = {},
			}
			groups[parentId] = group
			order[#order + 1] = parentId
		end
		group.entries[#group.entries + 1] = entry
	end

	table.sort(order, function(a, b)
		return (groups[a].path or ""):lower() < (groups[b].path or ""):lower()
	end)

	for i, parentId in ipairs(order) do
		local group = groups[parentId]
		if i > 1 then
			local spacer = AceGUI:Create("Label")
			spacer:SetFullWidth(true)
			spacer:SetText(" ")
			spacer:SetHeight(8)
			self.listGroup:AddChild(spacer)
		end

		local pathLabel = AceGUI:Create("Label")
		pathLabel:SetFullWidth(true)
		pathLabel:SetText("|cffffd100" .. group.path .. "|r")
		self.listGroup:AddChild(pathLabel)

		table.sort(group.entries, function(a, b)
			return a.name:lower() < b.name:lower()
		end)

		for _, entry in ipairs(group.entries) do
			self:AddListRow({
				kind = "macro",
				id = entry.id,
				label = entry.name,
				icon = entry.icon,
				selected = (entry.id == self.selectedEntryId),
				onClick = function()
					self:SelectEntry(entry.id)
				end,
				onDouble = function()
					self:SelectEntry(entry.id)
				end,
			})
		end
	end
end

function UI:AddListRow(info)
	local height = info.height or 18
	local iconSize = 14
	local iconLeft = 8
	local iconGap = 4

	local holder = AceGUI:Create("SimpleGroup")
	holder:SetFullWidth(true)
	holder:SetHeight(height)
	holder:SetLayout("Fill")
	self.listGroup:AddChild(holder)

	self._listRowButtonPool = self._listRowButtonPool or {}
	local btn = table.remove(self._listRowButtonPool)
	if not btn then
		btn = CreateFrame("Button", nil, holder.frame, "OptionsListButtonTemplate")
		btn:SetPushedTextOffset(0, 0)
		btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		if btn.toggle then
			btn.toggle:Hide()
			btn.toggle:Disable()
		end
		local icon = btn:CreateTexture(nil, "ARTWORK")
		icon:SetSize(iconSize, iconSize)
		btn._scrIcon = icon
	else
		btn:SetParent(holder.frame)
		if not btn._scrIcon then
			local icon = btn:CreateTexture(nil, "ARTWORK")
			icon:SetSize(iconSize, iconSize)
			btn._scrIcon = icon
		end
	end
	btn:ClearAllPoints()
	btn:SetAllPoints(holder.frame)
	btn:SetText(info.label or "")
	local fs = btn:GetFontString()
	local textLeft = iconLeft
	if info.icon and btn._scrIcon then
		btn._scrIcon:SetTexture(Compat.GetIconTexture(info.icon))
		btn._scrIcon:ClearAllPoints()
		btn._scrIcon:SetSize(iconSize, iconSize)
		btn._scrIcon:SetPoint("LEFT", btn, "LEFT", iconLeft, 0)
		btn._scrIcon:Show()
		textLeft = iconLeft + iconSize + iconGap
	elseif btn._scrIcon then
		btn._scrIcon:Hide()
	end
	if fs then
		fs:ClearAllPoints()
		fs:SetPoint("LEFT", textLeft, 0)
		fs:SetPoint("RIGHT", -8, 0)
		fs:SetJustifyH("LEFT")
		fs:SetWordWrap(height > 20)
	end
	btn:SetNormalFontObject(GameFontHighlightSmall)
	btn:SetHighlightFontObject(GameFontHighlightSmall)
	if info.selected then
		btn:LockHighlight()
	else
		btn:UnlockHighlight()
	end
	btn:Show()
	holder._scrRowBtn = btn

	btn:SetScript("OnClick", function(_, button)
		if button == "LeftButton" then
			local now = GetTime()
			if btn._lastClick and (now - btn._lastClick) < 0.35 and info.onDouble then
				btn._lastClick = 0
				info.onDouble()
			else
				btn._lastClick = now
				if info.onClick then
					info.onClick()
				end
			end
		elseif button == "RightButton" then
			self:ShowListContextMenu(btn, info)
		end
	end)

	local prevRelease = holder.OnRelease
	holder.OnRelease = function(widget)
		local rowBtn = widget._scrRowBtn
		if rowBtn then
			rowBtn:SetScript("OnClick", nil)
			rowBtn:UnlockHighlight()
			if rowBtn._scrIcon then
				rowBtn._scrIcon:Hide()
			end
			rowBtn:Hide()
			rowBtn:SetParent(nil)
			widget._scrRowBtn = nil
			self._listRowButtonPool[#self._listRowButtonPool + 1] = rowBtn
		end
		widget.OnRelease = prevRelease
		if prevRelease then
			prevRelease(widget)
		end
	end
end

------------------------------------------------------------------------
-- Actions / context menus
------------------------------------------------------------------------

function UI:PullMacros()
	addon():SyncMacros(true)
	self:RefreshAll()
end

function UI:ManualImport()
	self:PullMacros()
end

function UI:ShowListContextMenu(owner, info)
	if info.kind ~= "macro" then
		return
	end
	local entryId = info.id
	local entry = Data:GetEntry(entryId)
	if not entry then
		return
	end

	if self.selectedEntryId ~= entryId then
		self:SelectEntry(entryId)
	end

	if MenuUtil and MenuUtil.CreateContextMenu then
		local menu = MenuUtil.CreateContextMenu(owner, function(_, rootDescription)
			rootDescription:CreateTitle(entry.name)
			rootDescription:CreateButton("Create Blizzard Macro", function()
				self:CreateBlizzardMacro(entryId)
			end)
		end)
		if menu then
			menu:SetFrameStrata("TOOLTIP")
			menu:SetToplevel(true)
		end
		return
	end

	if not self._entryDropDown then
		self._entryDropDown = CreateFrame("Frame", "ScriptoriumMacroContextMenu", UIParent, "UIDropDownMenuTemplate")
	end
	self._entryDropDown:SetFrameStrata("TOOLTIP")
	self._entryDropDown:SetToplevel(true)
	UIDropDownMenu_Initialize(self._entryDropDown, function(_, level)
		local menuInfo = UIDropDownMenu_CreateInfo()
		menuInfo.text = entry.name
		menuInfo.isTitle = true
		menuInfo.notCheckable = true
		UIDropDownMenu_AddButton(menuInfo, level)

		menuInfo = UIDropDownMenu_CreateInfo()
		menuInfo.text = "Create Blizzard Macro"
		menuInfo.notCheckable = true
		menuInfo.func = function()
			self:CreateBlizzardMacro(entryId)
		end
		UIDropDownMenu_AddButton(menuInfo, level)
	end, "MENU")
	ToggleDropDownMenu(1, nil, self._entryDropDown, "cursor", 0, 0)
	local list = _G["DropDownList1"]
	if list then
		list:SetFrameStrata("TOOLTIP")
		list:SetToplevel(true)
	end
end

function UI:ShowFolderContextMenu(owner, folderId)
	local folder = Data:GetFolder(folderId)
	if not folder then
		return
	end
	-- Only leaf folders hold macros; parent folders are always empty.
	if folderId == Data:GetRootId() or #(folder.children or {}) > 0 then
		return
	end

	local isCharacterFolder = Data:IsCharacterFolder(folderId)

	if MenuUtil and MenuUtil.CreateContextMenu then
		local menu = MenuUtil.CreateContextMenu(owner, function(_, rootDescription)
			rootDescription:CreateTitle(folder.name)
			rootDescription:CreateButton("Create Blizzard Macros From Folder", function()
				self:CreateBlizzardMacrosFromFolder(folderId)
			end)
			if isCharacterFolder then
				rootDescription:CreateButton("Delete Character Folder", function()
					self:DeleteCharacterFolder(folderId)
				end)
			end
		end)
		if menu then
			menu:SetFrameStrata("TOOLTIP")
			menu:SetToplevel(true)
		end
		return
	end

	if not self._folderDropDown then
		self._folderDropDown = CreateFrame("Frame", "ScriptoriumFolderContextMenu", UIParent, "UIDropDownMenuTemplate")
	end
	self._folderDropDown:SetFrameStrata("TOOLTIP")
	self._folderDropDown:SetToplevel(true)
	UIDropDownMenu_Initialize(self._folderDropDown, function(_, level)
		local info = UIDropDownMenu_CreateInfo()
		info.text = folder.name
		info.isTitle = true
		info.notCheckable = true
		UIDropDownMenu_AddButton(info, level)

		info = UIDropDownMenu_CreateInfo()
		info.text = "Create Blizzard Macros From Folder"
		info.notCheckable = true
		info.func = function()
			self:CreateBlizzardMacrosFromFolder(folderId)
		end
		UIDropDownMenu_AddButton(info, level)

		if isCharacterFolder then
			info = UIDropDownMenu_CreateInfo()
			info.text = "Delete Character Folder"
			info.notCheckable = true
			info.func = function()
				self:DeleteCharacterFolder(folderId)
			end
			UIDropDownMenu_AddButton(info, level)
		end
	end, "MENU")
	ToggleDropDownMenu(1, nil, self._folderDropDown, "cursor", 0, 0)
	local list = _G["DropDownList1"]
	if list then
		list:SetFrameStrata("TOOLTIP")
		list:SetToplevel(true)
	end
end

function UI:DeleteCharacterFolder(folderId)
	if not Data:IsCharacterFolder(folderId) then
		addon():Notify("Only character folders can be deleted this way.", true)
		return
	end
	local folder = Data:GetFolder(folderId)
	if not folder then
		return
	end
	local realmId = folder.parentId
	local realm = Data:GetFolder(realmId)
	local realmName = realm and realm.name or ""
	local message = string.format(
		"Delete character folder \"%s\"%s?\n\nThis removes the macros from Scriptorium only. It does not delete Blizzard macros.",
		folder.name,
		realmName ~= "" and (" on " .. realmName) or ""
	)
	addon():ConfirmDelete(message, function()
		local parentId = realmId
		Data:DeleteFolder(folderId)

		-- Remove an empty realm folder left behind after the last character.
		local realmFolder = Data:GetFolder(parentId)
		if realmFolder and #(realmFolder.children or {}) == 0 then
			local charRootId = realmFolder.parentId
			Data:DeleteFolder(parentId)
			parentId = charRootId
		end

		if self.selectedFolderId == folderId or self.selectedFolderId == realmId then
			self.selectedEntryId = nil
			self:SelectFolder(parentId or Data:GetRootId())
		elseif self.selectedEntryId then
			local entry = Data:GetEntry(self.selectedEntryId)
			if not entry then
				self.selectedEntryId = nil
				self:LoadMacroIntoViewer(nil)
			end
		end
		self:RefreshAll()
		self:SetStatus(string.format("Deleted character folder \"%s\".", folder.name))
		addon():Notify(string.format("Deleted character folder \"%s\".", folder.name))
	end)
end

function UI:CreateBlizzardMacro(entryId)
	local id = entryId or self.selectedEntryId
	if not id then
		return
	end
	if id ~= self.selectedEntryId then
		self:SelectEntry(id)
	end
	local entry = Data:GetEntry(id)
	if not entry then
		return
	end
	self:ShowMacroScopeDialog(function(perCharacter)
		local ok, message = MacroBridge:UpsertFromEntry(entry, perCharacter)
		addon():Notify(message, not ok)
		self:SetStatus(message)
	end)
end

function UI:CreateBlizzardMacrosFromFolder(folderId)
	local folder = Data:GetFolder(folderId)
	if not folder then
		return
	end
	self:ShowFolderMacroScopeDialog(function(perCharacter)
		local entries = Data:CollectEntries(folderId)
		if #entries == 0 then
			local message = "No macros found in this folder."
			addon():Notify(message, true)
			self:SetStatus(message)
			return
		end
		local created, updated, failed = 0, 0, 0
		local lastError
		for _, entry in ipairs(entries) do
			local ok, message = MacroBridge:UpsertFromEntry(entry, perCharacter)
			if ok then
				if message:find("^Updated") then
					updated = updated + 1
				else
					created = created + 1
				end
			else
				failed = failed + 1
				lastError = message
			end
		end
		local message
		if failed == 0 then
			message = string.format(
				"Exported %d macro%s (%d created, %d updated).",
				created + updated,
				(created + updated) == 1 and "" or "s",
				created,
				updated
			)
		elseif (created + updated) == 0 then
			message = lastError or "Failed to export macros."
		else
			message = string.format(
				"Exported %d macro%s (%d failed).",
				created + updated,
				(created + updated) == 1 and "" or "s",
				failed
			)
		end
		addon():Notify(message, (created + updated) == 0)
		self:SetStatus(message)
	end)
end

function UI:ShowMacroScopeDialog(callback)
	if self.scopeFrame then
		AceGUI:Release(self.scopeFrame)
		self.scopeFrame = nil
	end
	local frame = AceGUI:Create("Window")
	frame:SetTitle("Create Blizzard Macro")
	frame:SetLayout("List")
	frame:SetWidth(320)
	frame:SetHeight(200)
	frame:SetCallback("OnClose", function(widget)
		AceGUI:Release(widget)
		if self.scopeFrame == widget then
			self.scopeFrame = nil
		end
	end)
	self.scopeFrame = frame

	if frame.frame then
		Compat.RaiseFrame(frame.frame)
	end

	local label = AceGUI:Create("Label")
	label:SetFullWidth(true)
	label:SetText("Export macros to Blizzard macros.\n\n\n• Existing macros will be updated\n\n• New macros will be created\n\n\nExport to:\n")
	frame:AddChild(label)

	local spacer = AceGUI:Create("Label")
	spacer:SetFullWidth(true)
	spacer:SetText(" ")
	spacer:SetHeight(8)
	frame:AddChild(spacer)

	local globalBtn = AceGUI:Create("Button")
	globalBtn:SetText("Global Macros")
	globalBtn:SetFullWidth(true)
	globalBtn:SetCallback("OnClick", function()
		AceGUI:Release(frame)
		self.scopeFrame = nil
		callback(false)
	end)
	frame:AddChild(globalBtn)

	local charBtn = AceGUI:Create("Button")
	charBtn:SetText("Character Macros")
	charBtn:SetFullWidth(true)
	charBtn:SetCallback("OnClick", function()
		AceGUI:Release(frame)
		self.scopeFrame = nil
		callback(true)
	end)
	frame:AddChild(charBtn)
end

function UI:ShowFolderMacroScopeDialog(callback)
	if self.scopeFrame then
		AceGUI:Release(self.scopeFrame)
		self.scopeFrame = nil
	end
	local frame = AceGUI:Create("Window")
	frame:SetTitle("Create Blizzard Macros")
	frame:SetLayout("List")
	frame:SetWidth(360)
	frame:SetHeight(215)
	frame:EnableResize(false)
	frame:SetCallback("OnClose", function(widget)
		AceGUI:Release(widget)
		if self.scopeFrame == widget then
			self.scopeFrame = nil
		end
	end)
	self.scopeFrame = frame

	if frame.frame then
		Compat.RaiseFrame(frame.frame)
	end

	local label = AceGUI:Create("Label")
	label:SetFullWidth(true)
	label:SetHeight(120)
	label:SetText("Export macros to Blizzard macros.\n\n\n• Existing macros will be updated\n\n• New macros will be created\n\n• Missing macros will NOT be deleted.\n\n\nExport to:\n")
	frame:AddChild(label)

	local spacer = AceGUI:Create("Label")
	spacer:SetFullWidth(true)
	spacer:SetText(" ")
	spacer:SetHeight(12)
	frame:AddChild(spacer)

	local globalBtn = AceGUI:Create("Button")
	globalBtn:SetText("Global Macros")
	globalBtn:SetFullWidth(true)
	globalBtn:SetCallback("OnClick", function()
		AceGUI:Release(frame)
		self.scopeFrame = nil
		callback(false)
	end)
	frame:AddChild(globalBtn)

	local charBtn = AceGUI:Create("Button")
	charBtn:SetText("Character Macros")
	charBtn:SetFullWidth(true)
	charBtn:SetCallback("OnClick", function()
		AceGUI:Release(frame)
		self.scopeFrame = nil
		callback(true)
	end)
	frame:AddChild(charBtn)
end

function UI:ClearSearch()
	self.searchQuery = ""
	if self.searchTimer then
		addon():CancelTimer(self.searchTimer)
		self.searchTimer = nil
	end
	if self.searchEdit then
		self.searchEdit:SetText("")
		if self.searchClearButton then
			self.searchClearButton:Hide()
		end
	end
	self:RefreshList()
end

function UI:ToggleSortMode()
	local mode = Data:GetSortMode()
	if mode == "name" then
		Data:SetSortMode("modified")
		self:SetStatus("Sorting by recently modified.")
	else
		Data:SetSortMode("name")
		self:SetStatus("Sorting alphabetically.")
	end
	if self.sortButton then
		self.sortButton:SetText(Data:GetSortMode() == "name" and "Sort: Name" or "Sort: Modified")
	end
	self:RefreshList()
end

------------------------------------------------------------------------
-- Window construction
------------------------------------------------------------------------

function UI:Toggle()
	if self.frame and self.frame:IsShown() then
		self.frame:Hide()
	else
		self:Show()
	end
end

function UI:Show()
	if self.frame then
		self.frame:Show()
		self:RefreshAll()
		return
	end
	self:CreateWindow()
	self.selectedFolderId = Data:GetRootId()
	self:RefreshAll()
end

function UI:CreateWindow()
	local frame = AceGUI:Create("Frame")
	frame:SetTitle("Scriptorium")
	frame:SetStatusText("Blizzard macro browser")
	frame:SetLayout("Flow")
	frame:SetWidth(1120)
	frame:SetHeight(640)
	frame:EnableResize(false)
	frame:SetCallback("OnClose", function(widget)
		if AceGUI:IsReleasing(widget) then
			return
		end
		if self.searchTimer then
			addon():CancelTimer(self.searchTimer)
			self.searchTimer = nil
		end
		if AddressBar and AddressBar.Destroy then
			AddressBar:Destroy()
		end
		AceGUI:Release(widget)
		self.frame = nil
		self.treeGroup = nil
		self._treeSplitter = nil
		self._contentsSplitter = nil
		self.contentGroup = nil
		self.shellGroup = nil
		self.bodyGroup = nil
		self.listContainer = nil
		self.navRow = nil
		self.optionsRow = nil
		self.addressCol = nil
		self.searchCol = nil
		self.addressHost = nil
		self.detailContainer = nil
		self.listGroup = nil
		self.nameEdit = nil
		self.bodyEdit = nil
		self.iconWidget = nil
		self.searchEdit = nil
		self.searchClearButton = nil
		self.sortButton = nil
		self.macroButton = nil
		self.pullMacrosButton = nil
		self.syncOnLoginCheck = nil
		self.syncOnMacroUpdateCheck = nil
	end)
	self.frame = frame

	local shell = AceGUI:Create("SimpleGroup")
	shell:SetFullWidth(true)
	shell:SetFullHeight(true)
	shell:SetAutoAdjustHeight(false)
	shell:SetLayout("List")
	frame:AddChild(shell)
	self.shellGroup = shell

	-- Top-left options: sync toggles + Pull Macros
	local OPTIONS_ROW_HEIGHT = 28
	local optionsRow = AceGUI:Create("SimpleGroup")
	optionsRow:SetFullWidth(true)
	optionsRow:SetHeight(OPTIONS_ROW_HEIGHT)
	optionsRow:SetAutoAdjustHeight(false)
	optionsRow:SetLayout("Flow")
	shell:AddChild(optionsRow)
	self.optionsRow = optionsRow
	self.optionsRowHeight = OPTIONS_ROW_HEIGHT

	local loginCheck = AceGUI:Create("CheckBox")
	loginCheck:SetLabel("Update on Login")
	loginCheck:SetValue(Data:GetSyncOnLogin())
	loginCheck:SetWidth(140)
	loginCheck:SetCallback("OnValueChanged", function(_, _, checked)
		Data:SetSyncOnLogin(checked and true or false)
	end)
	loginCheck:SetCallback("OnEnter", function(widget)
		GameTooltip:SetOwner(widget.frame, "ANCHOR_BOTTOMLEFT")
		GameTooltip:SetText("Update on Login")
		GameTooltip:AddLine("Pull Blizzard macros into Scriptorium when you log in.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	loginCheck:SetCallback("OnLeave", function()
		GameTooltip:Hide()
	end)
	optionsRow:AddChild(loginCheck)
	self.syncOnLoginCheck = loginCheck

	local autoCheck = AceGUI:Create("CheckBox")
	autoCheck:SetLabel("Auto-Update Macros")
	autoCheck:SetValue(Data:GetSyncOnMacroUpdate())
	autoCheck:SetWidth(160)
	autoCheck:SetCallback("OnValueChanged", function(_, _, checked)
		Data:SetSyncOnMacroUpdate(checked and true or false)
	end)
	autoCheck:SetCallback("OnEnter", function(widget)
		GameTooltip:SetOwner(widget.frame, "ANCHOR_BOTTOMLEFT")
		GameTooltip:SetText("Auto-Update Macros")
		GameTooltip:AddLine("Automatically update Scriptorium when a Blizzard macro changes.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	autoCheck:SetCallback("OnLeave", function()
		GameTooltip:Hide()
	end)
	optionsRow:AddChild(autoCheck)
	self.syncOnMacroUpdateCheck = autoCheck

	local pullBtn = AceGUI:Create("Button")
	pullBtn:SetText("Pull Macros")
	pullBtn:SetWidth(110)
	pullBtn:SetCallback("OnClick", function()
		self:PullMacros()
	end)
	pullBtn:SetCallback("OnEnter", function(widget)
		GameTooltip:SetOwner(widget.frame, "ANCHOR_BOTTOMLEFT")
		GameTooltip:SetText("Pull Macros")
		GameTooltip:AddLine("Manually sync Scriptorium from your current Blizzard macros.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	pullBtn:SetCallback("OnLeave", function()
		GameTooltip:Hide()
	end)
	optionsRow:AddChild(pullBtn)
	self.pullMacrosButton = pullBtn

	local navRow = AceGUI:Create("SimpleGroup")
	navRow:SetFullWidth(true)
	navRow:SetHeight(44)
	navRow:SetAutoAdjustHeight(false)
	navRow:SetLayout("Flow")
	shell:AddChild(navRow)
	self.navRow = navRow

	local addressCol = AceGUI:Create("SimpleGroup")
	addressCol:SetHeight(44)
	addressCol:SetAutoAdjustHeight(false)
	addressCol:SetLayout("Fill")
	navRow:AddChild(addressCol)
	self.addressCol = addressCol

	local addressHost = AceGUI:Create("SimpleGroup")
	addressHost:SetFullWidth(true)
	addressHost:SetHeight(26)
	addressHost:SetAutoAdjustHeight(false)
	addressHost:SetLayout("Fill")
	addressCol:AddChild(addressHost)
	self.addressHost = addressHost

	local navGap = AceGUI:Create("Label")
	navGap:SetText(" ")
	navGap:SetWidth(16)
	navGap:SetHeight(1)
	navRow:AddChild(navGap)

	local searchCol = AceGUI:Create("SimpleGroup")
	searchCol:SetWidth(220)
	searchCol:SetHeight(44)
	searchCol:SetAutoAdjustHeight(false)
	searchCol:SetLayout("List")
	navRow:AddChild(searchCol)
	self.searchCol = searchCol

	local search = AceGUI:Create("EditBox")
	search:SetLabel("Search Macros")
	search:SetFullWidth(true)
	search:DisableButton(true)
	search:SetCallback("OnEnterPressed", function(widget, event, text)
		self.searchQuery = text or ""
		self:RefreshList()
	end)
	search:SetCallback("OnTextChanged", function(widget, event, text)
		self.searchQuery = text or ""
		if self.searchClearButton then
			if self.searchQuery ~= "" then
				self.searchClearButton:Show()
			else
				self.searchClearButton:Hide()
			end
		end
		if self.searchTimer then
			addon():CancelTimer(self.searchTimer)
		end
		self.searchTimer = addon():ScheduleTimer(function()
			self:RefreshList()
		end, 0.25)
	end)
	searchCol:AddChild(search)
	self.searchEdit = search

	local clearBtn = CreateFrame("Button", nil, search.editbox)
	clearBtn:SetSize(16, 16)
	clearBtn:SetPoint("RIGHT", search.editbox, "RIGHT", -4, 0)
	clearBtn:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
	clearBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight")
	clearBtn:SetScript("OnEnter", function(btn)
		GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
		GameTooltip:SetText("Clear search")
		GameTooltip:Show()
	end)
	clearBtn:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	clearBtn:SetScript("OnClick", function()
		self:ClearSearch()
	end)
	clearBtn:Hide()
	self.searchClearButton = clearBtn
	search.editbox:SetTextInsets(0, 20, 3, 3)
	search.editbox:HookScript("OnSizeChanged", function()
		self:AlignAddressWithSearch()
	end)

	navRow.frame:HookScript("OnSizeChanged", function()
		self:LayoutNavRow()
	end)
	shell.frame:HookScript("OnSizeChanged", function()
		self:LayoutNavRow()
		self:LayoutBodyHeight()
	end)

	AddressBar:Create(addressHost)
	AddressBar:SetFolder(self.selectedFolderId or Data:GetRootId(), true)
	self:AlignAddressWithSearch()

	local NAV_BOTTOM_GAP = 2
	local navBottomGap = AceGUI:Create("SimpleGroup")
	navBottomGap:SetFullWidth(true)
	navBottomGap:SetHeight(NAV_BOTTOM_GAP)
	navBottomGap:SetAutoAdjustHeight(false)
	navBottomGap:SetLayout("List")
	shell:AddChild(navBottomGap)
	self.navBottomGap = navBottomGap
	self.navBottomGapHeight = NAV_BOTTOM_GAP

	local body = AceGUI:Create("SimpleGroup")
	body:SetFullWidth(true)
	body:SetAutoAdjustHeight(false)
	body:SetLayout("Fill")
	shell:AddChild(body)
	self.bodyGroup = body

	local tree = AceGUI:Create("TreeGroup")
	tree:SetFullWidth(true)
	tree:SetFullHeight(true)
	tree:SetLayout("Fill")
	tree:SetTreeWidth(TREE_WIDTH_DEFAULT, false)
	tree:EnableButtonTooltips(false)
	if tree.treeframe then
		if tree.treeframe.SetResizeBounds then
			tree.treeframe:SetResizeBounds(TREE_WIDTH_MIN, 1, TREE_WIDTH_MAX, 1600)
		elseif tree.treeframe.SetMaxResize then
			tree.treeframe:SetMinResize(TREE_WIDTH_MIN, 1)
			tree.treeframe:SetMaxResize(TREE_WIDTH_MAX, 1600)
		end
	end
	tree:SetCallback("OnGroupSelected", function(widget, event, uniquevalue)
		if self._ignoreTreeSelect then
			return
		end
		local folderId = uniquevalue
		if type(uniquevalue) == "string" then
			folderId = uniquevalue:match("([^\001]+)$") or uniquevalue
		end
		if folderId and folderId ~= self.selectedFolderId then
			self:SelectFolder(folderId)
		end
	end)
	tree:SetCallback("OnTreeResize", function()
		self:ForceLayout()
		self:DecorateTreeRows()
		self:EnsureTreeDragger()
		self:EnsureContentsDragger()
	end)
	local origRefreshTree = tree.RefreshTree
	tree.RefreshTree = function(widget, ...)
		origRefreshTree(widget, ...)
		self:DecorateTreeRows()
		self:EnsureTreeDragger()
		self:EnsureContentsDragger()
	end
	body:AddChild(tree)
	self.treeGroup = tree
	self:EnsureTreeDragger()

	local content = AceGUI:Create("SimpleGroup")
	content:SetFullWidth(true)
	content:SetFullHeight(true)
	content:SetAutoAdjustHeight(false)
	content:SetLayout("Flow")
	tree:AddChild(content)
	self.contentGroup = content

	local listContainer = AceGUI:Create("InlineGroup")
	listContainer:SetTitle("Folder contents")
	listContainer:SetWidth(320)
	listContainer:SetFullHeight(true)
	listContainer:SetAutoAdjustHeight(false)
	listContainer:SetLayout("Fill")
	content:AddChild(listContainer)
	self.listContainer = listContainer

	listContainer.titletext:ClearAllPoints()
	listContainer.titletext:SetPoint("TOPLEFT", 14, 0)
	listContainer.titletext:SetJustifyH("LEFT")
	listContainer.titletext:SetHeight(18)

	local sortBtn = CreateFrame("Button", nil, listContainer.frame, "UIPanelButtonTemplate")
	sortBtn:SetSize(110, 18)
	sortBtn:SetPoint("LEFT", listContainer.titletext, "RIGHT", 8, 0)
	sortBtn:SetText(Data:GetSortMode() == "name" and "Sort: Name" or "Sort: Modified")
	sortBtn:SetScript("OnClick", function()
		self:ToggleSortMode()
	end)
	self.sortButton = sortBtn

	local listScroll = AceGUI:Create("ScrollFrame")
	listScroll:SetLayout("List")
	listContainer:AddChild(listScroll)
	self.listGroup = listScroll

	-- Right detail: read-only macro viewer
	local detail = AceGUI:Create("InlineGroup")
	detail:SetTitle("Macro")
	detail:SetWidth(480)
	detail:SetFullHeight(true)
	detail:SetAutoAdjustHeight(false)
	detail:SetLayout("Fill")
	content:AddChild(detail)
	self.detailContainer = detail

	local detailScroll = AceGUI:Create("ScrollFrame")
	detailScroll:SetLayout("List")
	detail:AddChild(detailScroll)

	local nameEdit = AceGUI:Create("EditBox")
	nameEdit:SetLabel("Name")
	nameEdit:SetFullWidth(true)
	detailScroll:AddChild(nameEdit)
	self.nameEdit = nameEdit

	local iconRow = AceGUI:Create("SimpleGroup")
	iconRow:SetFullWidth(true)
	iconRow:SetLayout("Flow")
	detailScroll:AddChild(iconRow)

	local icon = AceGUI:Create("Icon")
	icon:SetImage(Compat.GetIconTexture(Compat.DefaultIcon()))
	icon:SetImageSize(36, 36)
	icon:SetWidth(44)
	icon:SetHeight(44)
	iconRow:AddChild(icon)
	self.iconWidget = icon

	local bodyEdit = AceGUI:Create("MultiLineEditBox")
	bodyEdit:SetLabel("Macro Body")
	bodyEdit:SetFullWidth(true)
	bodyEdit:SetNumLines(14)
	bodyEdit:DisableButton(true)
	detailScroll:AddChild(bodyEdit)
	self.bodyEdit = bodyEdit

	self:SetupReadOnlyFields()
	self._lockedName = ""
	self._lockedBody = ""

	local actions = AceGUI:Create("SimpleGroup")
	actions:SetFullWidth(true)
	actions:SetLayout("Flow")
	detailScroll:AddChild(actions)

	local macroBtn = AceGUI:Create("Button")
	macroBtn:SetText("Create Blizzard Macro")
	macroBtn:SetWidth(180)
	macroBtn:SetDisabled(true)
	macroBtn:SetCallback("OnClick", function()
		self:CreateBlizzardMacro()
	end)
	actions:AddChild(macroBtn)
	self.macroButton = macroBtn

	self:LoadMacroIntoViewer(nil)
	frame:SetStatusText("Ready — /scriptorium or /scr to toggle")

	self:ForceLayout()
	addon():ScheduleTimer(function()
		self:ForceLayout()
	end, 0)
end

function UI:ForceLayout()
	local frame = self.frame
	if not frame or not frame.frame then
		return
	end
	local w = frame.frame:GetWidth()
	if w and w > 0 then
		frame:SetWidth(w + 1)
		frame:SetWidth(w)
	end
	frame:DoLayout()
	self:SyncPaneWidths()
	self:EnsureTreeDragger()
	self:EnsureContentsDragger()
end

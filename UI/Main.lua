--- UI/Main.lua
--- Three-pane file explorer: folder tree | contents list | entry editor.
local ADDON_NAME, ns = ...

local AceGUI = LibStub("AceGUI-3.0")
local Data = ns.Data
local Search = ns.Search
local MacroBridge = ns.MacroBridge
local Compat = ns.Compat

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
UI.dirty = false
UI.draft = nil -- unsaved field values for selected entry
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

function UI:IsDirty()
	return self.dirty
end

function UI:MarkDirty()
	self.dirty = true
	if self.saveButton then
		self.saveButton:SetDisabled(false)
	end
end

function UI:ClearDirty()
	self.dirty = false
	if self.saveButton then
		self.saveButton:SetDisabled(true)
	end
end

function UI:CaptureDraftFromWidgets()
	if not self.selectedEntryId then
		self.draft = nil
		return
	end
	self.draft = {
		name = self.nameEdit and self.nameEdit:GetText() or "",
		description = self.descEdit and self.descEdit:GetText() or "",
		text = self.bodyEdit and self.bodyEdit:GetText() or "",
		icon = self.currentIcon or Compat.DefaultIcon(),
	}
end

function UI:LoadEntryIntoEditor(entry)
	self.suppressDirty = true
	self.currentIcon = entry and Compat.NormalizeIcon(entry.icon) or Compat.DefaultIcon()
	if self.nameEdit then
		self.nameEdit:SetText(entry and entry.name or "")
	end
	if self.descEdit then
		self.descEdit:SetText(entry and entry.description or "")
	end
	if self.bodyEdit then
		self.bodyEdit:SetText(entry and entry.text or "")
	end
	if self.iconWidget then
		self.iconWidget:SetImage(Compat.GetIconTexture(self.currentIcon))
	end
	local enabled = entry ~= nil
	if self.nameEdit then self.nameEdit:SetDisabled(not enabled) end
	if self.descEdit then self.descEdit:SetDisabled(not enabled) end
	if self.bodyEdit then self.bodyEdit:SetDisabled(not enabled) end
	if self.iconButton then self.iconButton:SetDisabled(not enabled) end
	if self.macroButton then self.macroButton:SetDisabled(not enabled) end
	if self.dupEntryButton then self.dupEntryButton:SetDisabled(not enabled) end
	if self.delEntryButton then self.delEntryButton:SetDisabled(not enabled) end
	self:ClearDirty()
	self.suppressDirty = false
	self:CaptureDraftFromWidgets()
end

function UI:SaveCurrentEntry()
	if not self.selectedEntryId then
		return false
	end
	self:CaptureDraftFromWidgets()
	local ok, err = Data:UpdateEntry(self.selectedEntryId, self.draft)
	if not ok then
		addon():Notify(err or "Save failed.", true)
		return false
	end
	self:ClearDirty()
	self:SetStatus("Saved.")
	self:RefreshAll()
	return true
end

function UI:WithUnsavedGuard(action)
	if not self:IsDirty() then
		action()
		return
	end
	addon():ConfirmUnsaved(function()
		self:ClearDirty()
		action()
	end)
end

------------------------------------------------------------------------
-- Selection
------------------------------------------------------------------------

function UI:SelectFolder(folderId, skipGuard)
	local function doSelect()
		self.selectedFolderId = folderId or Data:GetRootId()
		self.selectedEntryId = nil
		self.searchQuery = self.searchEdit and self.searchEdit:GetText() or self.searchQuery
		-- Clear search when navigating tree intentionally? Keep search if active.
		self:LoadEntryIntoEditor(nil)
		self:RefreshTreeSelection()
		self:RefreshList()
		self:RefreshDetailEnabled()
	end
	if skipGuard then
		doSelect()
	else
		self:WithUnsavedGuard(doSelect)
	end
end

function UI:SelectEntry(entryId, skipGuard)
	local function doSelect()
		local entry = Data:GetEntry(entryId)
		if not entry then
			return
		end
		self.selectedEntryId = entryId
		self.selectedFolderId = entry.parentId
		self:LoadEntryIntoEditor(entry)
		self:RefreshTreeSelection()
		self:RefreshList()
		self:RefreshDetailEnabled()
	end
	if skipGuard then
		doSelect()
	else
		self:WithUnsavedGuard(doSelect)
	end
end

------------------------------------------------------------------------
-- Refresh
------------------------------------------------------------------------

function UI:RefreshAll()
	self:RefreshTree()
	self:RefreshList()
	if self.selectedEntryId then
		local entry = Data:GetEntry(self.selectedEntryId)
		if entry and not self:IsDirty() then
			self:LoadEntryIntoEditor(entry)
		elseif not entry then
			self.selectedEntryId = nil
			self:LoadEntryIntoEditor(nil)
		end
	end
end

function UI:RefreshTree()
	if not self.treeGroup then
		return
	end
	self.treeGroup:SetTree(Data:BuildTree())
	self:RefreshTreeSelection()
	self:DecorateTreeAddButtons()
end

--- Toggle expand/collapse for a tree path, remembering user intent.
function UI:ToggleFolderExpanded(uniquevalue)
	if not uniquevalue or not self.treeGroup then
		return
	end
	local status = (self.treeGroup.status or self.treeGroup.localstatus).groups
	local nowExpanded = not status[uniquevalue]
	status[uniquevalue] = nowExpanded or nil
	self._userExpanded = self._userExpanded or {}
	if nowExpanded then
		self._userExpanded[uniquevalue] = true
	else
		self._userExpanded[uniquevalue] = nil
	end
	self.treeGroup:RefreshTree()
end

--- Resolve the tree folder button currently under the mouse (walks parents).
function UI:GetFolderButtonUnderMouse()
	local frames
	if GetMouseFoci then
		frames = GetMouseFoci()
	elseif GetMouseFocus then
		local focus = GetMouseFocus()
		frames = focus and { focus } or {}
	else
		return nil
	end
	for i = 1, #frames do
		local frame = frames[i]
		while frame do
			if frame.value and frame.obj == self.treeGroup then
				return frame
			end
			frame = frame.GetParent and frame:GetParent() or nil
		end
	end
	return nil
end

--- Finish a folder drag onto destFolderId (may be nil if dropped nowhere useful).
function UI:CompleteFolderDrag(destFolderId)
	local srcId = self._draggingFolderId
	self._draggingFolderId = nil
	if ResetCursor then
		ResetCursor()
	end
	if self._dragHighlightBtn then
		self._dragHighlightBtn:UnlockHighlight()
		self._dragHighlightBtn = nil
	end
	if not srcId or not destFolderId or srcId == destFolderId then
		return
	end
	local src = Data:GetFolder(srcId)
	if not src or src.parentId == destFolderId then
		return
	end
	local ok, err = Data:MoveFolder(srcId, destFolderId)
	if not ok then
		addon():Notify(err, true)
		return
	end
	-- Paths changed; rebuild expand state so the destination stays open.
	self._userExpanded = {}
	local pathParts = {}
	local walk = destFolderId
	while walk do
		table.insert(pathParts, 1, walk)
		local folder = Data:GetFolder(walk)
		walk = folder and folder.parentId
	end
	for i = 1, #pathParts do
		self._userExpanded[table.concat(pathParts, "\001", 1, i)] = true
	end
	self:SelectFolder(srcId, true)
	self:RefreshAll()
	self:SetStatus("Folder moved.")
end

--- Enable click-and-drag to move a folder into another folder.
function UI:SetupFolderRowDrag(button)
	if button._scriptoriumDragHooked then
		return
	end
	button:RegisterForDrag("LeftButton")
	button:SetScript("OnDragStart", function(btn)
		if not btn.value or btn.value == Data:GetRootId() then
			return
		end
		self._draggingFolderId = btn.value
		-- Prefer a built-in cursor token; fall back silently if unavailable.
		if SetCursorByMode then
			pcall(SetCursorByMode, 43) -- HoldingHandCursor (open hand)
		elseif SetCursor then
			pcall(SetCursor, "Interface\\Cursor\\OpenHandGlow")
		end
	end)
	button:SetScript("OnDragStop", function()
		if not self._draggingFolderId then
			return
		end
		local destBtn = self:GetFolderButtonUnderMouse()
		self:CompleteFolderDrag(destBtn and destBtn.value)
	end)
	local origOnEnter = button:GetScript("OnEnter")
	button:SetScript("OnEnter", function(btn, ...)
		if origOnEnter then
			origOnEnter(btn, ...)
		end
		if self._draggingFolderId and btn.value and btn.value ~= self._draggingFolderId then
			if self._dragHighlightBtn and self._dragHighlightBtn ~= btn then
				self._dragHighlightBtn:UnlockHighlight()
			end
			btn:LockHighlight()
			self._dragHighlightBtn = btn
		end
	end)
	local origOnLeave = button:GetScript("OnLeave")
	button:SetScript("OnLeave", function(btn, ...)
		if self._dragHighlightBtn == btn then
			btn:UnlockHighlight()
			self._dragHighlightBtn = nil
		end
		if origOnLeave then
			origOnLeave(btn, ...)
		end
	end)
	button._scriptoriumDragHooked = true
end

--- Truncate a folder label to fit maxWidth, preserving root gold coloring / counts.
--- Returns true if the visible text was truncated.
local function SetTruncatedFolderLabel(fontString, folder, maxWidth)
	if not fontString or not folder then
		return false
	end
	local isRoot = folder.id == Data:GetRootId()
	local entryCount = 0
	if not isRoot then
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
		return string.format("%s (%d)", name, entryCount)
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

local function LayoutTreeFolderLabel(button, addBtn, textLeft)
	local fs = button.text
	if not fs then
		return
	end
	fs:ClearAllPoints()
	fs:SetPoint("LEFT", button, "LEFT", textLeft, 0)
	if addBtn and addBtn:IsShown() then
		fs:SetPoint("RIGHT", addBtn, "LEFT", -4, 0)
	else
		fs:SetPoint("RIGHT", button, "RIGHT", -4, 0)
	end
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
	-- Width can be 0 before the first layout pass; fall back to button geometry.
	if maxWidth < 1 and button.GetWidth then
		local rightPad = (addBtn and addBtn:IsShown()) and 22 or 4
		maxWidth = math.max(0, (button:GetWidth() or 0) - textLeft - rightPad)
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

--- Custom folder-pane splitter (AceGUI StartSizing is unreliable with dual anchors).
function UI:EnsureTreeDragger()
	local tree = self.treeGroup
	if not tree or not tree.treeframe or not tree.frame then
		return
	end

	-- Disable AceGUI's built-in grip; it sits under row buttons and StartSizing fails here.
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
				UI:DecorateTreeAddButtons()
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
		UI:DecorateTreeAddButtons()
		UI:EnsureTreeDragger()
		UI:EnsureContentsDragger()
	end)
end

local CONTENTS_WIDTH_MIN = 180
local ENTRY_WIDTH_MIN = 260

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
end

--- Splitter between Contents and Entry (same interaction as the Folders splitter).
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

--- Add "+" / chevron controls and right-click menus on folder tree rows.
function UI:DecorateTreeAddButtons()
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
						self:WithUnsavedGuard(function()
							if folderId ~= self.selectedFolderId then
								self.selectedFolderId = folderId
								self.selectedEntryId = nil
								self:LoadEntryIntoEditor(nil)
								self:RefreshTreeSelection()
								self:RefreshList()
								self:RefreshDetailEnabled()
							end
							self:ShowFolderContextMenu(btn, folderId)
						end)
					end
					return
				end
				if origOnClick then
					origOnClick(btn, mouseButton, ...)
				end
				-- Row clicks select only; never keep the clicked folder expanded
				-- unless the user opened it with the chevron.
				if btn.uniquevalue then
					self:RefreshTreeSelection()
				end
			end)
			-- Expand/collapse is via the chevron only.
			button:SetScript("OnDoubleClick", function() end)
			button._scriptoriumMenuHooked = true
		end

		-- Keep double-click disabled even on already-hooked rows.
		if button:IsShown() then
			button:SetScript("OnDoubleClick", function() end)
		end

		if button:IsShown() and button.value then
			self:SetupFolderRowDrag(button)
			-- OptionsListButtonTemplate shifts the label while pressed; keep it still.
			if button.SetPushedTextOffset then
				button:SetPushedTextOffset(0, 0)
			end
			if button.SetClipsChildren then
				button:SetClipsChildren(true)
			end
			if not button._scriptoriumTipHooked then
				button:HookScript("OnEnter", function(btn)
					if self._draggingFolderId then
						return
					end
					-- Always show the real folder name (label text may be truncated).
					ShowFolderTooltip(btn)
				end)
				button:HookScript("OnLeave", function()
					HideFolderTooltip()
				end)
				button._scriptoriumTipHooked = true
			end
		end

		-- Fully disable AceGUI's built-in expand toggle (we use our own chevron).
		if button.toggle then
			button.toggle:SetScript("OnClick", nil)
			button.toggle:EnableMouse(false)
			button.toggle:Hide()
			button.toggle:SetAlpha(0)
		end

		local addBtn = button._scriptoriumAdd
		local chevron = button._scriptoriumChevronBtn

		if button:IsShown() and button.value then
			if not addBtn then
				addBtn = CreateFrame("Button", nil, button)
				addBtn:SetSize(16, 16)
				addBtn:SetPoint("RIGHT", button, "RIGHT", -2, 0)
				addBtn:SetFrameLevel(button:GetFrameLevel() + 5)
				addBtn:SetNormalTexture("Interface\\Buttons\\UI-PlusButton-Up")
				addBtn:SetPushedTexture("Interface\\Buttons\\UI-PlusButton-Down")
				addBtn:SetDisabledTexture("Interface\\Buttons\\UI-PlusButton-Disabled")
				addBtn:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight")
				addBtn:SetScript("OnEnter", function(self)
					GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
					GameTooltip:SetText("New folder")
					GameTooltip:AddLine("Create a folder inside this one.", 1, 1, 1, true)
					GameTooltip:Show()
				end)
				addBtn:SetScript("OnLeave", function()
					GameTooltip:Hide()
				end)
				addBtn:SetScript("OnClick", function(btn)
					if btn.folderId then
						self:CreateFolder(btn.folderId)
					end
				end)
				button._scriptoriumAdd = addBtn
			end
			addBtn.folderId = button.value
			addBtn:Show()

			local level = button.level or 1
			local hasIcon = button.icon and button.icon:GetTexture()
			local left = (hasIcon and 16 or 0) + (level == 1 and 8 or (8 * level))
			local hasChildren = button.treeline and button.treeline.hasChildren
			local chevronSize = 18
			local chevronGap = 2
			local textLeft = left + chevronSize + chevronGap

			-- Keep one font for normal + highlight so LockHighlight does not nudge glyphs.
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
				chevron:SetPoint("LEFT", button, "LEFT", left, 0)
				chevron:Show()
			else
				if chevron then
					chevron:Hide()
				end
			end

			LayoutTreeFolderLabel(button, addBtn, textLeft)
		else
			if addBtn then
				addBtn:Hide()
			end
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
	-- AceGUI TreeGroup uniquevalue is a \001-joined path from root.
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

	-- Rebuild expand state from scratch so a row click can never leave a
	-- folder open unless the user opened it with the chevron.
	wipe(status.groups)
	for i = 1, #pathParts - 1 do
		status.groups[table.concat(pathParts, "\001", 1, i)] = true
	end
	if self._userExpanded then
		for path, isOpen in pairs(self._userExpanded) do
			if isOpen then
				status.groups[path] = true
			end
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
		hint:SetText("Select a folder to view and manage its contents.")
		self.listGroup:AddChild(hint)
		return
	end

	local _, entries = Data:GetSortedChildren(folderId)

	local headerRow = AceGUI:Create("SimpleGroup")
	headerRow:SetFullWidth(true)
	headerRow:SetLayout("Flow")
	self.listGroup:AddChild(headerRow)

	local addEntryBtn = AceGUI:Create("Icon")
	addEntryBtn:SetImage("Interface\\Buttons\\UI-PlusButton-Up")
	addEntryBtn:SetImageSize(16, 16)
	addEntryBtn:SetWidth(22)
	addEntryBtn:SetLabel(nil)
	addEntryBtn:SetCallback("OnClick", function()
		self:CreateEntry()
	end)
	addEntryBtn:SetCallback("OnEnter", function(widget)
		GameTooltip:SetOwner(widget.frame, "ANCHOR_RIGHT")
		GameTooltip:SetText("New entry")
		GameTooltip:AddLine("Create an entry in this folder.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	addEntryBtn:SetCallback("OnLeave", function()
		GameTooltip:Hide()
	end)
	headerRow:AddChild(addEntryBtn)
	self.addEntryButton = addEntryBtn

	local pathLabel = AceGUI:Create("Label")
	pathLabel:SetWidth(280)
	pathLabel:SetText("|cffffd100" .. Data:GetFolderPath(folderId) .. "|r")
	headerRow:AddChild(pathLabel)

	if #entries == 0 then
		local empty = AceGUI:Create("Label")
		empty:SetFullWidth(true)
		empty:SetText("No entries in this folder.")
		self.listGroup:AddChild(empty)
		return
	end

	for _, entry in ipairs(entries) do
		self:AddListRow({
			kind = "entry",
			id = entry.id,
			label = entry.name,
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
		empty:SetText("No matching entries.")
		self.listGroup:AddChild(empty)
		return
	end

	-- Group matches by folder so the breadcrumb is a section title, not repeated per row.
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
				kind = "entry",
				id = entry.id,
				label = entry.name,
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

	-- Use the same button template as the folder tree so selection highlight matches.
	-- Keep the native button on a short-lived AceGUI holder and detach it on release
	-- so AceGUI pooling cannot leak row chrome into other SimpleGroups.
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
	else
		btn:SetParent(holder.frame)
	end
	btn:ClearAllPoints()
	btn:SetAllPoints(holder.frame)
	btn:SetText(info.label or "")
	local fs = btn:GetFontString()
	if fs then
		fs:ClearAllPoints()
		fs:SetPoint("LEFT", 8, 0)
		fs:SetPoint("RIGHT", -8, 0)
		fs:SetJustifyH("LEFT")
		fs:SetWordWrap(height > 20)
	end
	-- Same fonts as nested tree rows.
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

function UI:RefreshDetailEnabled()
	-- handled in LoadEntryIntoEditor
end

------------------------------------------------------------------------
-- Context menus / actions
------------------------------------------------------------------------

function UI:ShowListContextMenu(owner, info)
	if info.kind ~= "entry" then
		return
	end
	local entryId = info.id
	local entry = Data:GetEntry(entryId)
	if not entry then
		return
	end

	local function openMenu()
		if self.selectedEntryId ~= entryId then
			self:SelectEntry(entryId, true)
		end

		if MenuUtil and MenuUtil.CreateContextMenu then
			local menu = MenuUtil.CreateContextMenu(owner, function(_, rootDescription)
				rootDescription:CreateTitle(entry.name)
				rootDescription:CreateButton("Create Blizzard Macro", function()
					self:CreateBlizzardMacro(entryId)
				end)
				rootDescription:CreateButton("Rename", function()
					self:RenameSelectedEntry(entryId)
				end)
				rootDescription:CreateButton("Duplicate", function()
					self:DuplicateSelectedEntry(entryId)
				end)
				rootDescription:CreateButton("Move into Folder…", function()
					self:MoveSelectedIntoFolder(entryId)
				end)
				rootDescription:CreateButton("Delete", function()
					self:DeleteSelectedEntry(entryId)
				end)
			end)
			if menu then
				menu:SetFrameStrata("TOOLTIP")
				menu:SetToplevel(true)
			end
			return
		end

		if not self._entryDropDown then
			self._entryDropDown = CreateFrame("Frame", "ScriptoriumEntryContextMenu", UIParent, "UIDropDownMenuTemplate")
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

			menuInfo = UIDropDownMenu_CreateInfo()
			menuInfo.text = "Rename"
			menuInfo.notCheckable = true
			menuInfo.func = function()
				self:RenameSelectedEntry(entryId)
			end
			UIDropDownMenu_AddButton(menuInfo, level)

			menuInfo = UIDropDownMenu_CreateInfo()
			menuInfo.text = "Duplicate"
			menuInfo.notCheckable = true
			menuInfo.func = function()
				self:DuplicateSelectedEntry(entryId)
			end
			UIDropDownMenu_AddButton(menuInfo, level)

			menuInfo = UIDropDownMenu_CreateInfo()
			menuInfo.text = "Move into Folder…"
			menuInfo.notCheckable = true
			menuInfo.func = function()
				self:MoveSelectedIntoFolder(entryId)
			end
			UIDropDownMenu_AddButton(menuInfo, level)

			menuInfo = UIDropDownMenu_CreateInfo()
			menuInfo.text = "Delete"
			menuInfo.notCheckable = true
			menuInfo.func = function()
				self:DeleteSelectedEntry(entryId)
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

	if self.selectedEntryId ~= entryId then
		self:WithUnsavedGuard(openMenu)
	else
		openMenu()
	end
end

function UI:ShowFolderContextMenu(owner, folderId)
	local folder = Data:GetFolder(folderId)
	if not folder then
		return
	end
	local isRoot = folderId == Data:GetRootId()

	if MenuUtil and MenuUtil.CreateContextMenu then
		local menu = MenuUtil.CreateContextMenu(owner, function(_, rootDescription)
			rootDescription:CreateTitle(folder.name)
			rootDescription:CreateButton("Add Folder", function()
				self:CreateFolder(folderId)
			end)
			local addEntryBtn = rootDescription:CreateButton("Add Entry", function()
				self:CreateEntry(folderId)
			end)
			local renameBtn = rootDescription:CreateButton("Rename Folder", function()
				self:RenameSelectedFolder(folderId)
			end)
			local deleteBtn = rootDescription:CreateButton("Delete Folder", function()
				self:DeleteSelectedFolder(folderId)
			end)
			if isRoot then
				addEntryBtn:SetEnabled(false)
				renameBtn:SetEnabled(false)
				deleteBtn:SetEnabled(false)
			end
		end)
		-- AceGUI frames use FULLSCREEN_DIALOG; default menus sit behind them.
		if menu then
			menu:SetFrameStrata("TOOLTIP")
			menu:SetToplevel(true)
		end
		return
	end

	-- Classic / older clients: UIDropDownMenu at cursor.
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
		info.text = "Add Folder"
		info.notCheckable = true
		info.func = function()
			self:CreateFolder(folderId)
		end
		UIDropDownMenu_AddButton(info, level)

		info = UIDropDownMenu_CreateInfo()
		info.text = "Add Entry"
		info.notCheckable = true
		info.disabled = isRoot
		info.func = function()
			self:CreateEntry(folderId)
		end
		UIDropDownMenu_AddButton(info, level)

		info = UIDropDownMenu_CreateInfo()
		info.text = "Rename Folder"
		info.notCheckable = true
		info.disabled = isRoot
		info.func = function()
			self:RenameSelectedFolder(folderId)
		end
		UIDropDownMenu_AddButton(info, level)

		info = UIDropDownMenu_CreateInfo()
		info.text = "Delete Folder"
		info.notCheckable = true
		info.disabled = isRoot
		info.func = function()
			self:DeleteSelectedFolder(folderId)
		end
		UIDropDownMenu_AddButton(info, level)
	end, "MENU")
	ToggleDropDownMenu(1, nil, self._folderDropDown, "cursor", 0, 0)
	-- DropList frames are created by the dropdown system; raise them too.
	local list = _G["DropDownList1"]
	if list then
		list:SetFrameStrata("TOOLTIP")
		list:SetToplevel(true)
	end
end

function UI:CreateFolder(parentId)
	parentId = parentId or self.selectedFolderId or Data:GetRootId()
	addon():PromptName("New folder name:", "New Folder", function(name)
		local id, err = Data:CreateFolder(parentId, name)
		if not id then
			addon():Notify(err, true)
			return
		end
		-- Expand parent in the tree so the new folder is visible.
		if self.treeGroup then
			local status = self.treeGroup.status or self.treeGroup.localstatus
			if status and status.groups then
				local pathParts = {}
				local walk = parentId
				while walk do
					table.insert(pathParts, 1, walk)
					local folder = Data:GetFolder(walk)
					walk = folder and folder.parentId
				end
				status.groups[table.concat(pathParts, "\001")] = true
				self._userExpanded = self._userExpanded or {}
				self._userExpanded[table.concat(pathParts, "\001")] = true
			end
		end
		self:SelectFolder(parentId, true)
		self:RefreshAll()
		self:SetStatus("Folder created.")
	end)
end

function UI:CreateEntry(parentId)
	parentId = parentId or self.selectedFolderId or Data:GetRootId()
	if parentId == Data:GetRootId() then
		addon():Notify("Select a folder before creating an entry.", true)
		return
	end
	addon():PromptName("New entry name:", "New Entry", function(name)
		local id, err = Data:CreateEntry(parentId, name)
		if not id then
			addon():Notify(tostring(err), true)
			return
		end
		self:SelectFolder(parentId, true)
		self:RefreshAll()
		self:SelectEntry(id, true)
		self:SetStatus("Entry created.")
	end)
end

function UI:DeleteSelectedFolder(folderId)
	local id = folderId or self.selectedFolderId
	if not id or id == Data:GetRootId() then
		addon():Notify("Cannot delete the root folder.", true)
		return
	end
	local folder = Data:GetFolder(id)
	if not folder then
		return
	end
	addon():ConfirmDelete(
		string.format("Delete folder \"%s\" and all of its contents?", folder.name),
		function()
			local parentId = folder.parentId
			Data:DeleteFolder(id)
			self.selectedEntryId = nil
			self:ClearDirty()
			self:SelectFolder(parentId, true)
			self:RefreshAll()
			self:SetStatus("Folder deleted.")
		end
	)
end

function UI:DeleteSelectedEntry(entryId)
	local id = entryId or self.selectedEntryId
	if not id then
		return
	end
	local entry = Data:GetEntry(id)
	if not entry then
		return
	end
	addon():ConfirmDelete(
		string.format("Delete entry \"%s\"?", entry.name),
		function()
			local parentId = entry.parentId
			Data:DeleteEntry(id)
			self.selectedEntryId = nil
			self:ClearDirty()
			self:LoadEntryIntoEditor(nil)
			self:SelectFolder(parentId, true)
			self:RefreshAll()
			self:SetStatus("Entry deleted.")
		end
	)
end

function UI:RenameSelectedEntry(entryId)
	local id = entryId or self.selectedEntryId
	local entry = Data:GetEntry(id)
	if not entry then
		return
	end
	addon():PromptName("Rename entry:", entry.name, function(name)
		local ok, err = Data:UpdateEntry(id, { name = name })
		if not ok then
			addon():Notify(err, true)
		else
			self:ClearDirty()
		end
		self:RefreshAll()
		if self.selectedEntryId == id then
			self:LoadEntryIntoEditor(Data:GetEntry(id))
		end
	end)
end

function UI:DuplicateSelectedEntry(entryId)
	local id = entryId or self.selectedEntryId
	if not id then
		return
	end
	self:WithUnsavedGuard(function()
		local newId, err = Data:DuplicateEntry(id)
		if not newId then
			addon():Notify(tostring(err), true)
			return
		end
		self:RefreshAll()
		self:SelectEntry(newId, true)
		self:SetStatus("Entry duplicated.")
	end)
end

function UI:RenameSelectedFolder(folderId)
	local id = folderId or self.selectedFolderId
	if not id or id == Data:GetRootId() then
		addon():Notify("Cannot rename the root folder.", true)
		return
	end
	local folder = Data:GetFolder(id)
	if not folder then
		return
	end
	addon():PromptName("Rename folder:", folder.name, function(name)
		local ok, err = Data:RenameFolder(id, name)
		if not ok then
			addon():Notify(err, true)
			return
		end
		self:RefreshAll()
	end)
end

function UI:MoveSelectedIntoFolder(entryId)
	local movingEntry = entryId or self.selectedEntryId
	if not movingEntry then
		return
	end

	addon():PromptName("Move into folder (full path or name):", "", function(targetName)
		targetName = targetName and targetName:match("^%s*(.-)%s*$") or ""
		if targetName == "" then
			return
		end
		local destId = self:FindFolderByNameOrPath(targetName)
		if not destId then
			addon():Notify("Destination folder not found.", true)
			return
		end
		local ok, err = Data:MoveEntry(movingEntry, destId)
		if not ok then
			addon():Notify(err, true)
		else
			self:SelectFolder(destId, true)
			self:SelectEntry(movingEntry, true)
			self:RefreshAll()
			self:SetStatus("Entry moved.")
		end
	end)
end

function UI:FindFolderByNameOrPath(text)
	-- Exact path match first, then unique name match.
	local lower = text:lower()
	local nameMatch = nil
	local nameCount = 0
	for id, folder in pairs(Data.db.global.folders) do
		local path = Data:GetFolderPath(id)
		if path:lower() == lower then
			return id
		end
		if folder.name:lower() == lower then
			nameMatch = id
			nameCount = nameCount + 1
		end
	end
	if nameCount == 1 then
		return nameMatch
	end
	return nil
end

function UI:PickIcon()
	if not self.selectedEntryId then
		addon():Notify("Select an entry first.", true)
		self:SetStatus("Select an entry before choosing an icon.")
		return
	end
	local opened = Compat.ShowIconPicker(function(icon)
		self.currentIcon = Compat.NormalizeIcon(icon)
		if self.iconWidget then
			self.iconWidget:SetImage(Compat.GetIconTexture(self.currentIcon))
		end
		self:MarkDirty()
	end)
	if not opened then
		addon():PromptName("Icon texture name (e.g. INV_Misc_QuestionMark):", self.currentIcon or Compat.DefaultIcon(), function(icon)
			self.currentIcon = Compat.NormalizeIcon(icon)
			if self.iconWidget then
				self.iconWidget:SetImage(Compat.GetIconTexture(self.currentIcon))
			end
			self:MarkDirty()
		end)
	end
end

function UI:ShowIconPickerDialog(callback)
	if self.iconPickerFrame then
		AceGUI:Release(self.iconPickerFrame)
		self.iconPickerFrame = nil
	end
	if self.iconPickerTimer then
		addon():CancelTimer(self.iconPickerTimer)
		self.iconPickerTimer = nil
	end

	local filter = ""
	local iconList = {}
	local scrollOffset = 0
	local COLS = 10
	local ROWS = 8
	local CELL = 40
	local NUM_SHOWN = COLS * ROWS

	local frame = AceGUI:Create("Window")
	frame:SetTitle("Choose Icon")
	frame:SetLayout("List")
	frame:SetWidth(460)
	frame:SetHeight(480)
	frame:EnableResize(false)
	self.iconPickerFrame = frame

	if frame.frame then
		Compat.RaiseFrame(frame.frame)
	end

	local search = AceGUI:Create("EditBox")
	search:SetLabel("Spell name, spell ID, or texture name")
	search:SetFullWidth(true)
	search:DisableButton(true)
	search:SetText("")
	frame:AddChild(search)

	local status = AceGUI:Create("Label")
	status:SetFullWidth(true)
	status:SetText("")
	frame:AddChild(status)

	-- Native recycled grid (same idea as Blizzard's macro popup): full icon
	-- pool is scrollable; only a viewport of buttons exists.
	-- IMPORTANT: parent native frames to the Window frame, not an AceGUI
	-- SimpleGroup. AceGUI pools SimpleGroups — leftover children would reappear
	-- in Contents the next time RefreshList acquires one (e.g. on Save).
	local spacer = AceGUI:Create("SimpleGroup")
	spacer:SetFullWidth(true)
	spacer:SetHeight(ROWS * CELL + 4)
	spacer:SetLayout("Fill")
	frame:AddChild(spacer)

	local container = CreateFrame("Frame", nil, frame.frame)
	container:SetAllPoints(spacer.frame)

	local scrollBar = CreateFrame("Slider", nil, container, "UIPanelScrollBarTemplate")
	scrollBar:SetPoint("TOPLEFT", container, "TOPRIGHT", -18, -16)
	scrollBar:SetPoint("BOTTOMLEFT", container, "BOTTOMRIGHT", -18, 16)
	scrollBar:SetMinMaxValues(0, 0)
	scrollBar:SetValueStep(1)
	if scrollBar.SetObeyStepOnDrag then
		scrollBar:SetObeyStepOnDrag(true)
	end
	scrollBar:SetValue(0)

	local buttonParent = CreateFrame("Frame", nil, container)
	buttonParent:SetPoint("TOPLEFT")
	buttonParent:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -22, 0)
	buttonParent:EnableMouseWheel(true)

	-- Keep the grid aligned if AceGUI reflows the spacer.
	spacer.frame:HookScript("OnSizeChanged", function()
		if container then
			container:ClearAllPoints()
			container:SetAllPoints(spacer.frame)
		end
	end)

	local function destroyGrid()
		if not container then
			return
		end
		container:Hide()
		container:SetParent(nil)
		container:ClearAllPoints()
		container = nil
	end

	local function closePicker()
		if self.iconPickerTimer then
			addon():CancelTimer(self.iconPickerTimer)
			self.iconPickerTimer = nil
		end
		destroyGrid()
		AceGUI:Release(frame)
		self.iconPickerFrame = nil
	end

	local function selectIcon(icon)
		closePicker()
		callback(Compat.NormalizeIcon(icon))
	end

	local buttons = {}
	for i = 1, NUM_SHOWN do
		local btn = CreateFrame("Button", nil, buttonParent)
		btn:SetSize(CELL - 2, CELL - 2)
		local col = (i - 1) % COLS
		local row = math.floor((i - 1) / COLS)
		btn:SetPoint("TOPLEFT", buttonParent, "TOPLEFT", col * CELL, -row * CELL)
		local tex = btn:CreateTexture(nil, "ARTWORK")
		tex:SetAllPoints()
		btn.tex = tex
		btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
		btn:SetScript("OnClick", function(self)
			if self.iconValue ~= nil then
				selectIcon(self.iconValue)
			end
		end)
		btn:Hide()
		buttons[i] = btn
	end

	local function currentList()
		local q = filter:match("^%s*(.-)%s*$") or ""
		if q == "" then
			-- Full Blizzard macro UI icon pool, with "?" always first.
			local defaultIcon = Compat.DefaultIcon()
			local list = { defaultIcon }
			local pool = Compat.CollectMacroIcons()
			for i = 1, #pool do
				local icon = pool[i]
				local normalized = Compat.NormalizeIcon(icon)
				if normalized ~= defaultIcon and normalized ~= "INV_MISC_QUESTIONMARK"
					and tostring(icon) ~= "134400" then
					list[#list + 1] = icon
				end
			end
			return list
		end
		return Compat.ResolveIconSearch(q)
	end

	local function updateVisible()
		local totalRows = math.max(1, math.ceil(#iconList / COLS))
		local maxOffset = math.max(0, totalRows - ROWS)
		if scrollOffset > maxOffset then
			scrollOffset = maxOffset
		end
		for i = 1, NUM_SHOWN do
			local idx = scrollOffset * COLS + i
			local icon = iconList[idx]
			local btn = buttons[i]
			if icon ~= nil then
				btn.iconValue = icon
				btn.tex:SetTexture(type(icon) == "number" and icon or Compat.GetIconTexture(icon))
				btn:Show()
			else
				btn.iconValue = nil
				btn:Hide()
			end
		end
	end

	local function refreshGrid()
		iconList = currentList()
		local totalRows = math.max(1, math.ceil(#iconList / COLS))
		local maxOffset = math.max(0, totalRows - ROWS)
		scrollOffset = 0
		scrollBar:SetMinMaxValues(0, maxOffset)
		scrollBar:SetValue(0)
		if maxOffset > 0 then
			scrollBar:Show()
		else
			scrollBar:Hide()
		end
		updateVisible()

		if #iconList == 0 then
			status:SetText("No matching icons. Try a spell name, spell ID, or texture name.")
		else
			status:SetText(string.format("%d icons — click one to use it.", #iconList))
		end
	end

	scrollBar:SetScript("OnValueChanged", function(_, value)
		scrollOffset = math.floor(value + 0.5)
		updateVisible()
	end)

	buttonParent:SetScript("OnMouseWheel", function(_, delta)
		local _, maxOffset = scrollBar:GetMinMaxValues()
		scrollBar:SetValue(math.min(maxOffset, math.max(0, scrollOffset - delta)))
	end)

	frame:SetCallback("OnClose", function(widget)
		if self.iconPickerTimer then
			addon():CancelTimer(self.iconPickerTimer)
			self.iconPickerTimer = nil
		end
		destroyGrid()
		AceGUI:Release(widget)
		if self.iconPickerFrame == widget then
			self.iconPickerFrame = nil
		end
	end)

	search:SetCallback("OnTextChanged", function(_, _, text)
		filter = text or ""
		if self.iconPickerTimer then
			addon():CancelTimer(self.iconPickerTimer)
		end
		self.iconPickerTimer = addon():ScheduleTimer(function()
			self.iconPickerTimer = nil
			if self.iconPickerFrame then
				refreshGrid()
			end
		end, 0.15)
	end)

	search:SetCallback("OnEnterPressed", function(_, _, text)
		filter = text or ""
		local matches = Compat.ResolveIconSearch(filter)
		if #matches > 0 then
			selectIcon(matches[1])
		elseif filter:match("%S") then
			selectIcon(filter)
		end
	end)

	refreshGrid()
end

function UI:CreateBlizzardMacro(entryId)
	local id = entryId or self.selectedEntryId
	if not id then
		return
	end
	if id ~= self.selectedEntryId then
		self:SelectEntry(id, true)
	end
	-- Save first if dirty so macro uses latest text.
	if self:IsDirty() then
		if not self:SaveCurrentEntry() then
			return
		end
	end
	local entry = Data:GetEntry(id)
	if not entry then
		return
	end
	self:ShowMacroScopeDialog(function(perCharacter)
		local ok, message = MacroBridge:CreateFromEntry(entry, perCharacter)
		addon():Notify(message, not ok)
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
	frame:SetHeight(140)
	frame:SetCallback("OnClose", function(widget)
		AceGUI:Release(widget)
		if self.scopeFrame == widget then
			self.scopeFrame = nil
		end
	end)
	self.scopeFrame = frame

	local label = AceGUI:Create("Label")
	label:SetFullWidth(true)
	label:SetText("Choose macro type:")
	frame:AddChild(label)

	local globalBtn = AceGUI:Create("Button")
	globalBtn:SetText("Global Macro")
	globalBtn:SetFullWidth(true)
	globalBtn:SetCallback("OnClick", function()
		AceGUI:Release(frame)
		self.scopeFrame = nil
		callback(false)
	end)
	frame:AddChild(globalBtn)

	local charBtn = AceGUI:Create("Button")
	charBtn:SetText("Character Macro")
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
	frame:SetStatusText("Account-wide macro repository")
	frame:SetLayout("Flow")
	frame:SetWidth(1120)
	frame:SetHeight(640)
	frame:EnableResize(false)
	frame:SetCallback("OnClose", function(widget)
		if AceGUI:IsReleasing(widget) then
			return
		end
		if self.autoSaveTimer then
			addon():CancelTimer(self.autoSaveTimer)
			self.autoSaveTimer = nil
		end
		if self.searchTimer then
			addon():CancelTimer(self.searchTimer)
			self.searchTimer = nil
		end
		AceGUI:Release(widget)
		self.frame = nil
		self.treeGroup = nil
		self._treeSplitter = nil
		self._contentsSplitter = nil
		self.contentGroup = nil
		self.listContainer = nil
		self.detailContainer = nil
		self.listGroup = nil
		self.nameEdit = nil
		self.descEdit = nil
		self.bodyEdit = nil
		self.iconWidget = nil
		self.saveButton = nil
		self.searchEdit = nil
		self.searchClearButton = nil
		self.sortButton = nil
	end)
	self.frame = frame

	-- Toolbar
	local toolbar = AceGUI:Create("SimpleGroup")
	toolbar:SetFullWidth(true)
	toolbar:SetLayout("Flow")
	frame:AddChild(toolbar)

	local search = AceGUI:Create("EditBox")
	search:SetLabel("Search")
	search:SetWidth(260)
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
		-- Live search with light debounce via timer.
		if self.searchTimer then
			addon():CancelTimer(self.searchTimer)
		end
		self.searchTimer = addon():ScheduleTimer(function()
			self:RefreshList()
		end, 0.25)
	end)
	toolbar:AddChild(search)
	self.searchEdit = search

	-- Clear button inside the search box.
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

	-- Body: TreeGroup provides left tree; content holds list + detail.
	local body = AceGUI:Create("SimpleGroup")
	body:SetFullWidth(true)
	body:SetFullHeight(true)
	body:SetAutoAdjustHeight(false)
	body:SetLayout("Fill")
	frame:AddChild(body)

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
		-- uniquevalue is path with \001 separators; last segment is folder id.
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
		self:DecorateTreeAddButtons()
		self:EnsureTreeDragger()
		self:EnsureContentsDragger()
	end)
	-- Keep per-row "+" buttons in sync when the tree refreshes (expand/scroll).
	local origRefreshTree = tree.RefreshTree
	tree.RefreshTree = function(widget, ...)
		origRefreshTree(widget, ...)
		self:DecorateTreeAddButtons()
		self:EnsureTreeDragger()
		self:EnsureContentsDragger()
	end
	body:AddChild(tree)
	self.treeGroup = tree
	self:EnsureTreeDragger()

	-- Content area inside tree group: two columns.
	-- Absolute widths (synced by SyncPaneWidths) so a Contents/Entry splitter can resize them.
	local content = AceGUI:Create("SimpleGroup")
	content:SetFullWidth(true)
	content:SetFullHeight(true)
	content:SetAutoAdjustHeight(false)
	content:SetLayout("Flow")
	tree:AddChild(content)
	self.contentGroup = content

	-- Centre list
	local listContainer = AceGUI:Create("InlineGroup")
	listContainer:SetTitle("Folder contents")
	listContainer:SetWidth(320)
	listContainer:SetFullHeight(true)
	listContainer:SetAutoAdjustHeight(false)
	listContainer:SetLayout("Fill")
	content:AddChild(listContainer)
	self.listContainer = listContainer

	-- Place sort control beside the "Folder contents" title text.
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

	-- Right detail (scroll so editor controls stay inside the frame)
	local detail = AceGUI:Create("InlineGroup")
	detail:SetTitle("Entry")
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
	nameEdit:SetCallback("OnTextChanged", function()
		if not self.suppressDirty then self:MarkDirty() end
	end)
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

	local iconBtn = AceGUI:Create("Button")
	iconBtn:SetText("Choose Icon")
	iconBtn:SetWidth(120)
	iconBtn:SetCallback("OnClick", function() self:PickIcon() end)
	iconRow:AddChild(iconBtn)
	self.iconButton = iconBtn

	local descEdit = AceGUI:Create("EditBox")
	descEdit:SetLabel("Description / Notes")
	descEdit:SetFullWidth(true)
	descEdit:SetCallback("OnTextChanged", function()
		if not self.suppressDirty then self:MarkDirty() end
	end)
	detailScroll:AddChild(descEdit)
	self.descEdit = descEdit

	local bodyEdit = AceGUI:Create("MultiLineEditBox")
	bodyEdit:SetLabel("Text Content")
	bodyEdit:SetFullWidth(true)
	bodyEdit:SetNumLines(12)
	bodyEdit:DisableButton(true)
	bodyEdit:SetCallback("OnTextChanged", function()
		if not self.suppressDirty then self:MarkDirty() end
	end)
	detailScroll:AddChild(bodyEdit)
	self.bodyEdit = bodyEdit

	local actions = AceGUI:Create("SimpleGroup")
	actions:SetFullWidth(true)
	actions:SetLayout("Flow")
	detailScroll:AddChild(actions)

	local function actionBtn(text, width, onClick)
		local b = AceGUI:Create("Button")
		b:SetText(text)
		b:SetWidth(width)
		b:SetCallback("OnClick", onClick)
		actions:AddChild(b)
		return b
	end

	self.saveButton = actionBtn("Save", 80, function()
		self:SaveCurrentEntry()
	end)
	self.saveButton:SetDisabled(true)

	self.macroButton = actionBtn("Create Blizzard Macro", 160, function()
		self:CreateBlizzardMacro()
	end)

	self.dupEntryButton = actionBtn("Duplicate", 90, function()
		self:DuplicateSelectedEntry()
	end)

	self.delEntryButton = actionBtn("Delete", 80, function()
		self:DeleteSelectedEntry()
	end)

	-- Auto-save timer: periodically save if dirty and entry selected.
	self.autoSaveTimer = addon():ScheduleRepeatingTimer(function()
		if self.frame and self.frame.frame and self.frame.frame:IsShown()
			and self:IsDirty() and self.selectedEntryId then
			self:SaveCurrentEntry()
			if self.frame then
				self.frame:SetStatusText("Auto-saved.")
			end
		end
	end, 30)

	self:LoadEntryIntoEditor(nil)
	frame:SetStatusText("Ready — /scriptorium to toggle")

	-- AceGUI Flow lays out before TreeGroup content has a real width, which stacks
	-- Contents/Entry until a resize. Nudge width to force a second layout pass.
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

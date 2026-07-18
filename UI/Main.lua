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
	if self.copyButton then self.copyButton:SetDisabled(not enabled) end
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
	self._ignoreTreeSelect = true
	self.treeGroup:SelectByValue(unique)
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
	local folders, entries = Data:GetSortedChildren(folderId)

	local header = AceGUI:Create("Label")
	header:SetFullWidth(true)
	header:SetText("|cffffd100" .. Data:GetFolderPath(folderId) .. "|r")
	self.listGroup:AddChild(header)

	if #folders == 0 and #entries == 0 then
		local empty = AceGUI:Create("Label")
		empty:SetFullWidth(true)
		empty:SetText("This folder is empty.")
		self.listGroup:AddChild(empty)
		return
	end

	for _, folder in ipairs(folders) do
		self:AddListRow({
			kind = "folder",
			id = folder.id,
			label = "|cff66aaff[Folder]|r " .. folder.name,
			onClick = function()
				self:SelectFolder(folder.id)
			end,
			onDouble = function()
				self:SelectFolder(folder.id)
			end,
		})
	end

	for _, entry in ipairs(entries) do
		local selected = (entry.id == self.selectedEntryId)
		local prefix = selected and "|cff00ff00>|r " or ""
		self:AddListRow({
			kind = "entry",
			id = entry.id,
			label = prefix .. entry.name,
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
	local header = AceGUI:Create("Label")
	header:SetFullWidth(true)
	header:SetText("|cffffd100Search:|r " .. query)
	self.listGroup:AddChild(header)

	local results = Search:Query(query)
	if #results == 0 then
		local empty = AceGUI:Create("Label")
		empty:SetFullWidth(true)
		empty:SetText("No matching entries.")
		self.listGroup:AddChild(empty)
		return
	end

	for _, result in ipairs(results) do
		local entry = result.entry
		local selected = (entry.id == self.selectedEntryId)
		local prefix = selected and "|cff00ff00>|r " or ""
		local label = string.format("%s%s\n|cffaaaaaa%s|r", prefix, entry.name, result.path)
		self:AddListRow({
			kind = "entry",
			id = entry.id,
			label = label,
			height = 36,
			onClick = function()
				self:SelectEntry(entry.id)
			end,
			onDouble = function()
				self:SelectEntry(entry.id)
			end,
		})
	end
end

function UI:AddListRow(info)
	local btn = AceGUI:Create("InteractiveLabel")
	btn:SetFullWidth(true)
	btn:SetText(info.label)
	if info.height then
		btn:SetHeight(info.height)
	end
	btn:SetCallback("OnClick", function(_, _, button)
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
			self:ShowListContextMenu(info)
		end
	end)
	self.listGroup:AddChild(btn)
end

function UI:RefreshDetailEnabled()
	-- handled in LoadEntryIntoEditor
end

------------------------------------------------------------------------
-- Context menus / actions
------------------------------------------------------------------------

function UI:ShowListContextMenu(info)
	-- Lightweight action sheet via AceGUI window.
	if info.kind == "folder" then
		addon():PromptName("Rename folder:", Data:GetFolder(info.id).name, function(name)
			local ok, err = Data:RenameFolder(info.id, name)
			if not ok then
				addon():Notify(err, true)
			end
			self:RefreshAll()
		end)
	elseif info.kind == "entry" then
		-- Right-click selects then offers rename via prompt.
		self:SelectEntry(info.id, true)
		addon():PromptName("Rename entry:", Data:GetEntry(info.id).name, function(name)
			local ok, err = Data:UpdateEntry(info.id, { name = name })
			if not ok then
				addon():Notify(err, true)
			else
				self:ClearDirty()
			end
			self:RefreshAll()
			if self.selectedEntryId == info.id then
				self:LoadEntryIntoEditor(Data:GetEntry(info.id))
			end
		end)
	end
end

function UI:CreateFolder()
	local parentId = self.selectedFolderId or Data:GetRootId()
	addon():PromptName("New folder name:", "New Folder", function(name)
		local id, err = Data:CreateFolder(parentId, name)
		if not id then
			addon():Notify(err, true)
			return
		end
		self:SelectFolder(parentId, true)
		self:RefreshAll()
		self:SetStatus("Folder created.")
	end)
end

function UI:CreateEntry()
	local parentId = self.selectedFolderId or Data:GetRootId()
	addon():PromptName("New entry name:", "New Entry", function(name)
		local id, err = Data:CreateEntry(parentId, name)
		if not id then
			addon():Notify(tostring(err), true)
			return
		end
		self:RefreshAll()
		self:SelectEntry(id, true)
		self:SetStatus("Entry created.")
	end)
end

function UI:DeleteSelectedFolder()
	local id = self.selectedFolderId
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

function UI:DeleteSelectedEntry()
	local id = self.selectedEntryId
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

function UI:DuplicateSelectedEntry()
	local id = self.selectedEntryId
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

function UI:RenameSelectedFolder()
	local id = self.selectedFolderId
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

function UI:MoveFolderUp()
	if Data:ReorderFolder(self.selectedFolderId, -1) then
		self:RefreshAll()
	end
end

function UI:MoveFolderDown()
	if Data:ReorderFolder(self.selectedFolderId, 1) then
		self:RefreshAll()
	end
end

function UI:MoveSelectedIntoFolder()
	-- Prompt for destination folder by path list is complex; use name of folder ID path.
	-- Simple approach: prompt for destination folder name under root search.
	local movingFolder = self.selectedFolderId
	local movingEntry = self.selectedEntryId
	if not movingFolder and not movingEntry then
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
		if movingEntry then
			local ok, err = Data:MoveEntry(movingEntry, destId)
			if not ok then
				addon():Notify(err, true)
			else
				self:SelectFolder(destId, true)
				self:SelectEntry(movingEntry, true)
				self:RefreshAll()
				self:SetStatus("Entry moved.")
			end
		elseif movingFolder then
			local ok, err = Data:MoveFolder(movingFolder, destId)
			if not ok then
				addon():Notify(err, true)
			else
				self:SelectFolder(movingFolder, true)
				self:RefreshAll()
				self:SetStatus("Folder moved.")
			end
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

function UI:CopyText()
	if not self.bodyEdit then
		return
	end
	local edit = self.bodyEdit.editbox or self.bodyEdit
	-- AceGUI MultiLineEditBox exposes .editBox
	local box = self.bodyEdit.editBox
	if box then
		box:SetFocus()
		box:HighlightText()
		self:SetStatus("Text selected — press Ctrl+C to copy.")
	else
		self:SetStatus("Select text in the editor and press Ctrl+C.")
	end
end

function UI:CreateBlizzardMacro()
	if not self.selectedEntryId then
		return
	end
	-- Save first if dirty so macro uses latest text.
	if self:IsDirty() then
		if not self:SaveCurrentEntry() then
			return
		end
	end
	local entry = Data:GetEntry(self.selectedEntryId)
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
	frame:SetWidth(960)
	frame:SetHeight(640)
	frame:EnableResize(true)
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
		self.listGroup = nil
		self.nameEdit = nil
		self.descEdit = nil
		self.bodyEdit = nil
		self.iconWidget = nil
		self.saveButton = nil
		self.searchEdit = nil
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
	search:SetCallback("OnEnterPressed", function(widget, event, text)
		self.searchQuery = text or ""
		self:RefreshList()
	end)
	search:SetCallback("OnTextChanged", function(widget, event, text)
		self.searchQuery = text or ""
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

	local function toolButton(text, width, onClick)
		local b = AceGUI:Create("Button")
		b:SetText(text)
		b:SetWidth(width or 100)
		b:SetCallback("OnClick", onClick)
		toolbar:AddChild(b)
		return b
	end

	toolButton("New Folder", 100, function() self:CreateFolder() end)
	toolButton("New Entry", 100, function() self:CreateEntry() end)
	toolButton("Rename Folder", 110, function() self:RenameSelectedFolder() end)
	toolButton("Delete Folder", 110, function() self:DeleteSelectedFolder() end)
	toolButton("Move…", 70, function() self:MoveSelectedIntoFolder() end)
	toolButton("Up", 50, function() self:MoveFolderUp() end)
	toolButton("Down", 55, function() self:MoveFolderDown() end)
	self.sortButton = toolButton(
		Data:GetSortMode() == "name" and "Sort: Name" or "Sort: Modified",
		120,
		function() self:ToggleSortMode() end
	)

	-- Body: TreeGroup provides left tree; content holds list + detail.
	local body = AceGUI:Create("SimpleGroup")
	body:SetFullWidth(true)
	body:SetHeight(520)
	body:SetLayout("Fill")
	frame:AddChild(body)

	local tree = AceGUI:Create("TreeGroup")
	tree:SetFullWidth(true)
	tree:SetFullHeight(true)
	tree:SetLayout("Flow")
	tree:SetTreeWidth(220, true)
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
	body:AddChild(tree)
	self.treeGroup = tree

	-- Content area inside tree group: two columns
	local content = AceGUI:Create("SimpleGroup")
	content:SetFullWidth(true)
	content:SetFullHeight(true)
	content:SetLayout("Flow")
	tree:AddChild(content)

	-- Centre list
	local listContainer = AceGUI:Create("InlineGroup")
	listContainer:SetTitle("Contents")
	listContainer:SetWidth(280)
	listContainer:SetFullHeight(true)
	listContainer:SetLayout("Fill")
	content:AddChild(listContainer)

	local listScroll = AceGUI:Create("ScrollFrame")
	listScroll:SetLayout("List")
	listContainer:AddChild(listScroll)
	self.listGroup = listScroll

	-- Right detail
	local detail = AceGUI:Create("InlineGroup")
	detail:SetTitle("Entry")
	detail:SetWidth(400)
	detail:SetFullHeight(true)
	detail:SetLayout("List")
	content:AddChild(detail)

	local nameEdit = AceGUI:Create("EditBox")
	nameEdit:SetLabel("Name")
	nameEdit:SetFullWidth(true)
	nameEdit:SetCallback("OnTextChanged", function()
		if not self.suppressDirty then self:MarkDirty() end
	end)
	detail:AddChild(nameEdit)
	self.nameEdit = nameEdit

	local iconRow = AceGUI:Create("SimpleGroup")
	iconRow:SetFullWidth(true)
	iconRow:SetLayout("Flow")
	detail:AddChild(iconRow)

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
	detail:AddChild(descEdit)
	self.descEdit = descEdit

	local bodyEdit = AceGUI:Create("MultiLineEditBox")
	bodyEdit:SetLabel("Text Content")
	bodyEdit:SetFullWidth(true)
	bodyEdit:SetNumLines(14)
	bodyEdit:DisableButton(true)
	bodyEdit:SetCallback("OnTextChanged", function()
		if not self.suppressDirty then self:MarkDirty() end
	end)
	detail:AddChild(bodyEdit)
	self.bodyEdit = bodyEdit

	local actions = AceGUI:Create("SimpleGroup")
	actions:SetFullWidth(true)
	actions:SetLayout("Flow")
	detail:AddChild(actions)

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

	self.copyButton = actionBtn("Copy Text", 100, function()
		self:CopyText()
	end)

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
end

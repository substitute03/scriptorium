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

--- Add a "+" control on each visible folder row to create a child folder,
--- and wire right-click context menus for rename/delete.
function UI:DecorateTreeAddButtons()
	local tree = self.treeGroup
	if not tree or not tree.buttons then
		return
	end
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
			end)
			button._scriptoriumMenuHooked = true
		end

		local addBtn = button._scriptoriumAdd
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
			if button.text then
				button.text:SetPoint("RIGHT", addBtn, "LEFT", -4, 2)
			end
		elseif addBtn then
			addBtn:Hide()
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
	pathLabel:SetWidth(230)
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
    btn:SetFontObject(GameFontHighlight)
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
			self:ShowListContextMenu(btn.frame, info)
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
			local renameBtn = rootDescription:CreateButton("Rename Folder", function()
				self:RenameSelectedFolder(folderId)
			end)
			local deleteBtn = rootDescription:CreateButton("Delete Folder", function()
				self:DeleteSelectedFolder(folderId)
			end)
			if isRoot then
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
			end
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

local ICON_PICKER_PAGE = 120

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

	local frame = AceGUI:Create("Window")
	frame:SetTitle("Choose Icon")
	frame:SetLayout("List")
	frame:SetWidth(460)
	frame:SetHeight(480)
	frame:EnableResize(false)
	self.iconPickerFrame = frame

	-- Keep picker above the main Scriptorium window.
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
	status:SetText("Default icon shown — type to search for more.")
	frame:AddChild(status)

	local scroll = AceGUI:Create("ScrollFrame")
	scroll:SetFullWidth(true)
	scroll:SetHeight(340)
	scroll:SetLayout("Flow")
	frame:AddChild(scroll)

	local onCacheUpdate

	local function closePicker()
		if onCacheUpdate then
			Compat.UnregisterSpellIconCacheListener(onCacheUpdate)
		end
		if self.iconPickerTimer then
			addon():CancelTimer(self.iconPickerTimer)
			self.iconPickerTimer = nil
		end
		AceGUI:Release(frame)
		self.iconPickerFrame = nil
	end

	local function selectIcon(icon)
		closePicker()
		callback(Compat.NormalizeIcon(icon))
	end

	local function addIconButton(icon)
		local btn = AceGUI:Create("Icon")
		btn:SetLabel(nil)
		btn:SetImage(type(icon) == "number" and icon or Compat.GetIconTexture(icon))
		btn:SetImageSize(36, 36)
		btn:SetWidth(40)
		btn:SetCallback("OnClick", function()
			selectIcon(icon)
		end)
		scroll:AddChild(btn)
	end

	local function refreshGrid()
		scroll:ReleaseChildren()
		local q = filter:match("^%s*(.-)%s*$") or ""
		local defaultIcon = Compat.DefaultIcon()

		-- Always show the "?" icon first.
		addIconButton(defaultIcon)
		local shown = 1

		if q == "" then
			local _, _, done = Compat.GetSpellIconCacheProgress()
			if done then
				status:SetText("Default icon shown — type a spell name to search.")
			else
				status:SetText("Indexing spell icons… type a name anytime (e.g. Stealth).")
			end
			return
		end

		local matches = Compat.ResolveIconSearch(q)
		for i = 1, #matches do
			local icon = matches[i]
			-- Skip duplicates of the default question-mark icon.
			local normalized = Compat.NormalizeIcon(icon)
			if normalized ~= defaultIcon and normalized ~= "INV_MISC_QUESTIONMARK"
				and tostring(icon) ~= "134400" then
				addIconButton(icon)
				shown = shown + 1
				if shown >= ICON_PICKER_PAGE then
					break
				end
			end
		end

		local _, _, done = Compat.GetSpellIconCacheProgress()
		if shown == 1 then
			if done then
				status:SetText("No matching spell icons found. Try another name or spell ID.")
			else
				status:SetText("Still indexing spell icons… results will update automatically.")
			end
		else
			local suffix = done and "" or " (still indexing…)"
			status:SetText(string.format("Showing %d result(s). Click an icon to use it.%s", shown, suffix))
		end
	end

	onCacheUpdate = function()
		if self.iconPickerFrame and filter:match("%S") then
			refreshGrid()
		end
	end
	Compat.RegisterSpellIconCacheListener(onCacheUpdate)
	Compat.StartSpellIconCache()

	frame:SetCallback("OnClose", function(widget)
		if onCacheUpdate then
			Compat.UnregisterSpellIconCacheListener(onCacheUpdate)
		end
		if self.iconPickerTimer then
			addon():CancelTimer(self.iconPickerTimer)
			self.iconPickerTimer = nil
		end
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

	self.sortButton = toolButton(
		Data:GetSortMode() == "name" and "Sort: Name" or "Sort: Modified",
		120,
		function() self:ToggleSortMode() end
	)

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
	tree:SetTreeWidth(220, false)
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
	-- Keep per-row "+" buttons in sync when the tree refreshes (expand/scroll).
	local origRefreshTree = tree.RefreshTree
	tree.RefreshTree = function(widget, ...)
		origRefreshTree(widget, ...)
		self:DecorateTreeAddButtons()
	end
	body:AddChild(tree)
	self.treeGroup = tree

	-- Content area inside tree group: two columns
	local content = AceGUI:Create("SimpleGroup")
	content:SetFullWidth(true)
	content:SetFullHeight(true)
	content:SetAutoAdjustHeight(false)
	content:SetLayout("Flow")
	tree:AddChild(content)

	-- Centre list
	local listContainer = AceGUI:Create("InlineGroup")
	listContainer:SetTitle("Contents")
	listContainer:SetWidth(280)
	listContainer:SetFullHeight(true)
	listContainer:SetAutoAdjustHeight(false)
	listContainer:SetLayout("Fill")
	content:AddChild(listContainer)

	local listScroll = AceGUI:Create("ScrollFrame")
	listScroll:SetLayout("List")
	listContainer:AddChild(listScroll)
	self.listGroup = listScroll

	-- Right detail (scroll so editor controls stay inside the frame)
	local detail = AceGUI:Create("InlineGroup")
	detail:SetTitle("Entry")
	detail:SetWidth(400)
	detail:SetFullHeight(true)
	detail:SetAutoAdjustHeight(false)
	detail:SetLayout("Fill")
	content:AddChild(detail)

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
end

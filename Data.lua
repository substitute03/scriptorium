--- Data.lua
--- Folder + macro repository (account-wide via AceDB global).
--- Tree is a mirror of Blizzard macros; Blizzard remains the source of truth.
local ADDON_NAME, ns = ...
local Compat = ns.Compat

local Data = {}
ns.Data = Data

local ROOT_ID = "root"
Data.GENERAL_MACROS_NAME = "General Macros"
Data.CHARACTER_MACROS_NAME = "Character Macros"

local defaults = {
	global = {
		version = 2,
		nextId = 1,
		sortMode = "name", -- "name" | "modified"
		syncOnLogin = true,
		syncOnMacroUpdate = true,
		rootId = ROOT_ID,
		folders = {
			[ROOT_ID] = {
				id = ROOT_ID,
				name = "Macros",
				parentId = nil,
				children = {},
				entries = {},
			},
		},
		entries = {
			-- [id] = { id, name, icon, text, created, modified, parentId }
		},
	},
}

function Data:Init(db)
	self.db = db
	self:_EnsureSchema()
end

function Data:GetDefaults()
	return defaults
end

function Data:_EnsureSchema()
	local g = self.db.global
	if not g.folders[ROOT_ID] then
		g.folders[ROOT_ID] = {
			id = ROOT_ID,
			name = "Macros",
			parentId = nil,
			children = {},
			entries = {},
		}
	else
		g.folders[ROOT_ID].name = "Macros"
		g.folders[ROOT_ID].entries = g.folders[ROOT_ID].entries or {}
	end
	g.rootId = ROOT_ID
	g.entries = g.entries or {}
	g.nextId = g.nextId or 1
	g.sortMode = g.sortMode or "name"
	g.version = g.version or 1
	if g.syncOnLogin == nil then
		g.syncOnLogin = true
	end
	if g.syncOnMacroUpdate == nil then
		g.syncOnMacroUpdate = true
	end
	-- Drop legacy description field from existing macros.
	for _, entry in pairs(g.entries) do
		entry.description = nil
	end
end

function Data:_NextId(prefix)
	local g = self.db.global
	local id = prefix .. tostring(g.nextId)
	g.nextId = g.nextId + 1
	return id
end

function Data:GetRootId()
	return self.db.global.rootId or ROOT_ID
end

function Data:GetSortMode()
	return self.db.global.sortMode or "name"
end

function Data:SetSortMode(mode)
	if mode == "name" or mode == "modified" then
		self.db.global.sortMode = mode
	end
end

function Data:GetSyncOnLogin()
	local v = self.db.global.syncOnLogin
	if v == nil then
		return true
	end
	return v and true or false
end

function Data:SetSyncOnLogin(enabled)
	self.db.global.syncOnLogin = enabled and true or false
end

function Data:GetSyncOnMacroUpdate()
	local v = self.db.global.syncOnMacroUpdate
	if v == nil then
		return true
	end
	return v and true or false
end

function Data:SetSyncOnMacroUpdate(enabled)
	self.db.global.syncOnMacroUpdate = enabled and true or false
end

function Data:GetFolder(id)
	return self.db.global.folders[id]
end

function Data:GetEntry(id)
	return self.db.global.entries[id]
end

--- True if parent already has a child folder with this name (case-insensitive).
--- @param excludeId string|nil folder id to ignore
function Data:FolderNameExistsInParent(parentId, name, excludeId)
	local parent = self:GetFolder(parentId)
	if not parent or not name then
		return false
	end
	local lower = name:lower()
	for _, childId in ipairs(parent.children) do
		if childId ~= excludeId then
			local child = self:GetFolder(childId)
			if child and child.name:lower() == lower then
				return true
			end
		end
	end
	return false
end

--- Find a direct child folder by name (case-insensitive).
function Data:FindChildFolderByName(parentId, name)
	local parent = self:GetFolder(parentId)
	if not parent or not name then
		return nil
	end
	local lower = name:lower()
	for _, childId in ipairs(parent.children) do
		local child = self:GetFolder(childId)
		if child and child.name:lower() == lower then
			return childId, child
		end
	end
	return nil
end

--- Find or create a child folder with the given name.
function Data:EnsureFolder(parentId, name)
	local existingId, existing = self:FindChildFolderByName(parentId, name)
	if existingId then
		-- Keep the canonical display name.
		if existing.name ~= name then
			existing.name = name
		end
		return existingId, existing
	end
	return self:CreateFolder(parentId, name)
end

function Data:CreateFolder(parentId, name)
	local parent = self:GetFolder(parentId)
	if not parent then
		return nil, "Parent folder not found"
	end
	name = name and name:match("^%s*(.-)%s*$") or "New Folder"
	if name == "" then
		name = "New Folder"
	end
	if self:FolderNameExistsInParent(parentId, name) then
		return nil, string.format("A folder named \"%s\" already exists here.", name)
	end

	local id = self:_NextId("f")
	local folder = {
		id = id,
		name = name,
		parentId = parentId,
		children = {},
		entries = {},
	}
	self.db.global.folders[id] = folder
	parent.children[#parent.children + 1] = id
	return id, folder
end

function Data:DeleteFolder(id)
	if id == self:GetRootId() then
		return false, "Cannot delete the root folder"
	end
	local folder = self:GetFolder(id)
	if not folder then
		return false, "Folder not found"
	end

	local childIds = {}
	for i, childId in ipairs(folder.children) do
		childIds[i] = childId
	end
	for _, childId in ipairs(childIds) do
		self:DeleteFolder(childId)
	end
	local entryIds = {}
	for i, entryId in ipairs(folder.entries) do
		entryIds[i] = entryId
	end
	for _, entryId in ipairs(entryIds) do
		self:DeleteEntry(entryId, true)
	end

	local parent = self:GetFolder(folder.parentId)
	if parent then
		self:_RemoveFromList(parent.children, id)
	end
	self.db.global.folders[id] = nil
	return true
end

--- Remove root-level folders that are not part of the managed macro layout.
function Data:PruneUnmanagedRootFolders()
	local root = self:GetFolder(self:GetRootId())
	if not root then
		return
	end
	local keep = {
		[self.GENERAL_MACROS_NAME:lower()] = true,
		[self.CHARACTER_MACROS_NAME:lower()] = true,
	}
	local toDelete = {}
	for _, childId in ipairs(root.children) do
		local child = self:GetFolder(childId)
		if child and not keep[child.name:lower()] then
			toDelete[#toDelete + 1] = childId
		end
	end
	for _, childId in ipairs(toDelete) do
		self:DeleteFolder(childId)
	end
end

function Data:CreateEntry(parentId, name)
	if parentId == self:GetRootId() then
		return nil, "Cannot add macros to the root Macros node"
	end
	local parent = self:GetFolder(parentId)
	if not parent then
		return nil, "Parent folder not found"
	end
	name = name and name:match("^%s*(.-)%s*$") or "New Macro"
	if name == "" then
		name = "New Macro"
	end

	local now = Compat.GetTime()
	local id = self:_NextId("e")
	local entry = {
		id = id,
		name = name,
		icon = Compat.DefaultIcon(),
		text = "",
		created = now,
		modified = now,
		parentId = parentId,
	}
	self.db.global.entries[id] = entry
	parent.entries[#parent.entries + 1] = id
	return id, entry
end

function Data:UpdateEntry(id, fields)
	local entry = self:GetEntry(id)
	if not entry then
		return false, "Macro not found"
	end
	if fields.name ~= nil then
		local name = tostring(fields.name):match("^%s*(.-)%s*$")
		if name == "" then
			return false, "Name cannot be empty"
		end
		entry.name = name
	end
	if fields.icon ~= nil then
		entry.icon = Compat.NormalizeIcon(fields.icon)
	end
	if fields.text ~= nil then
		entry.text = fields.text
	end
	entry.modified = Compat.GetTime()
	return true
end

function Data:DeleteEntry(id, skipParentUpdate)
	local entry = self:GetEntry(id)
	if not entry then
		return false, "Macro not found"
	end
	if not skipParentUpdate then
		local parent = self:GetFolder(entry.parentId)
		if parent then
			self:_RemoveFromList(parent.entries, id)
		end
	end
	self.db.global.entries[id] = nil
	return true
end

--- Find a macro entry in a folder by exact name.
function Data:FindEntryByNameInFolder(folderId, name)
	local folder = self:GetFolder(folderId)
	if not folder or not name then
		return nil
	end
	for _, entryId in ipairs(folder.entries) do
		local entry = self:GetEntry(entryId)
		if entry and entry.name == name then
			return entryId, entry
		end
	end
	return nil
end

--- Reconcile a folder's macros against a Blizzard macro list (add/update/delete).
--- @param macros { { name, icon, body }, ... }
--- @return added, updated, removed
function Data:ReconcileFolderMacros(folderId, macros)
	local folder = self:GetFolder(folderId)
	if not folder then
		return 0, 0, 0
	end

	local seen = {}
	local added, updated = 0, 0

	for _, macro in ipairs(macros or {}) do
		local name = macro.name
		if name and name ~= "" then
			local icon = Compat.NormalizeIcon(macro.icon)
			local body = macro.body or ""
			local entryId, entry = self:FindEntryByNameInFolder(folderId, name)
			if entry then
				seen[entryId] = true
				local needsUpdate = entry.icon ~= icon or entry.text ~= body
				if needsUpdate then
					self:UpdateEntry(entryId, {
						icon = icon,
						text = body,
					})
					updated = updated + 1
				end
			else
				local newId = self:CreateEntry(folderId, name)
				if newId then
					self:UpdateEntry(newId, {
						icon = icon,
						text = body,
					})
					seen[newId] = true
					added = added + 1
				end
			end
		end
	end

	local removed = 0
	local toDelete = {}
	for _, entryId in ipairs(folder.entries) do
		if not seen[entryId] then
			toDelete[#toDelete + 1] = entryId
		end
	end
	for _, entryId in ipairs(toDelete) do
		self:DeleteEntry(entryId)
		removed = removed + 1
	end

	return added, updated, removed
end

function Data:GetFolderPath(folderId)
	local parts = {}
	local id = folderId
	while id do
		local folder = self:GetFolder(id)
		if not folder then
			break
		end
		table.insert(parts, 1, folder.name)
		id = folder.parentId
	end
	return table.concat(parts, " > ")
end

--- Slash path for address-bar edit mode. Root name is omitted by default.
function Data:GetFolderSlashPath(folderId, includeRoot)
	local parts = {}
	local id = folderId
	local rootId = self:GetRootId()
	while id do
		local folder = self:GetFolder(id)
		if not folder then
			break
		end
		if includeRoot or id ~= rootId then
			table.insert(parts, 1, folder.name)
		end
		id = folder.parentId
	end
	return table.concat(parts, "/")
end

--- Breadcrumb segments from root to folderId: { id, name } in order.
function Data:GetFolderBreadcrumbs(folderId)
	local parts = {}
	local id = folderId or self:GetRootId()
	while id do
		local folder = self:GetFolder(id)
		if not folder then
			break
		end
		table.insert(parts, 1, { id = id, name = folder.name })
		id = folder.parentId
	end
	return parts
end

function Data:NormalizePathSegments(pathText)
	if not pathText then
		return {}
	end
	local text = tostring(pathText):match("^%s*(.-)%s*$") or ""
	text = text:gsub("\\", "/")
	text = text:gsub("/+", "/")
	text = text:gsub("^/", ""):gsub("/$", "")
	if text == "" then
		return {}
	end
	local segments = {}
	for part in text:gmatch("[^/]+") do
		segments[#segments + 1] = part
	end
	local root = self:GetFolder(self:GetRootId())
	local rootName = root and root.name and root.name:lower() or "macros"
	if #segments > 0 and segments[1]:lower() == rootName then
		table.remove(segments, 1)
	end
	return segments
end

function Data:ResolveFolderPath(pathText)
	local segments = self:NormalizePathSegments(pathText)
	local currentId = self:GetRootId()
	for _, segment in ipairs(segments) do
		local parent = self:GetFolder(currentId)
		if not parent then
			return nil
		end
		local lower = segment:lower()
		local found
		for _, childId in ipairs(parent.children) do
			local child = self:GetFolder(childId)
			if child and child.name:lower() == lower then
				found = childId
				break
			end
		end
		if not found then
			return nil
		end
		currentId = found
	end
	return currentId
end

--- Hierarchical path autocomplete for a partial slash path.
function Data:GetPathCompletions(partialPath, limit)
	limit = limit or 12
	local text = tostring(partialPath or ""):match("^%s*(.-)%s*$") or ""
	text = text:gsub("\\", "/")
	local trailingSlash = text:match("/$")
	text = text:gsub("/+", "/")
	text = text:gsub("^/", "")

	local rawParts = {}
	if text ~= "" then
		for part in text:gmatch("[^/]+") do
			rawParts[#rawParts + 1] = part
		end
	end

	local root = self:GetFolder(self:GetRootId())
	local rootName = root and root.name or "Macros"
	local rootLower = rootName:lower()
	local includeRootPrefix = (#rawParts > 0 and rawParts[1]:lower() == rootLower)
		or (text:lower():match("^" .. rootLower .. "/") ~= nil)

	local segments = {}
	for i, part in ipairs(rawParts) do
		if not (i == 1 and part:lower() == rootLower) then
			segments[#segments + 1] = part
		end
	end

	local prefixSegments = {}
	local partial = ""
	if trailingSlash then
		for _, part in ipairs(segments) do
			prefixSegments[#prefixSegments + 1] = part
		end
	elseif #segments > 0 then
		for i = 1, #segments - 1 do
			prefixSegments[#prefixSegments + 1] = segments[i]
		end
		partial = segments[#segments] or ""
	end

	local parentId = self:GetRootId()
	for _, segment in ipairs(prefixSegments) do
		local parent = self:GetFolder(parentId)
		if not parent then
			return {}
		end
		local lower = segment:lower()
		local found
		for _, childId in ipairs(parent.children) do
			local child = self:GetFolder(childId)
			if child and child.name:lower() == lower then
				found = childId
				break
			end
		end
		if not found then
			return {}
		end
		parentId = found
	end

	local parent = self:GetFolder(parentId)
	if not parent then
		return {}
	end

	local partialLower = partial:lower()
	local matches = {}
	for _, childId in ipairs(parent.children) do
		local child = self:GetFolder(childId)
		if child then
			local name = child.name
			if partialLower == "" or name:lower():sub(1, #partialLower) == partialLower then
				local pathParts = {}
				for _, seg in ipairs(prefixSegments) do
					pathParts[#pathParts + 1] = seg
				end
				pathParts[#pathParts + 1] = name
				local path = table.concat(pathParts, "/")
				if includeRootPrefix then
					path = rootName .. "/" .. path
				end
				matches[#matches + 1] = { path = path, folderId = childId, name = name }
			end
		end
	end

	table.sort(matches, function(a, b)
		return a.name:lower() < b.name:lower()
	end)

	local results = {}
	for i = 1, math.min(limit, #matches) do
		results[i] = matches[i]
	end
	return results
end

function Data:GetEntryPath(entryId)
	local entry = self:GetEntry(entryId)
	if not entry then
		return ""
	end
	return self:GetFolderPath(entry.parentId)
end

--- True if this folder is a character leaf under Character Macros / <Realm>.
function Data:IsCharacterFolder(folderId)
	local folder = self:GetFolder(folderId)
	if not folder or folderId == self:GetRootId() then
		return false
	end
	if #(folder.children or {}) > 0 then
		return false
	end
	local realm = self:GetFolder(folder.parentId)
	if not realm then
		return false
	end
	local charRoot = self:GetFolder(realm.parentId)
	if not charRoot or charRoot.name ~= self.CHARACTER_MACROS_NAME then
		return false
	end
	local root = self:GetFolder(charRoot.parentId)
	return root ~= nil and root.id == self:GetRootId()
end

--- Collect macros in a folder (leaf folders only; no recursion).
function Data:CollectEntries(folderId)
	local results = {}
	local folder = self:GetFolder(folderId)
	if not folder or folderId == self:GetRootId() then
		return results
	end
	for _, entryId in ipairs(folder.entries) do
		local entry = self:GetEntry(entryId)
		if entry then
			results[#results + 1] = entry
		end
	end
	return results
end

function Data:GetSortedChildren(folderId)
	local folder = self:GetFolder(folderId)
	if not folder then
		return {}, {}
	end

	local folders = {}
	for _, childId in ipairs(folder.children) do
		local child = self:GetFolder(childId)
		if child then
			folders[#folders + 1] = child
		end
	end

	local entries = {}
	for _, entryId in ipairs(folder.entries) do
		local entry = self:GetEntry(entryId)
		if entry then
			entries[#entries + 1] = entry
		end
	end

	local mode = self:GetSortMode()
	if mode == "modified" then
		table.sort(folders, function(a, b)
			return a.name:lower() < b.name:lower()
		end)
		table.sort(entries, function(a, b)
			if a.modified == b.modified then
				return a.name:lower() < b.name:lower()
			end
			return (a.modified or 0) > (b.modified or 0)
		end)
	else
		table.sort(folders, function(a, b)
			return a.name:lower() < b.name:lower()
		end)
		table.sort(entries, function(a, b)
			return a.name:lower() < b.name:lower()
		end)
	end

	return folders, entries
end

function Data:BuildTree()
	local classIconTexture = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes"

	local function buildNode(folderId)
		local folder = self:GetFolder(folderId)
		if not folder then
			return nil
		end
		local isRoot = folderId == self:GetRootId()
		local isLeaf = #(folder.children or {}) == 0
		local text
		if isRoot then
			text = "|cffffd100" .. folder.name .. "|r"
		elseif isLeaf then
			local entryCount = 0
			for _, entryId in ipairs(folder.entries) do
				if self:GetEntry(entryId) then
					entryCount = entryCount + 1
				end
			end
			text = string.format("%s (%d)", folder.name, entryCount)
		else
			text = folder.name
		end
		local node = {
			value = folderId,
			text = text,
		}
		-- Character folders store classFile from login sync.
		if folder.classFile and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[folder.classFile] then
			node.icon = classIconTexture
			node.iconCoords = CLASS_ICON_TCOORDS[folder.classFile]
		end
		if #folder.children > 0 then
			node.children = {}
			local kids = {}
			for _, childId in ipairs(folder.children) do
				local child = self:GetFolder(childId)
				if child then
					kids[#kids + 1] = child
				end
			end
			local function folderSortKey(f)
				if f.name == self.GENERAL_MACROS_NAME then
					return "0"
				end
				if f.name == self.CHARACTER_MACROS_NAME then
					return "1"
				end
				return "2" .. f.name:lower()
			end
			table.sort(kids, function(a, b)
				return folderSortKey(a) < folderSortKey(b)
			end)
			for _, child in ipairs(kids) do
				local childNode = buildNode(child.id)
				if childNode then
					node.children[#node.children + 1] = childNode
				end
			end
		end
		return node
	end

	local root = buildNode(self:GetRootId())
	return root and { root } or {}
end

function Data:_RemoveFromList(list, id)
	for i = #list, 1, -1 do
		if list[i] == id then
			table.remove(list, i)
			return true
		end
	end
	return false
end

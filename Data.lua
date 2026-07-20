--- Data.lua
--- Repository model: folders + entries (account-wide via AceDB global).
local ADDON_NAME, ns = ...
local Compat = ns.Compat

local Data = {}
ns.Data = Data

local ROOT_ID = "root"

local defaults = {
	global = {
		version = 1,
		nextId = 1,
		sortMode = "name", -- "name" | "modified"
		rootId = ROOT_ID,
		folders = {
			[ROOT_ID] = {
				id = ROOT_ID,
				name = "Folders",
				parentId = nil,
				children = {}, -- ordered folder ids
				entries = {}, -- ordered entry ids
			},
		},
		entries = {
			-- [id] = { id, name, icon, description, text, created, modified, parentId }
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
			name = "Folders",
			parentId = nil,
			children = {},
			entries = {},
		}
	else
		-- Root is a container for folders only, not entries.
		g.folders[ROOT_ID].name = g.folders[ROOT_ID].name or "Folders"
		g.folders[ROOT_ID].entries = g.folders[ROOT_ID].entries or {}
	end
	g.rootId = ROOT_ID
	g.entries = g.entries or {}
	g.nextId = g.nextId or 1
	g.sortMode = g.sortMode or "name"
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

function Data:GetFolder(id)
	return self.db.global.folders[id]
end

function Data:GetEntry(id)
	return self.db.global.entries[id]
end

--- True if parent already has a child folder with this name (case-insensitive).
--- @param excludeId string|nil folder id to ignore (for rename)
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
		-- Future: tags, colour, etc.
	}
	self.db.global.folders[id] = folder
	parent.children[#parent.children + 1] = id
	return id, folder
end

function Data:RenameFolder(id, name)
	if id == self:GetRootId() then
		return false, "Cannot rename the root folder"
	end
	local folder = self:GetFolder(id)
	if not folder then
		return false, "Folder not found"
	end
	name = name and name:match("^%s*(.-)%s*$") or ""
	if name == "" then
		return false, "Name cannot be empty"
	end
	if self:FolderNameExistsInParent(folder.parentId, name, id) then
		return false, string.format("A folder named \"%s\" already exists here.", name)
	end
	folder.name = name
	return true
end

function Data:DeleteFolder(id)
	if id == self:GetRootId() then
		return false, "Cannot delete the root folder"
	end
	local folder = self:GetFolder(id)
	if not folder then
		return false, "Folder not found"
	end

	-- Recursively delete children and entries (copy lists first).
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

function Data:MoveFolder(id, newParentId, index)
	if id == self:GetRootId() then
		return false, "Cannot move the root folder"
	end
	local folder = self:GetFolder(id)
	local newParent = self:GetFolder(newParentId)
	if not folder or not newParent then
		return false, "Folder not found"
	end
	if id == newParentId then
		return false, "Cannot move a folder into itself"
	end
	-- Prevent moving into a descendant.
	local walk = newParentId
	while walk do
		if walk == id then
			return false, "Cannot move a folder into its descendant"
		end
		local f = self:GetFolder(walk)
		walk = f and f.parentId
	end

	local oldParent = self:GetFolder(folder.parentId)
	if newParentId ~= folder.parentId and self:FolderNameExistsInParent(newParentId, folder.name) then
		return false, string.format("A folder named \"%s\" already exists here.", folder.name)
	end
	if oldParent then
		self:_RemoveFromList(oldParent.children, id)
	end
	folder.parentId = newParentId
	index = index or (#newParent.children + 1)
	index = math.max(1, math.min(index, #newParent.children + 1))
	table.insert(newParent.children, index, id)
	return true
end

function Data:CreateEntry(parentId, name)
	if parentId == self:GetRootId() then
		return nil, "Cannot add entries to the root Folders node"
	end
	local parent = self:GetFolder(parentId)
	if not parent then
		return nil, "Parent folder not found"
	end
	name = name and name:match("^%s*(.-)%s*$") or "New Entry"
	if name == "" then
		name = "New Entry"
	end

	local now = Compat.GetTime()
	local id = self:_NextId("e")
	local entry = {
		id = id,
		name = name,
		icon = Compat.DefaultIcon(),
		description = "",
		text = "",
		created = now,
		modified = now,
		parentId = parentId,
		-- Future: tags = {}, favourite = false, history = {}, template = false
	}
	self.db.global.entries[id] = entry
	parent.entries[#parent.entries + 1] = id
	return id, entry
end

function Data:UpdateEntry(id, fields)
	local entry = self:GetEntry(id)
	if not entry then
		return false, "Entry not found"
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
	if fields.description ~= nil then
		entry.description = fields.description
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
		return false, "Entry not found"
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

function Data:DuplicateEntry(id)
	local entry = self:GetEntry(id)
	if not entry then
		return nil, "Entry not found"
	end
	local newId, newEntry = self:CreateEntry(entry.parentId, entry.name .. " Copy")
	if not newId then
		return nil, newEntry
	end
	newEntry.icon = entry.icon
	newEntry.description = entry.description
	newEntry.text = entry.text
	newEntry.modified = Compat.GetTime()
	return newId, newEntry
end

function Data:MoveEntry(id, newParentId, index)
	if newParentId == self:GetRootId() then
		return false, "Cannot move entries into the root Folders node"
	end
	local entry = self:GetEntry(id)
	local newParent = self:GetFolder(newParentId)
	if not entry or not newParent then
		return false, "Not found"
	end
	local oldParent = self:GetFolder(entry.parentId)
	if oldParent then
		self:_RemoveFromList(oldParent.entries, id)
	end
	entry.parentId = newParentId
	entry.modified = Compat.GetTime()
	index = index or (#newParent.entries + 1)
	index = math.max(1, math.min(index, #newParent.entries + 1))
	table.insert(newParent.entries, index, id)
	return true
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
--- @param includeRoot boolean|nil when true, prefix with the root folder name
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

--- Normalize a typed path into lowercase path segments (root name stripped).
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
	local rootName = root and root.name and root.name:lower() or "folders"
	if #segments > 0 and segments[1]:lower() == rootName then
		table.remove(segments, 1)
	end
	return segments
end

--- Resolve a typed slash path to a folder id (case-insensitive).
--- Empty / root-only paths resolve to the root folder.
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
--- @return suggestions { { path = "Macros/Mage", folderId = "..." }, ... }
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
	local rootName = root and root.name or "Folders"
	local rootLower = rootName:lower()
	local includeRootPrefix = (#rawParts > 0 and rawParts[1]:lower() == rootLower)
		or (text:lower():match("^" .. rootLower .. "/") ~= nil)

	-- Work with segments relative to root (strip optional root token).
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

--- Collect entries in a folder, optionally walking child folders depth-first.
function Data:CollectEntries(folderId, includeChildren)
	local results = {}
	local function walk(id)
		local folder = self:GetFolder(id)
		if not folder then
			return
		end
		if id ~= self:GetRootId() then
			for _, entryId in ipairs(folder.entries) do
				local entry = self:GetEntry(entryId)
				if entry then
					results[#results + 1] = entry
				end
			end
		end
		if includeChildren then
			for _, childId in ipairs(folder.children) do
				walk(childId)
			end
		end
	end
	walk(folderId)
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
	local function buildNode(folderId)
		local folder = self:GetFolder(folderId)
		if not folder then
			return nil
		end
		local isRoot = folderId == self:GetRootId()
		local entryCount = 0
		if not isRoot then
			for _, entryId in ipairs(folder.entries) do
				if self:GetEntry(entryId) then
					entryCount = entryCount + 1
				end
			end
		end
		local node = {
			value = folderId,
			text = isRoot and ("|cffffd100" .. folder.name .. "|r") or string.format("%s (%d)", folder.name, entryCount),
		}
		if #folder.children > 0 then
			node.children = {}
			-- Preserve stored order for tree; sort alphabetically for consistency.
			local kids = {}
			for _, childId in ipairs(folder.children) do
				local child = self:GetFolder(childId)
				if child then
					kids[#kids + 1] = child
				end
			end
			table.sort(kids, function(a, b)
				return a.name:lower() < b.name:lower()
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

function Data:_IndexOf(list, id)
	for i, v in ipairs(list) do
		if v == id then
			return i
		end
	end
	return nil
end

local M = {}
local git_states = require("dotnet-workspace-explorer.git_states")
local Git = {}
Git.__index = Git
local legacy_capability = "workspace.git.status"
local version_two_capability = "workspace.git.status.v2"

local function integer(value)
	return type(value) == "number" and value >= 0 and value % 1 == 0
end

local function exact_map(value, keys)
	if type(value) ~= "table" or vim.islist(value) then
		return false
	end
	local count = 0
	for key in pairs(value) do
		if not keys[key] then
			return false
		end
		count = count + 1
	end
	return count == vim.tbl_count(keys)
end

local function snapshot(result, version_two)
	if
		not exact_map(result, {
			available = true,
			workspaceRevision = true,
			statusRevision = true,
			decorations = true,
		})
		or type(result.available) ~= "boolean"
		or not integer(result.workspaceRevision)
		or not integer(result.statusRevision)
		or type(result.decorations) ~= "table"
		or not vim.islist(result.decorations)
	then
		return nil
	end
	local decorations, seen = {}, {}
	for _, decoration in ipairs(result.decorations) do
		local keys = version_two and { nodeId = true, states = true } or { nodeId = true, state = true }
		local states = version_two and git_states.normalize(decoration.states, false)
			or git_states.legacy(decoration.state)
		if
			not exact_map(decoration, keys)
			or type(decoration.nodeId) ~= "string"
			or decoration.nodeId == ""
			or not states
			or seen[decoration.nodeId]
		then
			return nil
		end
		seen[decoration.nodeId], decorations[decoration.nodeId] = true, states
	end
	if not result.available and next(decorations) ~= nil then
		return nil
	end
	return decorations
end

function Git.new(options)
	options.workspace.decorations = {}
	return setmetatable({
		workspace = options.workspace,
		is_live = options.is_live,
		on_error = options.on_error,
		on_render = options.on_render,
		inflight = false,
		trailing = false,
		status_revision = -1,
		enabled = true,
		valid = true,
	}, Git)
end

function Git:_live()
	return self.valid and self.enabled and self.is_live()
end

function Git:_capable()
	return self.workspace:has_capability(version_two_capability)
		or self.workspace:has_capability(legacy_capability)
end

function Git:_version_two()
	return self.workspace:has_capability(version_two_capability)
end

function Git:_clear(render)
	local changed = next(self.workspace.decorations or {}) ~= nil
	self.workspace.decorations = {}
	self.status_revision, self.inflight, self.trailing = -1, false, false
	if changed and render and self.valid and self.is_live() then
		self.on_render()
	end
end

function Git:start()
	if not self:_live() or not self:_capable() or self.group then
		return
	end
	self.group = vim.api.nvim_create_augroup("DotnetWorkspaceExplorerGit", { clear = true })
	vim.api.nvim_create_autocmd({ "BufWritePost", "FocusGained" }, {
		group = self.group,
		callback = function()
			self:request()
		end,
	})
	self:request()
end

function Git:request()
	if not self:_live() or not self:_capable() or self.workspace.phase ~= "ready" then
		return
	end
	if self.inflight then
		self.trailing = true
		return
	end
	self.inflight = true
	local revision = self.workspace.revision
	self.workspace:request(
		"workspace/git/status",
		{ expectedRevision = revision },
		function(err, result)
			if not self:_live() then
				return
			end
			self.inflight = false
			local decorations = not err and snapshot(result, self:_version_two()) or nil
			if err then
				self.on_error(err)
			elseif not decorations then
				self.on_error({
					code = "incompatible_git_status",
					message = "The workspace Git status response is incompatible.",
				})
			elseif
				result.workspaceRevision == self.workspace.revision
				and result.statusRevision > self.status_revision
			then
				self.status_revision = result.statusRevision
				self.workspace.decorations = decorations
				self.on_render()
			end
			if self.trailing then
				self.trailing = false
				self:request()
			end
		end
	)
end

function Git:disable(render)
	if self.group then
		pcall(vim.api.nvim_del_augroup_by_id, self.group)
	end
	self.group = nil
	self.enabled = false
	self:_clear(render)
end

function Git:is_enabled()
	return self.valid and self.enabled
end

function Git:invalidate()
	self:disable(false)
	self.valid = false
end

M.Git = Git

return M

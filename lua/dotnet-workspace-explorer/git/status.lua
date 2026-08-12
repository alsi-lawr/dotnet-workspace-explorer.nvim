local protocol = require("dotnet-workspace-explorer.protocol.git")

local M = {}
local GitStatus = {}
GitStatus.__index = GitStatus

local capability = "workspace.git.status"

---@class DweGitStatusOptions
---@field workspace DweWorkspaceTree
---@field is_live fun(): boolean
---@field on_error fun(problem: DweProblem)
---@field on_render fun()

---Creates a Git-decoration synchronizer for one workspace session.
---@param options DweGitStatusOptions
---@return table
function GitStatus.new(options)
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
	}, GitStatus)
end

function GitStatus:_live()
	return self.valid and self.enabled and self.is_live()
end

function GitStatus:_capable()
	return self.workspace:has_capability(capability)
end

---@param render boolean
function GitStatus:_clear(render)
	local changed = next(self.workspace.decorations or {}) ~= nil
	self.workspace.decorations = {}
	self.status_revision, self.inflight, self.trailing = -1, false, false
	if changed and render and self.valid and self.is_live() then
		self.on_render()
	end
end

---Begins refresh-on-write/focus tracking and performs the initial request.
function GitStatus:start()
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

---Requests a fresh Git decoration snapshot, coalescing overlapping requests.
function GitStatus:request()
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
			local decorations = not err and protocol.snapshot(result) or nil
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

---@param render boolean
function GitStatus:disable(render)
	if self.group then
		pcall(vim.api.nvim_del_augroup_by_id, self.group)
	end
	self.group = nil
	self.enabled = false
	self:_clear(render)
end

---@return boolean
function GitStatus:is_enabled()
	return self.valid and self.enabled
end

function GitStatus:invalidate()
	self:disable(false)
	self.valid = false
end

M.Git = GitStatus
return M

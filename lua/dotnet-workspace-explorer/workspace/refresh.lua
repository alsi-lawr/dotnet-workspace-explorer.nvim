local errors = require("dotnet-workspace-explorer.workspace.errors")
local M = {}
local noop = function() end

---Requests a server refresh and then reconciles the invalidated tree.
---@param self table
---@param callback? DweErrorFirstCallback
---@param retried? boolean
function M.refresh(self, callback, retried)
	callback = callback or noop
	local generation, epoch, workspace_id = self.client.generation, self.epoch, self.workspace_id
	local expected_revision = self.revision
	local function same_session()
		return self.client.generation == generation
			and not self.client.inert
			and self.workspace_id == workspace_id
	end
	local function retry_after_reconcile()
		if not same_session() then
			return callback(errors.stale())
		end
		local function resume(err)
			if err then
				return callback(err)
			end
			if not same_session() then
				return callback(errors.stale())
			end
			self:refresh(callback, true)
		end
		if self.reconciling or self.reconcile_queued then
			self.reconcile_waiters[#self.reconcile_waiters + 1] = resume
		else
			resume()
		end
	end
	self.client:request(
		"workspace/refresh",
		{ expectedRevision = expected_revision },
		function(err, result)
			if not self:_valid(generation, epoch, workspace_id) then
				if not retried and same_session() then
					return retry_after_reconcile()
				end
				return callback(errors.stale())
			end
			if err then
				if err.code == "workspace_conflict" then
					self:_invalidate()
					if not retried then
						return retry_after_reconcile()
					end
				end
				return callback(err)
			end
			if
				type(result) ~= "table"
				or type(result.revision) ~= "number"
				or result.revision < expected_revision
				or type(result.reset) ~= "boolean"
			then
				self:_invalidate()
				return callback(errors.stale())
			end
			self:_invalidate()
			callback(nil, result)
		end
	)
end

---Schedules a reconciliation if a completed mutation advanced the revision.
---@param self table
---@param revision integer
function M.mutation_completed(self, revision)
	local generation, workspace_id = self.client.generation, self.workspace_id
	vim.schedule(function()
		if
			self.client.generation == generation
			and not self.client.inert
			and self.workspace_id == workspace_id
			and self.revision < revision
			and not self.reconciling
		then
			self:_invalidate()
		end
	end)
end

return M

local commands = require("dotnet-workspace-explorer.protocol.commands")
local confirmation = require("dotnet-workspace-explorer.ui.confirmation")
local rpc = require("dotnet-workspace-explorer.rpc")

local M = {}

---Describes, previews, confirms, and executes `workspace.addExisting`.
---@param self table
function M.confirm(self)
	if not self:is_active() or self.confirming or self.executing then
		return
	end
	self.on_selected(self)
	if #self.mark_order == 0 then
		return self.on_error(
			rpc.problem(
				"empty_selection",
				"Press Space on an available file or directory before confirming Add Existing."
			)
		)
	end

	local captured = self.generation
	local request = {
		commandId = "workspace.addExisting",
		targetNodeId = self.target_id,
		arguments = {
			selectorId = self.selector_id,
			entryIds = vim.deepcopy(self.mark_order),
		},
		expectedRevision = self.revision,
	}
	self.confirming = true
	self.workspace:request("workspace/commands/describe", {
		commandId = request.commandId,
		targetNodeId = request.targetNodeId,
	}, function(err, result)
		if not self:_live(captured) then
			return
		end
		if err then
			return self:_fail(err)
		end
		if not commands.compatible_descriptor(result, request.commandId, self.target_kind) then
			return self:_fail(
				rpc.problem(
					"incompatible_command",
					"The Add Existing command descriptor is incompatible."
				)
			)
		end
		self.workspace:request("workspace/commands/preview", request, function(preview_err, preview)
			if not self:_live(captured) then
				return
			end
			if preview_err then
				return self:_fail(preview_err)
			end
			if not commands.compatible_preview(preview) then
				return self:_fail(
					rpc.problem(
						"incompatible_preview",
						"The Add Existing command preview is incompatible."
					)
				)
			end
			confirmation.yes_no(commands.effects_prompt(preview), function(confirmed)
				if not self:_live(captured) then
					return
				end
				self.confirming = false
				if not confirmed then
					return
				end
				local execute = vim.deepcopy(request)
				execute.confirmationToken = preview.confirmationToken
				self.executing = true
				self.workspace:request(
					"workspace/commands/execute",
					execute,
					function(execute_err, applied)
						if not self:_live(captured) then
							return
						end
						if execute_err then
							return self:_fail(execute_err)
						end
						if not commands.compatible_applied(applied) then
							return self:_fail(
								rpc.problem(
									"incompatible_result",
									"The Add Existing result is incompatible."
								)
							)
						end
						self:_exit(false, nil, applied.revision)
					end
				)
			end)
		end)
	end)
end

return M

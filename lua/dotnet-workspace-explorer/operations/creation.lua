local commands = require("dotnet-workspace-explorer.protocol.commands")

local M = {}

local required_capabilities = {
	"workspace.commands.describe",
	"workspace.commands.preview",
	"workspace.commands.execute",
	"workspace.create.options",
	"workspace.operations.completed",
}

---Prompts for a contextual creation option and executes it.
---@param self table
function M.run(self)
	if not self:_live() then
		return
	end
	if not self:_supports(required_capabilities) then
		return self:_fail({
			code = "unsupported_capability",
			message = "The workspace does not support contextual creation.",
		})
	end

	local target_id = self.selected()
	local node = target_id and self.workspace:get_node(target_id)
	if not node then
		return self:_fail({ code = "unknown_node", message = "Select a workspace node first." })
	end
	local revision = self.workspace.revision
	self.workspace:request("workspace/create/options", {
		targetNodeId = target_id,
		expectedRevision = revision,
	}, function(err, result)
		if not self:_live() then
			return
		end
		if err then
			return self:_fail(err)
		end
		if
			not commands.compatible_creation_options(
				result,
				revision,
				self.workspace:has_capability("workspace.addExisting.selector"),
				node.kind
			)
		then
			return self:_fail({
				code = "incompatible_options",
				message = "The workspace creation options are incompatible.",
			})
		end

		vim.ui.select(result.options, {
			prompt = "New",
			kind = "workspace-create-option",
			format_item = function(option)
				if option.description == "" then
					return option.displayName
				end
				return option.displayName .. " — " .. option.description
			end,
		}, function(option)
			if not self:_live() or option == nil then
				return
			end
			if option.kind == "addExisting" then
				if not self.on_add_existing then
					return self:_fail({
						code = "unsupported_capability",
						message = "The Add Existing selector is unavailable.",
					})
				end
				return self.on_add_existing({
					selection_id = option.selectionId,
					target_id = target_id,
					target_kind = node.kind,
					revision = revision,
				})
			end
			vim.ui.input({ prompt = option.displayName .. " name: " }, function(name)
				if not self:_live() or name == nil then
					return
				end
				self:_describe("workspace.create", target_id, node.kind, function()
					self:_preview({
						commandId = "workspace.create",
						targetNodeId = target_id,
						arguments = {
							selectionId = option.selectionId,
							name = name,
						},
						expectedRevision = revision,
					}, option.execution)
				end)
			end)
		end)
	end)
end

return M

local commands = require("dotnet-workspace-explorer.protocol.commands")
local confirmation = require("dotnet-workspace-explorer.ui.confirmation")

local M = {}
local Editing = {}
Editing.__index = Editing

local required_capabilities = {
	"workspace.commands.describe",
	"workspace.commands.preview",
	"workspace.commands.execute",
}

---@class DweEditingOptions
---@field workspace DweWorkspaceTree
---@field is_live fun(): boolean
---@field selected fun(): DweNodeId?
---@field on_error fun(problem: DweProblem)
---@field on_render fun()
---@field on_success fun(revision: integer)

---Creates the rename/copy/move workflow for one workspace session.
---@param options DweEditingOptions
---@return table
function Editing.new(options)
	local workspace = options.workspace
	workspace.mark_mode, workspace.marks = nil, {}
	return setmetatable({
		workspace = workspace,
		is_live = options.is_live,
		selected = options.selected,
		on_error = options.on_error,
		on_render = options.on_render,
		on_success = options.on_success,
		order = {},
		valid = true,
	}, Editing)
end

---@return boolean
function Editing:_live()
	return self.valid and self.is_live()
end

---@param problem DweProblem
function Editing:_fail(problem)
	if self:_live() then
		self.on_error(problem)
	end
end

---@return boolean
function Editing:_supports()
	for _, capability in ipairs(required_capabilities) do
		if not self.workspace:has_capability(capability) then
			return false
		end
	end
	return true
end

function Editing:_render()
	if self:_live() then
		self.on_render()
	end
end

---@param render boolean
function Editing:_clear(render)
	local changed = self.workspace.mark_mode ~= nil or next(self.workspace.marks) ~= nil
	self.workspace.mark_mode, self.workspace.marks, self.order = nil, {}, {}
	if changed and render then
		self:_render()
	end
end

---Clears the current move/copy mark set.
function Editing:clear()
	if self:_live() then
		self:_clear(true)
	end
end

---Toggles the selected node in a move or copy mark set.
---@param mode DweEditMode
function Editing:toggle(mode)
	if not self:_live() then
		return
	end
	local id = self.selected()
	if not id or not self.workspace:get_node(id) then
		return self:_fail({ code = "unknown_node", message = "Select a workspace node first." })
	end
	if self.workspace.mark_mode ~= mode then
		self.workspace.mark_mode, self.workspace.marks, self.order = mode, {}, {}
	end
	if self.workspace.marks[id] then
		self.workspace.marks[id] = nil
		for index, marked in ipairs(self.order) do
			if marked == id then
				table.remove(self.order, index)
				break
			end
		end
		if #self.order == 0 then
			self.workspace.mark_mode = nil
		end
	else
		self.workspace.marks[id] = true
		self.order[#self.order + 1] = id
	end
	self:_render()
end

---Removes marks whose nodes disappeared during reconciliation.
function Editing:reconcile()
	if not self.valid then
		return
	end
	local order, marks = {}, {}
	for _, id in ipairs(self.order) do
		if self.workspace:get_node(id) then
			order[#order + 1], marks[id] = id, true
		end
	end
	self.order, self.workspace.marks = order, marks
	if #order == 0 then
		self.workspace.mark_mode = nil
	end
end

---@param command_id string
---@param target_id DweNodeId
---@param arguments table
---@param confirm string
---@param clear_marks boolean
---@param compact? boolean
function Editing:_run(command_id, target_id, arguments, confirm, clear_marks, compact)
	if not self:_supports() then
		return self:_fail({
			code = "unsupported_capability",
			message = "The workspace does not support contextual editing.",
		})
	end
	local node = self.workspace:get_node(target_id)
	if not node then
		return self:_fail({ code = "unknown_node", message = "Select a workspace node first." })
	end
	local revision = self.workspace.revision
	self.workspace:request("workspace/commands/describe", {
		commandId = command_id,
		targetNodeId = target_id,
	}, function(err, descriptor)
		if not self:_live() then
			return
		end
		if err then
			return self:_fail(err)
		end
		if not commands.compatible_descriptor(descriptor, command_id, node.kind) then
			return self:_fail({
				code = "incompatible_command",
				message = "The workspace command descriptor is incompatible.",
			})
		end
		local request = {
			commandId = command_id,
			targetNodeId = target_id,
			arguments = arguments,
			expectedRevision = revision,
		}
		self.workspace:request(
			"workspace/commands/preview",
			request,
			function(preview_error, preview)
				if not self:_live() then
					return
				end
				if preview_error then
					return self:_fail(preview_error)
				end
				if not commands.compatible_preview(preview) then
					return self:_fail({
						code = "incompatible_preview",
						message = "The workspace command preview is incompatible.",
					})
				end
				local function execute(choice)
					if not self:_live() or choice ~= confirm then
						return
					end
					local execute_request = vim.deepcopy(request)
					execute_request.confirmationToken = preview.confirmationToken
					self.workspace:request(
						"workspace/commands/execute",
						execute_request,
						function(execute_error, result)
							if not self:_live() then
								return
							end
							if execute_error then
								return self:_fail(execute_error)
							end
							if not commands.compatible_applied(result) then
								return self:_fail({
									code = "incompatible_result",
									message = "The workspace command result is incompatible.",
								})
							end
							if clear_marks then
								self:_clear(true)
							end
							self.on_success(result.revision)
						end
					)
				end
				if compact then
					confirmation.yes_no(commands.effects_prompt(preview), function(confirmed)
						execute(confirmed and confirm or nil)
					end)
				else
					vim.ui.select({ confirm, "Cancel" }, {
						prompt = commands.effects_prompt(preview),
						kind = "confirmation",
					}, execute)
				end
			end
		)
	end)
end

---Prompts for and applies a new name to the selected node.
function Editing:rename()
	if not self:_live() then
		return
	end
	local target_id = self.selected()
	local node = target_id and self.workspace:get_node(target_id)
	if not node then
		return self:_fail({ code = "unknown_node", message = "Select a workspace node first." })
	end
	vim.ui.input({ prompt = "New name: ", default = node.name }, function(name)
		if not self:_live() or name == nil then
			return
		end
		self:_run("workspace.rename", target_id, { name = name }, "Rename", false, true)
	end)
end

---Moves or copies the marked nodes into the selected destination.
function Editing:place()
	if not self:_live() then
		return
	end
	local mode = self.workspace.mark_mode
	if not mode or #self.order == 0 then
		return self:_fail({ code = "no_marks", message = "Mark one or more workspace nodes first." })
	end
	local target_id = self.selected()
	if not target_id then
		return self:_fail({ code = "unknown_node", message = "Select a destination first." })
	end
	self:_run(
		"workspace." .. mode,
		target_id,
		{ sourceNodeIds = vim.deepcopy(self.order) },
		mode == "move" and "Move" or "Copy",
		true
	)
end

function Editing:invalidate()
	self.valid = false
	self:_clear(false)
end

M.Editing = Editing
return M

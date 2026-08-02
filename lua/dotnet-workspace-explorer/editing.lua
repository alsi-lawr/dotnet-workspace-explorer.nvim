local M = {}
local confirmation = require("dotnet-workspace-explorer.confirmation")
local Editing = {}
Editing.__index = Editing

local required_capabilities = {
	"workspace.commands.describe",
	"workspace.commands.preview",
	"workspace.commands.execute",
}

local effect_operations = {
	create = true,
	modify = true,
	trash = true,
	rename = true,
	move = true,
	moveInSolution = true,
	copy = true,
	addToProject = true,
	removeFromProject = true,
	addToSolution = true,
	removeFromSolution = true,
}

local function map(value)
	return type(value) == "table" and not vim.islist(value)
end

local function exact(value, keys)
	if not map(value) then
		return false
	end
	for key in pairs(value) do
		if keys[key] == nil then
			return false
		end
	end
	for key, required in pairs(keys) do
		if required and value[key] == nil then
			return false
		end
	end
	return true
end

local function nonempty(value)
	return type(value) == "string" and value ~= ""
end

local function string_list(value)
	if type(value) ~= "table" or not vim.islist(value) then
		return false
	end
	local seen = {}
	for _, item in ipairs(value) do
		if not nonempty(item) or seen[item] then
			return false
		end
		seen[item] = true
	end
	return true
end

local function compatible_descriptor(result, command_id, target_kind)
	if not exact(result, { command = true }) then
		return false
	end
	local command = result.command
	if
		not exact(command, {
			id = true,
			name = true,
			access = true,
			parameters = true,
			targetKinds = true,
		})
		or command.id ~= command_id
		or not nonempty(command.name)
		or command.access ~= "write"
		or not string_list(command.targetKinds)
		or type(command.parameters) ~= "table"
		or not vim.islist(command.parameters)
	then
		return false
	end
	local targets = {}
	for _, kind in ipairs(command.targetKinds) do
		targets[kind] = true
	end
	if not targets[target_kind] then
		return false
	end
	local parameter_id = command_id == "workspace.rename" and "name" or "sourceNodeIds"
	local parameter_type = command_id == "workspace.rename" and "text" or "nodeIdArray"
	if #command.parameters ~= 1 then
		return false
	end
	local parameter = command.parameters[1]
	return exact(parameter, { id = true, name = true, type = true, required = true })
		and parameter.id == parameter_id
		and nonempty(parameter.name)
		and parameter.type == parameter_type
		and parameter.required == true
end

local function compatible_preview(result)
	if
		not exact(result, {
			confirmationToken = true,
			expiresAtUtc = true,
			summary = true,
			effects = true,
		})
		or not nonempty(result.confirmationToken)
		or not nonempty(result.expiresAtUtc)
		or not nonempty(result.summary)
		or type(result.effects) ~= "table"
		or not vim.islist(result.effects)
	then
		return false
	end
	for _, effect in ipairs(result.effects) do
		if
			not exact(effect, { operation = true, target = true, recursive = true })
			or not effect_operations[effect.operation]
			or not nonempty(effect.target)
			or type(effect.recursive) ~= "boolean"
		then
			return false
		end
	end
	return true
end

local function compatible_applied(result)
	return exact(result, { applied = true, revision = true })
		and result.applied == true
		and type(result.revision) == "number"
		and result.revision >= 0
		and result.revision % 1 == 0
end

local function prompt(preview)
	local lines = { preview.summary }
	for _, effect in ipairs(preview.effects) do
		lines[#lines + 1] = ("• %s %s%s"):format(
			effect.operation,
			effect.target,
			effect.recursive and " (recursive)" or ""
		)
	end
	return table.concat(lines, "\n")
end

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

function Editing:_live()
	return self.valid and self.is_live()
end

function Editing:_fail(problem)
	if self:_live() then
		self.on_error(problem)
	end
end

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

function Editing:_clear(render)
	local changed = self.workspace.mark_mode ~= nil or next(self.workspace.marks) ~= nil
	self.workspace.mark_mode, self.workspace.marks, self.order = nil, {}, {}
	if changed and render then
		self:_render()
	end
end

function Editing:clear()
	if self:_live() then
		self:_clear(true)
	end
end

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
		if not compatible_descriptor(descriptor, command_id, node.kind) then
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
		self.workspace:request("workspace/commands/preview", request, function(preview_error, preview)
			if not self:_live() then
				return
			end
			if preview_error then
				return self:_fail(preview_error)
			end
			if not compatible_preview(preview) then
				return self:_fail({
					code = "incompatible_preview",
					message = "The workspace command preview is incompatible.",
				})
			end
			local function run_execute(choice)
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
						if not compatible_applied(result) then
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
				confirmation.yes_no(prompt(preview), function(confirmed)
					run_execute(confirmed and confirm or nil)
				end)
			else
				vim.ui.select({ confirm, "Cancel" }, {
					prompt = prompt(preview),
					kind = "confirmation",
				}, run_execute)
			end
		end)
	end)
end

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

local M = {}

local UINT32_MAX = 4294967295
local capabilities = {
	"workspace.root",
	"workspace.children",
	"workspace.refresh",
	"workspace.delta",
	"workspace.reset",
	"workspace.create.options",
	"workspace.commands.list",
	"workspace.commands.describe",
	"workspace.commands.preview",
	"workspace.commands.execute",
	"workspace.operations.completed",
}
local method_capabilities = {
	["workspace/root"] = "workspace.root",
	["workspace/children"] = "workspace.children",
	["workspace/refresh"] = "workspace.refresh",
	["workspace/create/options"] = "workspace.create.options",
	["workspace/commands/list"] = "workspace.commands.list",
	["workspace/commands/describe"] = "workspace.commands.describe",
	["workspace/commands/preview"] = "workspace.commands.preview",
	["workspace/commands/execute"] = "workspace.commands.execute",
}
local generation = 0
local active

local function problem(code, message, data)
	return { code = code, message = message, data = data }
end

local function empty()
	return vim.empty_dict()
end

local function default_spawn(command, options, on_exit)
	return vim.system(command, options, on_exit)
end

local Client = {}
Client.__index = Client

function Client.new(options)
	if
		not (vim.mpack and vim.mpack.encode and vim.mpack.Unpacker and vim.system and vim.empty_dict)
	then
		error("dotnet-workspace-explorer: Neovim lacks binary MessagePack process support", 2)
	end
	if
		options.max_page_size ~= nil
		and (
			type(options.max_page_size) ~= "number"
			or options.max_page_size % 1 ~= 0
			or options.max_page_size < 1
			or options.max_page_size > 4096
		)
	then
		error("dotnet-workspace-explorer: max_page_size must be an integer from 1 to 4096", 2)
	end
	return setmetatable({
		command = options.command,
		target = options.target,
		spawn = options.spawn or default_spawn,
		max_page_size = options.max_page_size or 256,
		on_notification = options.on_notification or function() end,
		on_error = options.on_error or function() end,
		state = "new",
		pending = {},
		next_id = 0,
		stderr = "",
	}, Client)
end

function Client:_live(captured)
	return active == self and not self.inert and self.generation == captured
end

function Client:_deliver(callback, request_error, result)
	local captured = self.generation
	vim.schedule(function()
		if self:_live(captured) then
			callback(request_error, result)
		end
	end)
end

function Client:_fail_pending(reason)
	local pending = self.pending
	self.pending = {}
	for _, callback in pairs(pending) do
		pcall(callback, reason)
	end
end

function Client:_terminate(reason)
	if self.inert then
		return
	end
	local captured = self.generation
	self.inert, self.state = true, "failed"
	if active == self then
		active = nil
	end
	self:_fail_pending(reason)
	if self.process then
		pcall(self.process.kill, self.process, 15)
	end
	vim.schedule(function()
		if generation == captured and self.state == "failed" then
			self.on_error(reason)
		end
	end)
end

function Client:_allocate_id()
	local first = self.next_id
	repeat
		local id = self.next_id
		self.next_id = id == UINT32_MAX and 0 or id + 1
		if self.pending[id] == nil then
			return id
		end
	until self.next_id == first
	return nil
end

function Client:_write(frame)
	local ok, encoded = pcall(vim.mpack.encode, frame)
	if not ok then
		self:_terminate(problem("encode_failed", tostring(encoded)))
		return false
	end
	if self.limits and #encoded > self.limits.maxFrameBytes then
		self:_terminate(problem("frame_too_large", "The request exceeds the negotiated frame limit."))
		return false
	end
	local wrote, write_error = pcall(self.process.write, self.process, encoded)
	if not wrote then
		self:_terminate(problem("write_failed", tostring(write_error)))
		return false
	end
	return true
end

function Client:_send(method, parameters, callback, initializing)
	if
		(initializing and self.state ~= "starting") or (not initializing and self.state ~= "ready")
	then
		self:_deliver(callback, problem("not_ready", "The workspace session is not ready."))
		return
	end
	local required = method_capabilities[method]
	if required and not self.capabilities[required] then
		self:_deliver(
			callback,
			problem("unsupported_capability", "The server did not negotiate " .. required .. ".")
		)
		return
	end
	local id = self:_allocate_id()
	if id == nil then
		self:_terminate(problem("request_ids_exhausted", "No request ID is available."))
		return
	end
	self.pending[id] = callback
	if self:_write({ 0, id, method, parameters }) then
		return id
	end
end

local function valid_id(value)
	return type(value) == "number" and value >= 0 and value <= UINT32_MAX and value % 1 == 0
end

function Client:_dispatch(frame)
	if type(frame) ~= "table" or not vim.islist(frame) then
		return self:_terminate(problem("invalid_frame", "An RPC frame must be an array."))
	end
	if frame[1] == 1 and #frame == 4 and valid_id(frame[2]) then
		local callback = self.pending[frame[2]]
		if callback == nil then
			return self:_terminate(problem("unmatched_response", "Received an unmatched response ID."))
		end
		self.pending[frame[2]] = nil
		local rpc_error = frame[3]
		if
			rpc_error ~= vim.NIL
			and (
				type(rpc_error) ~= "table"
				or type(rpc_error.code) ~= "string"
				or type(rpc_error.message) ~= "string"
			)
		then
			return self:_terminate(problem("invalid_frame", "A response error is malformed."))
		end
		self:_deliver(callback, rpc_error ~= vim.NIL and rpc_error or nil, frame[4])
	elseif
		frame[1] == 2
		and #frame == 3
		and type(frame[2]) == "string"
		and frame[2] ~= ""
		and type(frame[3]) == "table"
	then
		local captured, method, parameters = self.generation, frame[2], frame[3]
		vim.schedule(function()
			if self:_live(captured) then
				self.on_notification(method, parameters)
			end
		end)
	else
		self:_terminate(problem("invalid_frame", "Received a malformed or unexpected RPC frame."))
	end
end

function Client:_stdout(captured, read_error, data)
	if not self:_live(captured) then
		return
	end
	if read_error then
		return self:_terminate(problem("read_failed", tostring(read_error)))
	end
	if not data or data == "" then
		return
	end
	local position = 1
	while position <= #data do
		local ok, frame, next_position = pcall(self.unpacker, data, position)
		if not ok or type(next_position) ~= "number" or next_position <= position then
			return self:_terminate(
				problem("decode_failed", ok and "Invalid decoder position." or tostring(frame))
			)
		end
		position = next_position
		if frame == nil then
			return
		end
		self:_dispatch(frame)
		if not self:_live(captured) then
			return
		end
	end
end

local function validate_initialize(result, requested)
	if
		type(result) ~= "table"
		or type(result.protocolVersion) ~= "table"
		or result.protocolVersion.major ~= 1
		or type(result.protocolVersion.minor) ~= "number"
		or result.protocolVersion.minor < 0
		or result.protocolVersion.minor % 1 ~= 0
		or type(result.workspace) ~= "table"
		or type(result.workspace.id) ~= "string"
		or result.workspace.id == ""
		or type(result.workspace.revision) ~= "number"
		or result.workspace.revision < 0
		or result.workspace.revision % 1 ~= 0
		or type(result.capabilities) ~= "table"
		or not vim.islist(result.capabilities)
		or type(result.limits) ~= "table"
		or type(result.limits.maxFrameBytes) ~= "number"
		or result.limits.maxFrameBytes <= 0
		or result.limits.maxFrameBytes > 16777216
		or result.limits.maxFrameBytes % 1 ~= 0
		or type(result.limits.maxPageSize) ~= "number"
		or result.limits.maxPageSize <= 0
		or result.limits.maxPageSize > 4096
		or result.limits.maxPageSize % 1 ~= 0
	then
		return nil, problem("invalid_initialize", "The initialize response is malformed.")
	end
	local negotiated = {}
	for _, name in ipairs(result.capabilities) do
		if type(name) ~= "string" or name == "" or negotiated[name] or not requested[name] then
			return nil, problem("invalid_initialize", "The returned capabilities are invalid.")
		end
		negotiated[name] = true
	end
	return negotiated
end

function Client:start(callback)
	if self.state ~= "new" then
		return callback(problem("already_started", "The workspace session was already started."))
	end
	if active then
		active:stop("session_replaced", true)
	end
	generation = generation + 1
	self.generation, self.state, self.inert = generation, "starting", false
	self.unpacker, self.capabilities = vim.mpack.Unpacker(), {}
	active = self
	local captured = self.generation
	local ok, process = pcall(self.spawn, {
		self.command,
		"workspace",
		self.target,
		"--pipe",
	}, {
		stdin = true,
		text = false,
		stdout = function(err, data)
			self:_stdout(captured, err, data)
		end,
		stderr = function(_, data)
			if self:_live(captured) and data then
				self.stderr = (self.stderr .. data):sub(-4096)
			end
		end,
	}, function(result)
		if self:_live(captured) then
			self:_terminate(problem("unexpected_exit", "Workspace process exited.", result))
		end
	end)
	if not ok or process == nil then
		return self:_terminate(problem("spawn_failed", tostring(process)))
	end
	self.process = process
	local requested = {}
	for _, name in ipairs(capabilities) do
		requested[name] = true
	end
	self:_send("initialize", {
		protocolVersion = { major = 1, minor = 0 },
		clientInfo = { name = "dotnet-workspace-explorer.nvim" },
		capabilities = capabilities,
		limits = { maxFrameBytes = 16777216, maxPageSize = self.max_page_size },
	}, function(rpc_error, result)
		if rpc_error then
			return self:_terminate(problem(rpc_error.code, rpc_error.message, rpc_error.data))
		end
		local negotiated, validation_error = validate_initialize(result, requested)
		if not negotiated then
			return self:_terminate(validation_error)
		end
		self.capabilities, self.workspace, self.limits, self.state =
			negotiated, result.workspace, result.limits, "ready"
		callback(nil, result)
	end, true)
end

function Client:request(method, parameters, callback)
	parameters = parameters or empty()
	if next(parameters) == nil then
		parameters = empty()
	end
	return self:_send(method, parameters, callback or function() end, false)
end

function Client:has_capability(name)
	return self.state == "ready" and self.capabilities[name] == true
end

function Client:stop(reason, force)
	if self.inert or self.state == "new" then
		return
	end
	local was_ready = self.state == "ready"
	self.inert, self.state = true, "stopped"
	if active == self then
		active = nil
	end
	self:_fail_pending(problem(reason or "session_stopped", "The workspace session stopped."))
	if was_ready and self.process then
		local id = self:_allocate_id() or 0
		pcall(self.process.write, self.process, vim.mpack.encode({ 0, id, "shutdown", empty() }))
	end
	if (force or not was_ready) and self.process then
		pcall(self.process.kill, self.process, 15)
	end
end

M.Client = Client
M.empty = empty
M.problem = problem

return M

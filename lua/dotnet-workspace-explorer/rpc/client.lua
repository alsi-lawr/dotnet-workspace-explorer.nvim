local capability_model = require("dotnet-workspace-explorer.rpc.capabilities")
local frames = require("dotnet-workspace-explorer.rpc.frames")
local message = require("dotnet-workspace-explorer.rpc.message")
local validation = require("dotnet-workspace-explorer.rpc.validation")

local M = {}
local Client = {}
Client.__index = Client

local generation = 0
local active

---@class DweRpcProcess
---@field write fun(self: DweRpcProcess, data: string)
---@field kill fun(self: DweRpcProcess, signal: integer)

---@class DweRpcClientOptions
---@field command string
---@field target string
---@field spawn? fun(command: string[], options: table, on_exit: fun(result: unknown)): DweRpcProcess
---@field max_page_size? integer
---@field on_notification? fun(method: string, parameters: table)
---@field on_error? fun(problem: DweProblem)
---@field git_enabled? boolean

---@param command string[]
---@param options table
---@param on_exit fun(result: unknown)
---@return DweRpcProcess
local function default_spawn(command, options, on_exit)
	return vim.system(command, options, on_exit)
end

---Creates an inactive MessagePack-RPC client.
---@param options DweRpcClientOptions
---@return table
function Client.new(options)
	if
		not (
			vim.mpack
			and vim.mpack.encode
			and vim.mpack.Unpacker
			and vim.system
			and vim.empty_dict
		)
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
		git_enabled = options.git_enabled == true,
		state = "new",
		pending = {},
		next_id = 0,
		stderr = "",
	}, Client)
end

---@param captured integer
---@return boolean
function Client:_live(captured)
	return active == self and not self.inert and self.generation == captured
end

---@param callback DweErrorFirstCallback
---@param request_error DweProblem?
---@param result? unknown
function Client:_deliver(callback, request_error, result)
	local captured = self.generation
	vim.schedule(function()
		if self:_live(captured) then
			callback(request_error, result)
		end
	end)
end

---@param reason DweProblem
function Client:_fail_pending(reason)
	local pending = self.pending
	self.pending = {}
	for _, callback in pairs(pending) do
		pcall(callback, reason)
	end
end

---@param reason DweProblem
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

---@return integer?
function Client:_allocate_id()
	local first = self.next_id
	repeat
		local id = self.next_id
		self.next_id = id == validation.UINT32_MAX and 0 or id + 1
		if self.pending[id] == nil then
			return id
		end
	until self.next_id == first
	return nil
end

---@param method string
---@param parameters table
---@param callback DweErrorFirstCallback
---@param initializing boolean
---@return integer?
function Client:_send(method, parameters, callback, initializing)
	if
		(initializing and self.state ~= "starting") or (not initializing and self.state ~= "ready")
	then
		self:_deliver(callback, message.problem("not_ready", "The workspace session is not ready."))
		return
	end

	local required = capability_model.for_method(method)
	if not capability_model.supports(self.capabilities, required) then
		local capability = type(required) == "table" and table.concat(required, " or ") or required
		self:_deliver(
			callback,
			message.problem(
				"unsupported_capability",
				"The server did not negotiate " .. capability .. "."
			)
		)
		return
	end

	local id = self:_allocate_id()
	if id == nil then
		self:_terminate(message.problem("request_ids_exhausted", "No request ID is available."))
		return
	end
	self.pending[id] = callback
	if self:_write({ 0, id, method, parameters }) then
		return id
	end
end

---Starts the child process and negotiates protocol capabilities and limits.
---@param callback fun(error: DweProblem?, result: DweInitializeResult?)
function Client:start(callback)
	if self.state ~= "new" then
		return callback(
			message.problem("already_started", "The workspace session was already started.")
		)
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
			self:_terminate(
				message.problem("unexpected_exit", message.exit_message(self.stderr), result)
			)
		end
	end)
	if not ok or process == nil then
		return self:_terminate(message.problem("spawn_failed", tostring(process)))
	end
	self.process = process

	local requested_capabilities = capability_model.requested(self.git_enabled)
	local requested = {}
	for _, name in ipairs(requested_capabilities) do
		requested[name] = true
	end
	self:_send("initialize", {
		protocolVersion = { major = 1, minor = 0 },
		clientInfo = { name = "dotnet-workspace-explorer.nvim" },
		capabilities = requested_capabilities,
		limits = { maxFrameBytes = 16777216, maxPageSize = self.max_page_size },
	}, function(rpc_error, result)
		if rpc_error then
			return self:_terminate(
				message.problem(rpc_error.code, rpc_error.message, rpc_error.data)
			)
		end
		local negotiated, validation_error = validation.initialize(result, requested)
		if not negotiated and validation_error then
			return self:_terminate(validation_error)
		end
		self.capabilities, self.workspace, self.limits, self.state =
			negotiated, result.workspace, result.limits, "ready"
		callback(nil, result)
	end, true)
end

---Sends a request after initialization.
---@param method string
---@param parameters? table
---@param callback? DweErrorFirstCallback
---@return integer?
function Client:request(method, parameters, callback)
	parameters = parameters or message.empty()
	if next(parameters) == nil then
		parameters = message.empty()
	end
	return self:_send(method, parameters, callback or function() end, false)
end

---@param name string
---@return boolean
function Client:has_capability(name)
	return self.state == "ready" and self.capabilities[name] == true
end

---Stops the client and optionally kills the process immediately.
---@param reason? string
---@param force? boolean
function Client:stop(reason, force)
	if self.inert or self.state == "new" then
		return
	end
	local was_ready = self.state == "ready"
	self.inert, self.state = true, "stopped"
	if active == self then
		active = nil
	end
	self:_fail_pending(
		message.problem(reason or "session_stopped", "The workspace session stopped.")
	)
	if was_ready and self.process then
		local id = self:_allocate_id() or 0
		pcall(
			self.process.write,
			self.process,
			vim.mpack.encode({ 0, id, "shutdown", message.empty() })
		)
	end
	if (force or not was_ready) and self.process then
		pcall(self.process.kill, self.process, 15)
	end
end

Client._write = frames.write
Client._dispatch = frames.dispatch
Client._stdout = frames.stdout

M.Client = Client
return M

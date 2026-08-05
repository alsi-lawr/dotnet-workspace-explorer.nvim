local message = require("dotnet-workspace-explorer.rpc.message")
local validation = require("dotnet-workspace-explorer.rpc.validation")

local M = {}

---Encodes and writes one MessagePack-RPC frame.
---@param self table
---@param frame table
---@return boolean
function M.write(self, frame)
	local ok, encoded = pcall(vim.mpack.encode, frame)
	if not ok then
		self:_terminate(message.problem("encode_failed", tostring(encoded)))
		return false
	end
	if self.limits and #encoded > self.limits.maxFrameBytes then
		self:_terminate(message.problem("frame_too_large", "The request exceeds the negotiated frame limit."))
		return false
	end
	local wrote, write_error = pcall(self.process.write, self.process, encoded)
	if not wrote then
		self:_terminate(message.problem("write_failed", tostring(write_error)))
		return false
	end
	return true
end

---Dispatches one decoded response or notification frame.
---@param self table
---@param frame unknown
function M.dispatch(self, frame)
	if type(frame) ~= "table" or not vim.islist(frame) then
		return self:_terminate(message.problem("invalid_frame", "An RPC frame must be an array."))
	end
	if frame[1] == 1 and #frame == 4 and validation.request_id(frame[2]) then
		local callback = self.pending[frame[2]]
		if callback == nil then
			return self:_terminate(message.problem("unmatched_response", "Received an unmatched response ID."))
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
			return self:_terminate(message.problem("invalid_frame", "A response error is malformed."))
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
		self:_terminate(message.problem("invalid_frame", "Received a malformed or unexpected RPC frame."))
	end
end

---Consumes a binary stdout chunk, decoding every complete MessagePack frame.
---@param self table
---@param captured integer
---@param read_error? string
---@param data? string
function M.stdout(self, captured, read_error, data)
	if not self:_live(captured) then
		return
	end
	if read_error then
		return self:_terminate(message.problem("read_failed", tostring(read_error)))
	end
	if not data or data == "" then
		return
	end
	local position = 1
	while position <= #data do
		local ok, frame, next_position = pcall(self.unpacker, data, position)
		if not ok or type(next_position) ~= "number" or next_position <= position then
			return self:_terminate(
				message.problem("decode_failed", ok and "Invalid decoder position." or tostring(frame))
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

return M

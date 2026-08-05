local result = require("dotnet-workspace-explorer.protocol.command_result")
local schema = require("dotnet-workspace-explorer.protocol.command_schema")

return {
	compatible_descriptor = schema.compatible_descriptor,
	compatible_creation_options = schema.compatible_creation_options,
	compatible_preview = result.compatible_preview,
	compatible_applied = result.compatible_applied,
	compatible_operation = result.compatible_operation,
	compatible_completion = result.compatible_completion,
	completion_problem = result.completion_problem,
	effects_prompt = result.effects_prompt,
}

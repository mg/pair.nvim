local uv = vim.uv or vim.loop
local mcp = require("pair.mcp")

local Client = {}
Client.__index = Client

local function close(handle)
	if handle and not handle:is_closing() then
		handle:close()
	end
end

function Client.new(opts)
	return setmetatable({
		command = opts.command,
		cwd = opts.cwd,
		session_file = opts.session_file,
		model = opts.model,
		on_update = opts.on_update,
		on_error = opts.on_error,
		ready = false,
	}, Client)
end

function Client:start(callback)
	if vim.fn.executable(self.command) ~= 1 then
		callback(nil, { message = "Codex executable not found: " .. self.command })
		return
	end
	local disabled, err = mcp.disabled_servers(self.command, self.cwd)
	if not disabled then
		callback(nil, { message = err })
		return
	end
	self.disabled_servers = disabled
	local file = io.open(self.session_file, "r")
	if file then
		self.session_id = file:read("*l")
		file:close()
	end
	self.ready = true
	callback({ sessionId = self.session_id, model = self.model })
end

function Client:prompt(prompt, callback)
	if self.process then
		callback(nil, { message = "A Codex turn is already running" })
		return
	end
	local disabled, err = mcp.disabled_servers(self.command, self.cwd)
	if not disabled then
		callback(nil, { message = err })
		return
	end
	self.disabled_servers = disabled
	local args = {
		"exec",
		"--json",
		"--skip-git-repo-check",
		"-c",
		'sandbox_mode="read-only"',
		"-c",
		'approval_policy="never"',
	}
	if self.model then
		args[#args + 1] = "--model"
		args[#args + 1] = self.model
	end
	mcp.add_disabled_features(args)
	for _, name in ipairs(self.disabled_servers) do
		args[#args + 1] = "-c"
		args[#args + 1] = "mcp_servers." .. name .. ".enabled=false"
	end
	if self.session_id and self.session_id ~= "" then
		args[#args + 1] = "resume"
		args[#args + 1] = self.session_id
	else
		args[#args + 1] = "--sandbox"
		args[#args + 1] = "read-only"
		args[#args + 1] = "-C"
		args[#args + 1] = self.cwd
	end
	args[#args + 1] = "-"

	local stdin = uv.new_pipe(false)
	local stdout = uv.new_pipe(false)
	local stderr = uv.new_pipe(false)
	local output_buffer = ""
	local error_buffer = ""
	local failed
	local completed = false
	local process_done = false
	local stdout_done = false
	local finalized = false
	local exit_code, exit_signal
	local handle_event

	local function maybe_finish()
		if finalized or not process_done or not stdout_done then
			return
		end
		finalized = true
		close(stdin)
		close(stdout)
		close(stderr)
		close(self.process)
		vim.schedule(function()
			self.process = nil
			self.stdin = nil
			if exit_code == 0 and completed and not failed then
				callback({ stopReason = "end_turn" })
			else
				callback(nil, {
					message = failed
						or (
							"Codex exited (code "
							.. exit_code
							.. ", signal "
							.. exit_signal
							.. "): "
							.. error_buffer:sub(-500)
						),
				})
			end
		end)
	end

	local function decode_line(line)
		local ok, event = pcall(vim.json.decode, line)
		if ok and type(event) == "table" then
			vim.schedule(function()
				handle_event(event)
			end)
		end
	end

	handle_event = function(event)
		if event.type == "thread.started" and event.thread_id then
			self.session_id = event.thread_id
			local file = io.open(self.session_file, "w")
			if file then
				file:write(self.session_id, "\n")
				file:close()
				pcall(vim.fn.setfperm, self.session_file, "rw-------")
			end
		elseif event.type == "item.completed" and event.item then
			local item = event.item
			if item.type == "agent_message" and item.text then
				self.on_update({ sessionUpdate = "agent_message_chunk", content = { type = "text", text = item.text } })
			elseif item.type == "command_execution" then
				self.on_update({ sessionUpdate = "tool_call", id = item.id,
					title = item.command or "Inspecting project", command = item.command,
					status = item.exit_code ~= nil and item.exit_code ~= 0 and "failed" or "completed",
					output = item.aggregated_output, exitCode = item.exit_code })
			elseif item.type == "file_change" then
				failed = "Codex reported a direct file change; Pair stopped the turn"
				if self.process then
					self.process:kill("sigterm")
				end
			end
		elseif event.type == "item.started" and event.item then
			local item = event.item
			if item.type == "command_execution" then
				self.on_update({ sessionUpdate = "tool_call", id = item.id,
					title = item.command or "Inspecting project", command = item.command,
					status = "in_progress" })
			end
		elseif event.type == "turn.failed" then
			failed = event.error and event.error.message or "Codex turn failed"
		elseif event.type == "turn.completed" then
			completed = true
		end
	end

	self.process, self.pid = uv.spawn(self.command, {
		args = args,
		cwd = self.cwd,
		stdio = { stdin, stdout, stderr },
	}, function(code, signal)
		exit_code, exit_signal = code, signal
		process_done = true
		maybe_finish()
	end)
	if not self.process then
		close(stdin)
		close(stdout)
		close(stderr)
		callback(nil, { message = "Could not launch Codex: " .. tostring(self.pid) })
		return
	end
	self.stdin = stdin
	stdout:read_start(function(err, chunk)
		if err then
			failed = err
			stdout_done = true
			maybe_finish()
		elseif chunk then
			output_buffer = output_buffer .. chunk
			while true do
				local newline = output_buffer:find("\n", 1, true)
				if not newline then
					break
				end
				local line = output_buffer:sub(1, newline - 1)
				output_buffer = output_buffer:sub(newline + 1)
				decode_line(line)
			end
		else
			if output_buffer ~= "" then
				decode_line(output_buffer)
			end
			stdout_done = true
			maybe_finish()
		end
	end)
	stderr:read_start(function(_, chunk)
		if chunk then
			error_buffer = (error_buffer .. chunk):sub(-4000)
		end
	end)
	stdin:write(prompt, function()
		stdin:shutdown()
	end)
end

function Client:cancel()
	if self.process then
		self.process:kill("sigterm")
	end
end

function Client:stop()
	self.ready = false
	self:cancel()
end

function Client:reset()
	self.session_id = nil
	os.remove(self.session_file)
end

return Client

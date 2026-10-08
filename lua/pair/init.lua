local CodexExec = require("pair.codex")
local CodexAppServer = require("pair.app_server")
local ACP = require("pair.acp")
local Pi = require("pair.pi")
local Antigravity = require("pair.antigravity")
local DirectAPI = require("pair.direct_api")
local backends = require("pair.backends")
local context = require("pair.context")
local edit = require("pair.edit")
local sessions = require("pair.sessions")
local preferences = require("pair.preferences")
local ui = require("pair.ui")

local M = {}
local client
local workspace
local queue = {}
local active
local starting = false
local restoring
local outcomes = {}
local configured = false
local history_root
local current_record
local session_generation = 0
local session_model
local connect_callbacks = {}
local function finish_connections(ok, message)
  local callbacks = connect_callbacks
  connect_callbacks = {}
  for _, waiting in ipairs(callbacks) do waiting(ok, message) end
end
local status_error = false
local cancel_timeout_ms = 2500

local defaults = {
  command = "codex",
  keymaps = true,
  transport = "app-server",
  backend = "codex",
  remember_selection = true,
  agents = {},
  models = {},
  api_keys = {},
  api_endpoints = {},
  commands = { writable_paths = {} },
  context_max_bytes = 128 * 1024,
  context_nearby_lines = 20,
}
local config = vim.deepcopy(defaults)

local function client_backend(spec)
  if spec.kind == "direct" then return DirectAPI end
  if spec.kind == "acp" then return ACP end
  if spec.kind == "pi" then return Pi end
  if spec.kind == "antigravity" then return Antigravity end
  return config.transport == "exec" and CodexExec or CodexAppServer
end

local function notice(message, level)
  vim.notify("Pair: " .. message, level or vim.log.levels.INFO)
end

local function remember_selection(model)
  -- New conversations use the last selected model even when disk persistence
  -- is disabled. A restored conversation keeps its own saved model.
  if model then config.models[config.backend] = model end
  if not config.remember_selection then return end
  local saved, err = preferences.save(config.backend, model)
  if not saved then notice("Selection changed, but could not be remembered: " .. tostring(err), vim.log.levels.WARN) end
end

local function error_text(err)
  if type(err) == "table" then
    return err.message or vim.inspect(err)
  end
  return tostring(err)
end

local function startup_error(name, spec, err)
  local message = error_text(err)
  local lower = message:lower()
  if spec.kind == "direct" then
    if lower:find("missing ", 1, true) then
      return message .. ". Set " .. spec.key_env .. " or setup().api_keys." .. spec.provider
    end
    return message
  end
  if lower:find("not found", 1, true) and lower:find("executable", 1, true) then
    return "Executable for " .. name .. " is missing: " .. spec.command .. ". Install it or set its command in setup()."
  end
  if lower:find("login", 1, true) or lower:find("sign in", 1, true)
    or lower:find("unauthorized", 1, true) or lower:find("authentication", 1, true)
    or lower:find("credential", 1, true) or lower:find("token refresh", 1, true)
    or lower:find("http 401", 1, true) or lower:find("http 403", 1, true) then
    return "Authentication failed for " .. name .. ": " .. message
      .. ". Sign in through its CLI, then retry."
  end
  return message
end

local function recovery_action(message)
  local lower = message:lower()
  if config.backend == "opencode" and lower:find("free", 1, true)
    and (lower:find("opencode", 1, true) or lower:find("open code", 1, true)) then
    return " This model restricts access from external clients. Connect a provider with"
      .. " `opencode auth login`, then use :PairModel to choose a provider/model"
      .. " such as openrouter/openai/gpt-4.1-mini. :PairNew will not remove this restriction."
  end
  if lower:find(":pairnew", 1, true) then return "" end
  for _, marker in ipairs({ "context limit", "context window", "history limit",
    "session not found", "session expired", "conversation not found",
    "cannot resume", "session/load" }) do
    if lower:find(marker, 1, true) then
      return " Use :PairNew for a fresh conversation; the previous transcript"
        .. " remains in :PairSessions."
    end
  end
  return " Send another message to retry, or use :PairNew for a fresh session."
end

local function action_name(turn)
  if turn.kind == "chat" then return "Chat" end
  if turn.kind == "ask" then return "Ask" end
  return turn.target.kind == "insert" and "Insert" or "Change"
end

local function update_status()
  local activity
  if starting then
    activity = "Connecting"
  elseif restoring then
    activity = "Restoring session"
  elseif active then
    activity = action_name(active) .. ": " .. (active.cancel_requested and "cancelling"
      or active.stage or "thinking")
  elseif edit.pending() then
    activity = "Review proposal"
  elseif status_error then
    activity = "Unavailable"
  elseif current_record and not client and vim.fn.filereadable(current_record.session) == 1 then
    activity = "Reconnect"
  else
    activity = "Ready"
  end
  ui.status({
    backend = config.backend,
    model = session_model,
    activity = activity,
    queued = #queue,
    cancellable = starting or restoring ~= nil
      or (active ~= nil and not active.cancel_requested) or #queue > 0,
  })
end

local function ensure_history()
  local root = vim.fn.getcwd()
  local scope = root .. "\0" .. config.backend
  if history_root ~= scope then
    if workspace and workspace ~= root then
      if active or starting or restoring or #queue > 0 or edit.pending() then
        return nil, "Finish the current request or proposal before changing workspaces"
      end
      session_generation = session_generation + 1
      if client then client:stop(); client = nil end
      session_model = nil
      status_error = false
      outcomes = {}
    end
    local record, err = sessions.current(root, config.backend)
    if not record then return nil, err end
    ui.history(record.transcript)
    current_record = record
    history_root = scope
    session_model = sessions.read_model(record) or (config.models or {})[config.backend]
  end
  workspace = root
  update_status()
  return current_record
end

local function parse_proposal(text)
  local cleaned = vim.trim(text)
  cleaned = cleaned:gsub("^```json%s*", ""):gsub("^```%s*", ""):gsub("%s*```$", "")
  local ok, object = pcall(vim.json.decode, cleaned)
  if not ok or type(object) ~= "table" then
    local first = cleaned:find("{", 1, true)
    local last = cleaned:match(".*()}")
    if first and last and last >= first then
      ok, object = pcall(vim.json.decode, cleaned:sub(first, last))
    end
  end
  if not ok or type(object) ~= "table" or type(object.replacement) ~= "string" then
    return nil, "Agent did not return a valid replacement. Its response is in the chat pane."
  end
  return object
end

local function tool_text(value)
  if type(value) == "string" then return value:sub(1, 4096) end
  if type(value) ~= "table" then return nil end
  if type(value.text) == "string" then return value.text:sub(1, 4096) end
  if type(value.message) == "string" then return value.message:sub(1, 4096) end
  if type(value.content) == "table" then return tool_text(value.content) end
  local parts = {}
  for _, part in ipairs(value) do
    local text = tool_text(part)
    if text then parts[#parts + 1] = text end
  end
  return #parts > 0 and table.concat(parts, "\n") or nil
end

local function tool_detail(update)
  local parts = {}
  if type(update.command) == "string" then parts[#parts + 1] = "Command: " .. update.command
  elseif type(update.title) == "string" then parts[#parts + 1] = "Tool: " .. update.title end
  local output = tool_text(update.output or update.content)
  if output and output ~= "" then parts[#parts + 1] = "Output:\n" .. output end
  local err = tool_text(update.error)
  if err and err ~= "" then parts[#parts + 1] = "Error: " .. err end
  if update.exitCode ~= nil then parts[#parts + 1] = "Exit code: " .. tostring(update.exitCode) end
  local detail = table.concat(parts, "\n")
  if #detail > 4096 then detail = detail:sub(1, 4078) .. "\n… [truncated]" end
  return detail
end

local function on_update(update)
  if active and active.cancel_requested then return end
  if update.sessionUpdate == "agent_message_chunk" then
    local content = update.content
    if active and content and content.type == "text" then
      active.stage = active.kind == "edit" and "generating" or "replying"
      update_status()
      active.text = active.text .. content.text
      if active.kind == "chat" or active.kind == "ask" then
        ui.replace(active.response_entry, active.text)
      end
      if active.kind == "ask" then edit.show_answer(active.target, active.text, false) end
    end
  elseif update.sessionUpdate == "agent_message_reset" then
    if active then
      active.text = ""
      if active.response_entry then ui.replace(active.response_entry, "…") end
    end
  elseif update.sessionUpdate == "tool_call" then
    if active then active.stage = "inspecting"; update_status() end
    if active then
      active.tools = active.tools or {}
      active.tool_indices = active.tool_indices or {}
      active.tool_commands = active.tool_commands or {}
      local key = update.toolCallId or update.id
      if key and update.command then active.tool_commands[key] = update.command end
      local index = key and active.tools[key] or nil
      local raw_status = update.status
      local status = (raw_status == "failed" or raw_status == "error" or raw_status == "incomplete"
        or (type(update.exitCode) == "number" and update.exitCode ~= 0)) and "failed"
        or (raw_status == "completed" or raw_status == "success") and "completed" or "running"
      index = ui.tool(index, { title = update.title, status = status, detail = tool_detail({
        command = update.command or (key and active.tool_commands[key]), title = update.title,
        output = update.output, content = update.content, error = update.error, exitCode = update.exitCode,
      }) })
      if key then active.tools[key] = index end
      active.tool_indices[index] = true
    end
  elseif update.sessionUpdate == "pair_notice" then
    ui.add("Pair", update.text)
  end
end

local run_next

local function finish_turn(turn, result, err)
  edit.stop_progress()
  local cancelled = turn.cancel_requested or (result and result.stopReason == "cancelled")
  local tool_failed = cancelled or err ~= nil or (result ~= nil and result.stopReason ~= "end_turn")
  for index in pairs(turn.tool_indices or {}) do
    -- Some agents omit completion updates. The turn result closes those rows.
    ui.finish_tool(index, tool_failed)
  end
  if cancelled then
    local discarded = (turn.discarded or 0) + #queue
    queue = {}
    if turn.kind == "ask" then edit.dismiss_answer() end
    if turn.response_entry then ui.replace(turn.response_entry, "(Cancelled)") end
    ui.add("Pair", "Request cancelled" .. (discarded > 0
      and ("; discarded " .. discarded .. " queued request" .. (discarded == 1 and "" or "s")) or "")
      .. ". Send another message to continue, or use :PairNew for a fresh session.")
    if client then client:stop(); client = nil end
    session_generation = session_generation + 1
  elseif err then
    local discarded = #queue
    queue = {}
    if turn.kind == "ask" then edit.dismiss_answer() end
    if turn.response_entry then ui.replace(turn.response_entry, "(Request failed)") end
    local message = error_text(err)
    ui.add("Pair", "Request failed: " .. message
      .. (discarded > 0 and ("; discarded " .. discarded .. " queued request" .. (discarded == 1 and "" or "s")) or "")
      .. "." .. recovery_action(message))
    notice(message, vim.log.levels.ERROR)
  elseif result and result.stopReason and result.stopReason ~= "end_turn" then
    local discarded = #queue
    queue = {}
    if turn.kind == "ask" then edit.dismiss_answer() end
    if turn.response_entry then ui.replace(turn.response_entry, "(Agent stopped: " .. result.stopReason .. ")") end
    ui.add("Pair", "Agent stopped before completing the request: " .. result.stopReason
      .. (discarded > 0 and ("; discarded " .. discarded .. " queued request" .. (discarded == 1 and "" or "s")) or "")
      .. ". Send another message to retry, or use :PairNew for a fresh session.")
  elseif turn.kind == "chat" then
    if turn.text == "" then
      ui.replace(turn.response_entry, "(No text response)")
    end
  elseif turn.kind == "ask" then
    local answer = vim.trim(turn.text)
    ui.replace(turn.response_entry, answer ~= "" and answer or "(No answer)")
    if answer ~= "" and edit.show_answer(turn.target, answer) then
      notice("Answer shown beside the selection; <leader>pd or :PairDismiss hides it")
    else
      notice("Answer added to chat")
    end
  elseif turn.kind == "edit" then
    local proposal, parse_err = parse_proposal(turn.text)
    if not proposal then
      ui.add("Pair", parse_err .. "\n\n" .. turn.text)
      notice(parse_err, vim.log.levels.ERROR)
    else
      local ok, show_err = edit.show(turn.target, proposal.replacement, function(decision)
        ui.add("Pair", decision .. " proposal for " .. vim.fn.fnamemodify(turn.target.path, ":."))
        local outcome = string.format("User %s the proposal for %s at line %d", decision, turn.target.path, turn.target.start_row + 1)
        if decision == "accepted" then
          outcome = outcome .. ". Pair proposed this code; the user may have edited it afterward:\n" .. proposal.replacement
        end
        outcomes[#outcomes + 1] = outcome
        vim.schedule(run_next)
      end, type(proposal.rationale) == "string" and proposal.rationale or "Requested: " .. turn.message)
      if ok then
        local location = vim.fn.fnamemodify(turn.target.path, ":.") .. ":" .. (turn.target.start_row + 1)
        ui.add("Pair", "Proposal applied in the buffer at " .. location .. ". Choose Accept or Reject beside the code, or save to accept."
          .. (type(proposal.rationale) == "string" and ("\n" .. proposal.rationale) or ""))
        notice("Proposal applied in the buffer; accept, reject, or save to keep it")
      else
        ui.add("Pair", show_err)
        notice(show_err, vim.log.levels.WARN)
      end
    end
  end
  active = nil
  run_next()
  update_status()
end

local function build_prompt(turn)
  local prefix = "Pair session rules: inspect the project and discuss it. You may run commands, tests, and builds when your tools permit them. Commands run against files on disk, so unsaved editor content may differ. Do not edit ordinary source files via commands or file-writing tools. For source changes, return a proposal for Pair to display in Neovim. Never bypass tool or filesystem restrictions.\n"
  if config.backend == "antigravity" then
    prefix = prefix .. "The project is read-only to commands except these user-approved output directories: "
      .. (#config.commands.writable_paths > 0 and table.concat(config.commands.writable_paths, ", ") or "none")
      .. ". Use $TMPDIR for temporary files. Generated output in approved directories is written directly to disk.\n"
  end
  prefix = prefix .. "\n"
  if #outcomes > 0 then
    prefix = prefix .. "Editor outcomes since our last turn:\n" .. table.concat(outcomes, "\n") .. "\n\n"
    outcomes = {}
  end
  prefix = prefix .. context.prompt_block(turn.attachment)
  if turn.kind == "chat" then
    return prefix .. turn.message
  end
  local target = turn.target
  local location = string.format("%s:%d:%d", turn.snapshot.label, target.start_row + 1, target.start_col + 1)
  if turn.kind == "ask" then
    return prefix .. string.format(
      "Pair editor question at %s. Answer the user's question about the selected scope in the attached snapshot. Do not change files.\n\nQuestion: %s",
      location, turn.message
    )
  end
  local scope = target.kind == "insert"
      and "Insert at this exact cursor position. Return only code to insert; preserve neighboring code."
      or "Replace exactly the selected code. Return only the replacement text for that selection."
  return prefix .. string.format(
    "Pair scoped code proposal at %s. %s Use the exact scope in the attached snapshot. Do not change files or run commands that write project files.\n\nUser request: %s\n\nRespond with one JSON object only, with a string field named replacement and a short string field named rationale explaining the proposed change. No Markdown fence or other text.",
    location, scope, turn.message
  )
end

run_next = function()
  if active or not client or not client.ready or #queue == 0 then
    update_status()
    return
  end
  if queue[1].kind == "edit" and edit.pending() then
    update_status()
    return
  end
  active = table.remove(queue, 1)
  active.text = ""
  active.stage = "thinking"
  update_status()
  if active.kind == "chat" or active.kind == "ask" then
    active.response_entry = ui.add("Agent", "…")
  end
  if active.kind == "edit" then ui.add("Pair", "Preparing a scoped proposal…") end
  if active.kind ~= "chat" then edit.start_progress(active.target, active.kind) end
  local prompt = build_prompt(active)
  local turn = active
  client:prompt(prompt, function(result, err)
    if active ~= turn then return end
    finish_turn(turn, result, err)
  end)
  update_status()
end

local function ensure_client(callback)
  if callback then connect_callbacks[#connect_callbacks + 1] = callback end
  if starting then
    return
  end
  if client and not client.ready then
    client:stop()
    client = nil
  end
  if client then finish_connections(true); return end
  local spec, spec_err = backends.resolve(config.backend, config)
  if not spec then
    ui.add("Pair", spec_err .. ". Check the backend setup, then send a new message to retry.")
    notice(spec_err, vim.log.levels.ERROR)
    queue = {}
    status_error = true
    update_status()
    finish_connections(false, spec_err)
    return
  end
  spec.model = sessions.read_model(current_record) or spec.model
  starting = true
  status_error = false
  update_status()
  local generation = session_generation
  workspace = vim.fn.getcwd()
  local backend = client_backend(spec)
  client = backend.new({
    provider = spec.provider, api_key = spec.api_key, key_env = spec.key_env,
    endpoint = spec.endpoint,
    writable_paths = config.commands.writable_paths,
    command = spec.command,
    args = spec.args,
    env = spec.env,
    session_meta = spec.session_meta,
    allowed_tool_names = spec.allowed_tool_names,
    allowed_tool_kinds = spec.allowed_tool_kinds,
    required_mode = spec.required_mode,
    model = spec.model,
    cwd = workspace,
    session_file = current_record.session,
    on_update = function(update)
      if generation == session_generation then on_update(update) end
    end,
    on_error = function(message)
      if generation == session_generation then
        ui.add("Pair", message)
        status_error = true
        update_status()
      end
    end,
  })
  client:start(function(session, err)
    if generation ~= session_generation then return end
    starting = false
    if err then
      local message = startup_error(config.backend, spec, err)
      ui.add("Pair", "Could not start: " .. message .. "." .. recovery_action(message))
      notice(message, vim.log.levels.ERROR)
      client:stop()
      client = nil
      queue = {}
      status_error = true
      update_status()
      finish_connections(false, message)
      return
    end
    session_model = session and session.model or spec.model
    status_error = false
    run_next()
    update_status()
    finish_connections(true)
  end)
end

local function enqueue(turn, mode, done)
  local function reject(message)
    if message then notice(message, vim.log.levels.WARN) end
    if done then done(false) end
    return false
  end
  if active and active.cancel_requested then
    return reject("Wait for cancellation to finish, then send again")
  end
  if restoring then return reject("Wait for session restoration to finish or cancel it") end
  if turn.kind == "edit" and edit.pending() then
    return reject("Accept or reject the current proposal first")
  end
  local record, history_err = ensure_history()
  if not record then return reject(history_err) end
  local buf, source_win
  if turn.target then buf = turn.target.buf else buf, source_win = ui.source_buffer() end
  if buf then
    local snapshot, err = context.capture(buf, turn.target)
    if not snapshot then return reject(err) end
    turn.snapshot = snapshot
  end
  local function commit(attachment)
    turn.attachment = attachment
    ui.follow()
    queue[#queue + 1] = turn
    update_status()
    if turn.kind == "chat" then
      ui.add("You", turn.message)
    else
      ui.add("You", (turn.kind == "ask" and "Ask" or (turn.target.kind == "insert" and "Insert here" or "Change selection")) .. ": " .. turn.message)
    end
    ensure_client()
    run_next()
    if done then done(true) end
    return true
  end
  if not turn.snapshot then return commit(nil) end
  local detached = context.detached(turn.snapshot)
  if mode == "none" then
    if detached.scope and #detached.scope.text > config.context_max_bytes then
      return reject("Selected text exceeds the context limit; select a smaller range")
    end
    return commit(detached)
  end
  local size = context.byte_size(turn.snapshot)
  if size <= config.context_max_bytes then return commit(turn.snapshot) end
  local center = turn.target and turn.target.start_row
    or (source_win and vim.api.nvim_win_is_valid(source_win) and vim.api.nvim_win_get_cursor(source_win)[1] - 1 or 0)
  local narrow = context.narrow(turn.snapshot, center, config.context_nearby_lines)
  local generation = session_generation
  local choices = {}
  if context.byte_size(narrow) <= config.context_max_bytes then
    choices[#choices + 1] = {
      label = narrow.coverage.kind == "selection" and "Send selected lines only" or "Send nearby lines only",
      attachment = narrow,
    }
  end
  if not detached.scope or #detached.scope.text <= config.context_max_bytes then
    choices[#choices + 1] = { label = "Send without the full buffer", attachment = detached }
  end
  choices[#choices + 1] = { label = "Cancel and keep the draft" }
  if #choices == 1 then
    return reject("Buffer and selected text exceed the context limit; select a smaller range")
  end
  vim.ui.select(choices, {
    prompt = string.format("Pair: buffer is %d bytes (limit %d bytes). Choose narrower context:",
      size, config.context_max_bytes),
    format_item = function(item) return item.label end,
  }, function(choice)
    if generation ~= session_generation then return reject() end
    if choice and choice.attachment then commit(choice.attachment) else reject() end
  end)
  return "pending"
end

local function source_buffer()
  if vim.bo.buftype ~= "" then
    notice("Move to a source buffer first", vim.log.levels.WARN)
    return false
  end
  return true
end

function M.chat()
  local record, err = ensure_history()
  if not record then notice(err, vim.log.levels.ERROR); return end
  ui.chat()
end

function M.toggle_chat()
  if ui.is_open() then
    ui.close()
  else
    M.chat()
  end
end

function M.send(message, mode, done)
  local record, err = ensure_history()
  if not record then
    notice(err, vim.log.levels.ERROR)
    if done then done(false) end
    return false
  end
  if message and vim.trim(message) ~= "" then
    if not ui.is_open() then ui.chat() end
    return enqueue({ kind = "chat", message = vim.trim(message) }, mode, done)
  else
    ui.chat()
  end
end

function M.ask(message, supplied_target)
  if not source_buffer() then return end
  local target, err = supplied_target, nil
  if not target then target, err = edit.selection() end
  if not target then notice(err, vim.log.levels.WARN); return end
  if message and vim.trim(message) ~= "" then
    enqueue({ kind = "ask", target = target, message = vim.trim(message) })
  else
    ui.prompt("Ask about selection", function(input, mode, done)
      return enqueue({ kind = "ask", target = target, message = input }, mode, done)
    end, { source_buf = target.buf, target = target, anchor_row = target.end_row })
  end
end

function M.change(message, supplied_target)
  if not source_buffer() then return end
  local target, err = supplied_target, nil
  if not target then target, err = edit.selection() end
  if not target then notice(err, vim.log.levels.WARN); return end
  if message and vim.trim(message) ~= "" then
    enqueue({ kind = "edit", target = target, message = vim.trim(message) })
  else
    ui.prompt("Change selection", function(input, mode, done)
      return enqueue({ kind = "edit", target = target, message = input }, mode, done)
    end, { source_buf = target.buf, target = target })
  end
end

function M.here(message, supplied_target)
  if not source_buffer() then return end
  local target = supplied_target or edit.insertion()
  if message and vim.trim(message) ~= "" then
    enqueue({ kind = "edit", target = target, message = vim.trim(message) })
  else
    ui.prompt("Insert here", function(input, mode, done)
      return enqueue({ kind = "edit", target = target, message = input }, mode, done)
    end, { source_buf = target.buf, target = target })
  end
end

function M.actions(visual, supplied_target)
  local source_win = vim.api.nvim_get_current_win()
  local source_buf = vim.api.nvim_get_current_buf()
  local is_source = vim.bo[source_buf].buftype == ""
  local target, selection_err = supplied_target
  if not is_source then target = nil end
  if visual and is_source and not target then target, selection_err = edit.selection() end
  local insertion = is_source and edit.insertion() or nil
  local selection_note = not is_source and "open from a source buffer"
    or selection_err or "select code first"
  local choices = {
    { id = "chat", label = "Chat", available = true },
    { id = "ask", label = "Ask selection", available = target ~= nil, reason = selection_note },
    { id = "change", label = "Change selection", available = target ~= nil, reason = selection_note },
    { id = "insert", label = "Insert here", available = insertion ~= nil,
      reason = "open from a source buffer" },
    { id = "new", label = "New chat", available = true },
    { id = "resume", label = "Resume chat", available = true },
    { id = "backend", label = "Switch backend", available = true },
  }
  vim.ui.select(choices, {
    prompt = "Pair actions:",
    format_item = function(choice)
      return choice.label .. (choice.available and "" or " (" .. choice.reason .. ")")
    end,
  }, function(choice)
    if not choice then return end
    if not choice.available then
      notice(choice.label .. ": " .. choice.reason, vim.log.levels.WARN)
      return
    end
    if choice.id == "chat" then M.chat(); return end
    if choice.id == "new" then M.new_session(); return end
    if choice.id == "resume" then M.pick_session(); return end
    if choice.id == "backend" then M.pick_backend(); return end
    if not vim.api.nvim_win_is_valid(source_win)
      or vim.api.nvim_win_get_buf(source_win) ~= source_buf then
      notice("Source window changed while choosing an action; open the picker again", vim.log.levels.WARN)
      return
    end
    local scope = choice.id == "insert" and insertion or target
    if vim.api.nvim_buf_get_changedtick(source_buf) ~= scope.changedtick then
      notice("Source buffer changed while choosing an action; select it again", vim.log.levels.WARN)
      return
    end
    vim.api.nvim_set_current_win(source_win)
    if choice.id == "ask" then M.ask(nil, target)
    elseif choice.id == "change" then M.change(nil, target)
    else M.here(nil, insertion) end
  end)
end

function M.accept()
  local ok, err = edit.accept()
  if not ok then notice(err, vim.log.levels.WARN) end
  run_next()
end

function M.reject()
  local ok, err = edit.reject()
  if not ok then notice(err, vim.log.levels.WARN) end
  run_next()
end

function M.diff()
  local ok, err = edit.diff()
  if not ok then notice(err, vim.log.levels.WARN) end
end

function M.cancel()
  local discarded = #queue
  queue = {}
  if restoring then
    local pending_restore = restoring
    restoring = nil
    if pending_restore.client then pending_restore.client:stop() end
    update_status()
    notice("Session restoration cancelled")
  elseif starting then
    session_generation = session_generation + 1
    if client then client:stop(); client = nil end
    starting = false
    finish_connections(false, "Connection cancelled")
    session_model = nil
    status_error = false
    ui.add("Pair", "Startup cancelled" .. (discarded > 0 and ("; discarded " .. discarded
      .. " queued request" .. (discarded == 1 and "" or "s")) or "")
      .. ". Send another message to try again.")
  elseif active then
    if active.cancel_requested then
      active.discarded = (active.discarded or 0) + discarded
      update_status()
      return
    end
    local turn = active
    active.cancel_requested = true
    active.discarded = discarded
    edit.stop_progress()
    if active.kind == "ask" then edit.dismiss_answer() end
    if active.response_entry then ui.replace(active.response_entry, "(Cancelling…)") end
    if client then client:cancel() end
    vim.defer_fn(function()
      if active ~= turn or not turn.cancel_requested then return end
      finish_turn(turn, { stopReason = "cancelled" })
    end, cancel_timeout_ms)
  elseif discarded > 0 then
    ui.add("Pair", "Discarded " .. discarded .. " queued requests. Send another message to continue.")
  end
  update_status()
end

function M.dismiss()
  edit.dismiss_answer()
end

function M.new_session()
  if restoring then
    notice("Finish or cancel session restoration before starting a new chat", vim.log.levels.WARN)
    return
  end
  if edit.pending() then
    notice("Accept or reject the current proposal before starting a new session", vim.log.levels.WARN)
    return
  end
  local root = workspace or vim.fn.getcwd()
  local record, err = sessions.create(root, config.backend)
  if not record then notice(err, vim.log.levels.ERROR); return end
  if active then
    if active.response_entry then ui.replace(active.response_entry, "(Stopped when a new chat started)") end
    for index in pairs(active.tool_indices or {}) do ui.finish_tool(index, true) end
  end
  if active or starting or #queue > 0 then
    ui.add("Pair", "Stopped the current request"
      .. (#queue > 0 and (" and discarded " .. #queue .. " queued request"
        .. (#queue == 1 and "" or "s")) or "") .. " when a new chat started.")
  end
  session_generation = session_generation + 1
  queue = {}
  active = nil
  starting = false
  finish_connections(false, "New session started")
  session_model = (config.models or {})[config.backend]
  status_error = false
  edit.stop_progress()
  edit.dismiss_answer()
  if client then client:stop(); client = nil end
  outcomes = {}
  current_record = record
  workspace = root
  history_root = root .. "\0" .. config.backend
  ui.history(record.transcript)
  ui.clear()
  update_status()
  notice("New " .. config.backend .. " session will start with your next message")
end

local function restore_record(record, root, backend, previous_id)
  if vim.fn.getcwd() ~= root or config.backend ~= backend or not current_record
    or current_record.id ~= previous_id then
    notice("Workspace or backend changed; open the session picker again", vim.log.levels.WARN)
    return
  end
  if active or starting or restoring or #queue > 0 or edit.pending() then
    notice("Finish the current request or proposal before switching sessions", vim.log.levels.WARN)
    return
  end
  if ui.has_draft() then
    notice("Send or clear the chat draft before switching sessions", vim.log.levels.WARN)
    return
  end
  if record.id == previous_id and client and client.ready then
    if not ui.is_open() then ui.chat() end
    return
  end
  local entries, read_err = sessions.read_transcript(record)
  if not entries then notice(read_err, vim.log.levels.ERROR); return end
  local pointer
  if vim.fn.filereadable(record.session) == 1 then
    local ok, lines = pcall(vim.fn.readfile, record.session)
    if not ok then notice("Could not read the saved agent session", vim.log.levels.ERROR); return end
    pointer = lines[1]
    if pointer == "" then pointer = nil end
  end
  if #entries > 0 and not pointer then
    notice("This conversation has no saved agent session. Its transcript cannot be continued safely.",
      vim.log.levels.WARN)
    return
  end

  local function commit(candidate, session)
    local selected, err = sessions.activate(root, backend, record.id, previous_id)
    if not selected then
      if candidate then candidate:stop() end
      notice(err, vim.log.levels.ERROR)
      update_status()
      return
    end
    session_generation = session_generation + 1
    if client then client:stop() end
    client = candidate
    current_record = selected
    workspace = root
    history_root = root .. "\0" .. backend
    session_model = sessions.read_model(selected) or (session and session.model) or (config.models or {})[backend]
    status_error = false
    outcomes = {}
    edit.dismiss_answer()
    ui.history(selected.transcript)
    if not ui.is_open() then ui.chat() end
    update_status()
    notice("Restored " .. backend .. " conversation from " .. selected.created_at)
  end

  if not pointer then commit(nil, nil); return end
  local spec, spec_err = backends.resolve(backend, config)
  if not spec then notice(spec_err, vim.log.levels.ERROR); return end
  if spec.kind == "codex" and config.transport == "exec" then
    notice("Codex exec cannot verify a saved session before showing its transcript. Use the app-server transport to restore it.",
      vim.log.levels.WARN)
    return
  end
  local backend_client = client_backend(spec)
  local candidate
  local next_generation = session_generation + 1
  candidate = backend_client.new({
    provider = spec.provider, api_key = spec.api_key, key_env = spec.key_env,
    endpoint = spec.endpoint,
    command = spec.command, args = spec.args, env = spec.env,
    writable_paths = config.commands.writable_paths,
    session_meta = spec.session_meta,
    allowed_tool_names = spec.allowed_tool_names,
    allowed_tool_kinds = spec.allowed_tool_kinds,
    required_mode = spec.required_mode, model = sessions.read_model(record) or spec.model,
    cwd = root, session_file = record.session,
    on_update = function(update)
      if client == candidate and session_generation == next_generation then on_update(update) end
    end,
    on_error = function(message)
      if client == candidate and session_generation == next_generation then
        ui.add("Pair", message)
        status_error = true
        update_status()
      end
    end,
  })
  local state = { client = candidate }
  restoring = state
  update_status()
  candidate:start(function(session, err)
    if restoring ~= state then candidate:stop(); return end
    restoring = nil
    if err or not session or session.sessionId ~= pointer then
      candidate:stop()
      notice("Could not restore the saved agent session: " .. (err and error_text(err)
        or "the backend returned a different session ID") .. ". The current conversation is unchanged.",
        vim.log.levels.ERROR)
      update_status()
      return
    end
    commit(candidate, session)
  end)
end

function M.pick_session()
  local current, err = ensure_history()
  if not current then notice(err, vim.log.levels.ERROR); return end
  if active or starting or restoring or #queue > 0 or edit.pending() then
    notice("Finish the current request or proposal before opening sessions", vim.log.levels.WARN)
    return
  end
  local root, backend, previous_id = workspace, config.backend, current.id
  local records
  records, err = sessions.list(root, backend)
  if not records then notice(err, vim.log.levels.ERROR); return end
  local choices = {}
  for index = #records, 1, -1 do choices[#choices + 1] = records[index] end
  vim.ui.select(choices, {
    prompt = "Pair " .. backend .. " sessions for " .. vim.fn.fnamemodify(root, ":t") .. ":",
    format_item = function(record)
      return (record.active and "● " or "  ") .. record.created_at
        .. "  " .. record.id:sub(-8) .. (record.active and "  (current)" or "")
    end,
  }, function(choice)
    if choice then restore_record(choice, root, backend, previous_id) end
  end)
end

function M.backend(name)
  if not name or name == "" then
    notice("Current backend: " .. config.backend .. "; available: " .. table.concat(backends.names(config), ", "))
    return
  end
  local spec, err = backends.resolve(name, config)
  if err then notice(err, vim.log.levels.ERROR); return end
  if vim.fn.executable(spec.kind == "direct" and "curl" or spec.command) ~= 1 then
    notice(spec.kind == "direct" and "Direct API backends need curl on PATH"
      or ("Executable for " .. name .. " is missing: " .. spec.command
        .. ". Install it or set its command in setup()."),
      vim.log.levels.ERROR)
    return
  end
  if active or starting or restoring or #queue > 0 or edit.pending() then
    notice("Finish or cancel the current request and proposal before switching backends", vim.log.levels.WARN)
    return
  end
  if name == config.backend then return end
  session_generation = session_generation + 1
  if client then client:stop(); client = nil end
  config.backend = name
  session_model = nil
  status_error = false
  workspace = nil
  history_root = nil
  current_record = nil
  outcomes = {}
  local record, history_err = ensure_history()
  if not record then notice(history_err, vim.log.levels.ERROR); return end
  remember_selection(session_model)
  ui.add("Pair", "Using " .. name .. ". This backend has its own conversation; its next message will connect.")
  update_status()
end

function M.pick_backend()
  if active or starting or restoring or #queue > 0 or edit.pending() or ui.has_draft() then
    notice("Finish the current request, proposal, or draft before switching backends", vim.log.levels.WARN)
    return
  end
  local choices = {}
  local root, previous_generation = vim.fn.getcwd(), session_generation
  for _, name in ipairs(backends.names(config)) do
    local spec = backends.resolve(name, config)
    choices[#choices + 1] = { name = name, installed = spec and vim.fn.executable(spec.kind == "direct" and "curl" or spec.command) == 1,
      command = spec and (spec.command or "curl") or "invalid setup" }
  end
  vim.ui.select(choices, {
    prompt = "Pair backends (separate conversations):",
    format_item = function(item)
      return (item.name == config.backend and "● " or "  ") .. item.name .. "  "
        .. (item.installed and "installed" or "missing executable: " .. item.command)
    end,
  }, function(choice)
    if not choice or choice.name == config.backend then return end
    if active or starting or restoring or #queue > 0 or edit.pending() or ui.has_draft()
      or session_generation ~= previous_generation or vim.fn.getcwd() ~= root then
      notice("Pair changed while choosing a backend; open the picker again", vim.log.levels.WARN)
      return
    end
    local spec, spec_err = backends.resolve(choice.name, config)
    if not spec then notice(spec_err, vim.log.levels.ERROR); return end
    if not choice.installed then
      notice(spec.kind == "direct" and "Direct API backends need curl on PATH"
        or ("Executable for " .. choice.name .. " is missing: " .. spec.command),
        vim.log.levels.ERROR)
      return
    end
    if spec.kind == "codex" and config.transport == "exec" then
      M.backend(choice.name)
      return
    end
    local record, record_err = sessions.current(root, choice.name)
    if not record then notice(record_err, vim.log.levels.ERROR); return end
    local entries, read_err = sessions.read_transcript(record)
    if not entries then notice(read_err, vim.log.levels.ERROR); return end
    local pointer
    if vim.fn.filereadable(record.session) == 1 then
      local lines = vim.fn.readfile(record.session)
      pointer = lines[1]
    end
    if #entries > 0 and (not pointer or pointer == "") then
      notice("The " .. choice.name .. " transcript has no saved agent session and cannot be continued safely.",
        vim.log.levels.ERROR)
      return
    end
    local candidate
    local next_generation = session_generation + 1
    local backend_client = client_backend(spec)
    candidate = backend_client.new({
      provider = spec.provider, api_key = spec.api_key, key_env = spec.key_env,
      endpoint = spec.endpoint,
      command = spec.command, args = spec.args, env = spec.env,
      writable_paths = config.commands.writable_paths,
      session_meta = spec.session_meta,
      allowed_tool_names = spec.allowed_tool_names,
      allowed_tool_kinds = spec.allowed_tool_kinds,
      required_mode = spec.required_mode, model = sessions.read_model(record) or spec.model,
      cwd = root, session_file = record.session,
      on_update = function(update)
        if client == candidate and session_generation == next_generation then on_update(update) end
      end,
      on_error = function(message)
        if client == candidate and session_generation == next_generation then
          ui.add("Pair", message)
          status_error = true
          update_status()
        end
      end,
    })
    local state = { client = candidate }
    restoring = state
    update_status()
    candidate:start(function(session, connect_err)
      if restoring ~= state then candidate:stop(); return end
      restoring = nil
      if connect_err or not session or (pointer and session.sessionId ~= pointer) then
        candidate:stop()
        notice("Could not switch to " .. choice.name .. ": " .. (connect_err
          and startup_error(choice.name, spec, connect_err)
          or "the agent resumed a different session") .. ". Current conversation is unchanged.",
          vim.log.levels.ERROR)
        update_status()
        return
      end
      session_generation = next_generation
      if client then client:stop() end
      client = candidate
      config.backend = choice.name
      workspace = root
      current_record = record
      history_root = root .. "\0" .. choice.name
      session_model = sessions.read_model(record) or session.model or spec.model
      remember_selection(session_model)
      status_error = false
      outcomes = {}
      edit.dismiss_answer()
      ui.history(record.transcript)
      if not ui.is_open() then ui.chat() end
      ui.add("Pair", "Using " .. choice.name .. ". This backend has its own conversation.")
      update_status()
    end)
  end)
end

function M.model(value)
  local record, err = ensure_history()
  if not record then notice(err, vim.log.levels.ERROR); return end
  if active or starting or restoring or #queue > 0 or edit.pending() then
    notice("Finish the current request or proposal before changing models", vim.log.levels.WARN)
    return
  end
  local root, backend, generation = workspace, config.backend, session_generation
  ensure_client(function(ok, connect_err)
    if not ok then
      notice("Cannot list " .. backend .. " models: " .. connect_err,
        vim.log.levels.ERROR)
      return
    end
    if root ~= workspace or backend ~= config.backend or generation ~= session_generation then return end
    if not client.list_models then
      notice("Model picker needs the Codex app-server transport; set transport = 'app-server'", vim.log.levels.WARN)
      return
    end
    local selected_client = client
    selected_client:list_models(function(choices, list_err)
      if selected_client ~= client or generation ~= session_generation then return end
      if list_err then notice(error_text(list_err), vim.log.levels.ERROR); return end
      if #choices == 0 then
        notice("This backend did not report selectable models. Check its login and model access.", vim.log.levels.WARN)
        return
      end
      local function select(choice)
        if not choice then return end
        if selected_client ~= client or generation ~= session_generation then return end
        if active or starting or restoring or #queue > 0 or edit.pending() then
          notice("Finish the current request before changing models", vim.log.levels.WARN)
          return
        end
        starting = true
        update_status()
        selected_client:set_model(choice.value, function(model, set_err)
          if selected_client ~= client or generation ~= session_generation then return end
          starting = false
          if set_err then
            notice(error_text(set_err), vim.log.levels.ERROR)
            if not selected_client.ready then queue = {}; status_error = true end
            update_status()
            finish_connections(selected_client.ready, error_text(set_err))
            run_next()
            return
          end
          local saved, save_err = sessions.save_model(record, model)
          if not saved then notice("Model changed, but Pair could not save the choice: " .. save_err,
            vim.log.levels.ERROR) end
          session_model = model
          remember_selection(model)
          update_status()
          ui.add("Pair", "Using " .. backend .. "/" .. model .. " in this conversation")
          finish_connections(true)
          run_next()
        end)
      end
      if value and value ~= "" then
        for _, choice in ipairs(choices) do
          if choice.value == value then select(choice); return end
        end
        if backends.resolve(backend, config).kind == "direct" then
          select({ value = value, label = value })
          return
        end
        notice("Model is not available for " .. backend .. ": " .. value, vim.log.levels.ERROR)
        return
      end
      vim.ui.select(choices, {
        prompt = "Pair " .. backend .. " models:",
        format_item = function(choice)
          return (choice.value == session_model and "● " or "  ") .. choice.label
            .. (choice.label ~= choice.value and " (" .. choice.value .. ")" or "")
            .. (choice.default and "  default" or "")
        end,
      }, select)
    end)
  end)
end

function M.health_info()
  local spec, err = backends.resolve(config.backend, config)
  return {
    configured = configured,
    backend = config.backend,
    transport = spec and spec.kind == "pi" and "rpc" or config.transport,
    custom = spec and spec.custom == true or false,
    executable = spec and vim.fn.executable(spec.kind == "direct" and "curl" or spec.command) == 1 or false,
    kind = spec and spec.kind or nil,
    key_env = spec and spec.key_env or nil,
    key_present = spec and spec.kind == "direct" and ((type(spec.api_key) == "string" and spec.api_key ~= "")
      or type(spec.api_key) == "function" or (vim.env[spec.key_env] or "") ~= "") or false,
    spec_error = err,
    command_sandbox = config.backend == "antigravity" and require("pair.command_sandbox").available() or nil,
    context_max_bytes = config.context_max_bytes,
    context_nearby_lines = config.context_nearby_lines,
  }
end

function M.setup(opts)
  if vim.fn.has("nvim-0.11") ~= 1 then
    error("Pair requires Neovim 0.11 or newer")
  end
  if configured then return end
  configured = true
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  if config.transport ~= "app-server" and config.transport ~= "exec" then
    error("Pair transport must be 'app-server' or 'exec'")
  end
  local _, backend_err = backends.resolve(config.backend, config)
  if backend_err then error(backend_err) end
  if type(config.remember_selection) ~= "boolean" then
    error("Pair remember_selection must be a boolean")
  end
  if config.remember_selection then
    local saved, read_err = preferences.read()
    if read_err then notice(read_err, vim.log.levels.WARN) end
    if saved then
      for backend, model in pairs(saved.models) do
        if backends.resolve(backend, config) then config.models[backend] = model end
      end
      if saved.backend then
        if backends.resolve(saved.backend, config) then
          config.backend = saved.backend
        else
          notice("Saved backend " .. saved.backend .. " is no longer configured; using " .. config.backend,
            vim.log.levels.WARN)
        end
      end
    end
  end
  if type(config.commands) ~= "table" or type(config.commands.writable_paths) ~= "table"
    or not vim.islist(config.commands.writable_paths) then
    error("Pair commands.writable_paths must be a list of relative output directories")
  end
  for _, path in ipairs(config.commands.writable_paths) do
    if type(path) ~= "string" then error("Pair command output paths must be strings") end
  end
  if type(config.context_max_bytes) ~= "number" or config.context_max_bytes < 1
    or config.context_max_bytes % 1 ~= 0 then
    error("Pair context_max_bytes must be a positive integer")
  end
  if type(config.context_nearby_lines) ~= "number" or config.context_nearby_lines < 0
    or config.context_nearby_lines % 1 ~= 0 then
    error("Pair context_nearby_lines must be a nonnegative integer")
  end
  ui.on_send(function(message, mode, done) return M.send(message, mode, done) end)
  ui.on_cancel(M.cancel)
  update_status()
  vim.api.nvim_create_user_command("PairChat", M.toggle_chat, {})
  vim.api.nvim_create_user_command("PairSend", function(command) M.send(command.args) end, { nargs = "*" })
  -- A Visual ':' command supplies '<,'> as a line range, but its character
  -- bounds still live in the Visual marks. Numeric Ex ranges are linewise.
  local visual_ex_command
  vim.api.nvim_create_autocmd("CmdlineLeave", {
    callback = function()
      local line = vim.fn.getcmdline()
      visual_ex_command = vim.v.event.abort == false
        and (line:match("^%s*'<,'>%s*PairAsk%f[%W]")
          or line:match("^%s*'<,'>%s*PairChange%f[%W]")
          or line:match("^%s*'<,'>%s*PairActions%f[%W]"))
        and line or nil
    end,
  })
  local function command_target(command)
    local visual = visual_ex_command
    visual_ex_command = nil
    if command.range == 0 or visual then return nil end
    local target, err = edit.line_range(command.line1, command.line2)
    if not target then notice(err, vim.log.levels.WARN) end
    return target, err
  end
  vim.api.nvim_create_user_command("PairAsk", function(command)
    local target, err = command_target(command)
    if not err then M.ask(command.args, target) end
  end, { nargs = "*", range = true })
  vim.api.nvim_create_user_command("PairChange", function(command)
    local target, err = command_target(command)
    if not err then M.change(command.args, target) end
  end, { nargs = "*", range = true })
  vim.api.nvim_create_user_command("PairHere", function(command) M.here(command.args) end, { nargs = "*" })
  vim.api.nvim_create_user_command("PairActions", function(command)
    local visual = visual_ex_command ~= nil
    local target, err = command_target(command)
    if not err then M.actions(visual, target) end
  end, { range = true })
  vim.api.nvim_create_user_command("PairAccept", M.accept, {})
  vim.api.nvim_create_user_command("PairReject", M.reject, {})
  vim.api.nvim_create_user_command("PairDiff", M.diff, {})
  vim.api.nvim_create_user_command("PairCancel", M.cancel, {})
  vim.api.nvim_create_user_command("PairDismiss", M.dismiss, {})
  vim.api.nvim_create_user_command("PairNew", M.new_session, {})
  vim.api.nvim_create_user_command("PairSessions", M.pick_session, {})
  vim.api.nvim_create_user_command("PairBackends", M.pick_backend, {})
  vim.api.nvim_create_user_command("PairModel", function(command) M.model(command.args) end, { nargs = "?" })
  vim.api.nvim_create_user_command("PairBackend", function(command) M.backend(command.args) end, {
    nargs = "?",
    complete = function() return backends.names(config) end,
  })
  if config.keymaps then
    vim.keymap.set("n", "<leader>pc", M.toggle_chat, { desc = "Toggle Pair chat" })
    vim.keymap.set("n", "<leader>pp", M.actions, { desc = "Pair actions" })
    vim.keymap.set("x", "<leader>pp", ":<C-u>lua require('pair').actions(true)<CR>",
      { desc = "Pair actions for selection" })
    vim.keymap.set("n", "<leader>ps", function() M.send() end, { desc = "Pair send message" })
    vim.keymap.set("x", "<leader>pa", ":<C-u>PairAsk<CR>", { desc = "Pair ask about selection" })
    vim.keymap.set("x", "<leader>pe", ":<C-u>PairChange<CR>", { desc = "Pair change selection" })
    vim.keymap.set("n", "<leader>pi", M.here, { desc = "Pair insert here" })
    vim.keymap.set("n", "<leader>py", M.accept, { desc = "Pair accept proposal" })
    vim.keymap.set("n", "<leader>pn", M.reject, { desc = "Pair reject proposal" })
    vim.keymap.set("n", "<leader>pv", M.diff, { desc = "Pair view proposal diff" })
    vim.keymap.set("n", "<leader>pd", M.dismiss, { desc = "Pair dismiss inline answer" })
    vim.keymap.set("n", "<leader>pr", M.new_session, { desc = "Pair start a new chat session" })
    vim.keymap.set("n", "<leader>pS", M.pick_session, { desc = "Pair choose a chat session" })
    vim.keymap.set("n", "<leader>pB", M.pick_backend, { desc = "Pair choose a backend" })
    vim.keymap.set("n", "<leader>pM", function() M.model() end, { desc = "Pair choose a model" })
  end
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      if client then client:stop() end
    end,
  })
end

return M

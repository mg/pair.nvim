local uv = vim.uv or vim.loop

local M = {}

local function base_path(root, backend, create_dir)
  local dir = vim.fn.stdpath("state") .. "/pair"
  if create_dir ~= false then vim.fn.mkdir(dir, "p") end
  local suffix = backend == "codex" and "" or "." .. backend
  return dir .. "/" .. vim.fn.sha256(root) .. suffix
end

local function paths(base, id)
  local dir = base .. ".records"
  return { id = id, transcript = dir .. "/" .. id .. ".json",
    session = dir .. "/" .. id .. ".session", model = dir .. "/" .. id .. ".model" }
end

local function read_file(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local value = file:read("*a")
  file:close()
  return value
end

local function write_file(path, value)
  local temporary = path .. ".tmp." .. tostring(uv.hrtime())
  local fd, err = uv.fs_open(temporary, "w", 384)
  if not fd then return nil, err end
  local written, write_err = uv.fs_write(fd, value, 0)
  uv.fs_close(fd)
  if not written or written ~= #value then
    os.remove(temporary)
    return nil, write_err or "Incomplete Pair session write"
  end
  local moved, move_err = os.rename(temporary, path)
  if not moved then os.remove(temporary); return nil, move_err end
  return true
end

function M.read_model(record)
  local value = read_file(record.model)
  return value and vim.trim(value) ~= "" and vim.trim(value) or nil
end

function M.save_model(record, value)
  if type(value) ~= "string" or value == "" then return nil, "Invalid Pair model" end
  return write_file(record.model, value .. "\n")
end

local function redact(value)
  if type(value) ~= "string" then return value end
  value = value:gsub("sk%-[%w_-]+", function(token)
    return #token >= 16 and "[REDACTED_API_KEY]" or token
  end)
  value = value:gsub("AIza[%w_-]+", function(token)
    return #token >= 20 and "[REDACTED_API_KEY]" or token
  end)
  value = value:gsub("gh[pousr]_[%w_]+", function(token)
    return #token >= 20 and "[REDACTED_API_KEY]" or token
  end)
  value = value:gsub("([Bb]earer%s+)([%w%._%-]+)", "%1[REDACTED_API_KEY]")
  value = value:gsub("([A-Z_]*API_KEY%s*[:=]%s*['\"]?)([%w%._%-]+)",
    "%1[REDACTED_API_KEY]")
  return value
end

function M.safe_entries(entries)
  local result = {}
  for _, entry in ipairs(entries or {}) do
    if type(entry) == "table" and type(entry.role) == "string" and type(entry.text) == "string" then
      result[#result + 1] = {
        role = redact(entry.role),
        text = redact(entry.text),
        status = type(entry.status) == "string" and redact(entry.status) or nil,
        detail = type(entry.detail) == "string" and redact(entry.detail) or nil,
        expanded = entry.expanded == true,
      }
    end
  end
  return result
end

function M.save_transcript(path, entries)
  return write_file(path, vim.json.encode(M.safe_entries(entries)))
end

local function load_index(base)
  local path = base .. ".sessions.json"
  local raw = read_file(path)
  if not raw then
    if vim.fn.filereadable(path) == 1 then return nil, "Pair cannot read session index: " .. path end
    return nil
  end
  local ok, index = pcall(vim.json.decode, raw)
  if not ok or type(index) ~= "table" or index.version ~= 1
    or type(index.active) ~= "string" or type(index.records) ~= "table" then
    return nil, "Pair session index is invalid: " .. base .. ".sessions.json"
  end
  local active_found = false
  for _, record in ipairs(index.records) do
    if type(record) ~= "table" or type(record.id) ~= "string"
      or not record.id:match("^[%w_-]+$") or type(record.created_at) ~= "string" then
      return nil, "Pair session index contains an invalid record"
    end
    if record.id == index.active then active_found = true end
  end
  if not active_found then return nil, "Pair session index has no active record" end
  return index
end

local function new_record(base)
  local nonce = vim.fn.sha256(tostring(uv.hrtime()) .. tostring(math.random())):sub(1, 12)
  local id = os.date("!%Y%m%dT%H%M%SZ") .. "-" .. nonce
  local record = { id = id, created_at = os.date("!%Y-%m-%dT%H:%M:%SZ") }
  local file = paths(base, id)
  vim.fn.mkdir(base .. ".records", "p")
  local ok, err = write_file(file.transcript, "[]")
  if not ok then return nil, err end
  return record
end

local function migrate(base, root, backend)
  local legacy_transcript = read_file(base .. ".json")
  local legacy_session = read_file(base .. ".session")
  local index = { version = 1, workspace = root, backend = backend, records = {} }
  local record
  if legacy_transcript or legacy_session then
    local entries = {}
    if legacy_transcript then
      local ok, decoded = pcall(vim.json.decode, legacy_transcript)
      if not ok or type(decoded) ~= "table" then
        return nil, "Pair cannot migrate an invalid transcript: " .. base .. ".json"
      end
      entries = M.safe_entries(decoded)
    end
    record = { id = "legacy", created_at = os.date("!%Y-%m-%dT%H:%M:%SZ") }
    local file = paths(base, record.id)
    vim.fn.mkdir(base .. ".records", "p")
    local ok, err = write_file(file.transcript, vim.json.encode(entries))
    if not ok then return nil, err end
    if legacy_session then
      ok, err = write_file(file.session, legacy_session)
      if not ok then return nil, err end
    end
  else
    local err
    record, err = new_record(base)
    if not record then return nil, err end
  end
  index.records[1] = record
  index.active = record.id
  local ok, err = write_file(base .. ".sessions.json", vim.json.encode(index))
  if not ok then return nil, err end
  if legacy_transcript then os.remove(base .. ".json") end
  if legacy_session then os.remove(base .. ".session") end
  return index
end

local function index_for(root, backend)
  local base = base_path(root, backend)
  local index, err = load_index(base)
  if err then return nil, nil, err end
  if not index then
    index, err = migrate(base, root, backend)
    if not index then return nil, nil, err end
  end
  return index, base
end

function M.current(root, backend)
  local index, base, err = index_for(root, backend)
  if not index then return nil, err end
  local record = paths(base, index.active)
  if vim.fn.filereadable(record.transcript) ~= 1 then
    return nil, "Pair transcript is missing: " .. record.transcript
  end
  for _, item in ipairs(index.records) do
    if item.id == index.active then record.created_at = item.created_at; break end
  end
  return record
end

function M.create(root, backend)
  local index, base, err = index_for(root, backend)
  if not index then return nil, err end
  local record
  record, err = new_record(base)
  if not record then return nil, err end
  index.records[#index.records + 1] = record
  index.active = record.id
  local ok
  ok, err = write_file(base .. ".sessions.json", vim.json.encode(index))
  if not ok then return nil, err end
  local file = paths(base, record.id)
  file.created_at = record.created_at
  return file
end

function M.list(root, backend)
  local index, base, err = index_for(root, backend)
  if not index then return nil, err end
  local result = {}
  for _, record in ipairs(index.records) do
    local file = paths(base, record.id)
    file.created_at = record.created_at
    file.active = record.id == index.active
    result[#result + 1] = file
  end
  return result
end

function M.read_transcript(record)
  if type(record) ~= "table" or type(record.transcript) ~= "string" then
    return nil, "Invalid Pair session record"
  end
  local raw = read_file(record.transcript)
  if not raw then return nil, "Pair transcript is missing: " .. record.transcript end
  local ok, entries = pcall(vim.json.decode, raw)
  if not ok or type(entries) ~= "table" or not vim.islist(entries) then
    return nil, "Pair transcript is invalid: " .. record.transcript
  end
  for _, entry in ipairs(entries) do
    if type(entry) ~= "table" or type(entry.role) ~= "string" or type(entry.text) ~= "string" then
      return nil, "Pair transcript contains an invalid entry: " .. record.transcript
    end
  end
  return entries
end

function M.inspect(root, backend)
  local base = base_path(root, backend, false)
  local index_path = base .. ".sessions.json"
  if not uv.fs_stat(index_path) then return { exists = false, index_path = index_path } end
  local index, err = load_index(base)
  if not index then return nil, err or "Pair cannot read session index: " .. index_path end
  local record = paths(base, index.active)
  local entries, read_err = M.read_transcript(record)
  if not entries then return nil, read_err end
  local pointer = read_file(record.session)
  if not pointer and uv.fs_stat(record.session) then
    return nil, "Pair cannot read saved agent session: " .. record.session
  end
  return {
    exists = true,
    index_path = index_path,
    records = #index.records,
    entries = #entries,
    pointer_saved = pointer ~= nil and vim.trim(pointer) ~= "",
  }
end

function M.activate(root, backend, id, expected_active)
  local index, base, err = index_for(root, backend)
  if not index then return nil, err end
  if expected_active and index.active ~= expected_active then
    return nil, "Pair's active session changed while restoring; open the picker again"
  end
  local selected
  for _, item in ipairs(index.records) do
    if item.id == id then selected = item; break end
  end
  if not selected then return nil, "Pair session record no longer exists" end
  local record = paths(base, id)
  record.created_at = selected.created_at
  local entries, read_err = M.read_transcript(record)
  if not entries then return nil, read_err end
  if id == index.active then return record end
  index.active = id
  local ok
  ok, err = write_file(base .. ".sessions.json", vim.json.encode(index))
  if not ok then return nil, err end
  return record
end

return M

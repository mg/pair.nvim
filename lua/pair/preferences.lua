local uv = vim.uv or vim.loop
local M = {}

local function path()
  return vim.fn.stdpath("state") .. "/pair/preferences.json"
end

local function valid_name(value)
  return type(value) == "string" and #value <= 128 and value:match("^[%w_%-]+$") ~= nil
end

local function valid_model(value)
  return type(value) == "string" and #value > 0 and #value <= 512 and not value:find("%c")
end

function M.read()
  local file = io.open(path(), "r")
  if not file then
    if uv.fs_stat(path()) then return nil, "Could not read saved Pair selections" end
    return { models = {} }
  end
  local raw = file:read(65537)
  file:close()
  local ok, data = pcall(vim.json.decode, raw or "")
  if not ok or #raw > 65536 or type(data) ~= "table" or data.version ~= 1
    or not valid_name(data.backend) or type(data.models) ~= "table" then
    return nil, "Saved Pair selections are invalid; using setup defaults"
  end
  for backend, model in pairs(data.models) do
    if not valid_name(backend) or not valid_model(model) then
      return nil, "Saved Pair selections are invalid; using setup defaults"
    end
  end
  return { backend = data.backend, models = data.models }
end

function M.save(backend, model)
  if not valid_name(backend) or (model ~= nil and not valid_model(model)) then
    return nil, "Invalid Pair backend or model selection"
  end
  -- Merge the latest file so another Neovim's model choices survive this save.
  local data = M.read() or { models = {} }
  data.version, data.backend = 1, backend
  if model then data.models[backend] = model end
  local directory = vim.fn.fnamemodify(path(), ":h")
  local made, make_err = pcall(vim.fn.mkdir, directory, "p")
  if not made then return nil, tostring(make_err) end
  local temporary = path() .. ".tmp." .. tostring(uv.hrtime())
  local fd, open_err = uv.fs_open(temporary, "w", 384) -- 0600
  if not fd then return nil, open_err end
  local encoded = vim.json.encode(data)
  local written, write_err = uv.fs_write(fd, encoded, 0)
  uv.fs_close(fd)
  if written ~= #encoded then
    os.remove(temporary)
    return nil, write_err or "Incomplete Pair selection write"
  end
  local moved, move_err = os.rename(temporary, path())
  if not moved then os.remove(temporary); return nil, move_err end
  return true
end

return M

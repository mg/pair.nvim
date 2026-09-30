local M = {}

function M.check()
  vim.health.start("Pair.nvim")

  if vim.fn.has("nvim-0.11") == 1 then
    vim.health.ok("Neovim 0.11 or newer")
  else
    vim.health.error("Pair requires Neovim 0.11 or newer")
    return
  end

  local loaded, pair = pcall(require, "pair")
  if not loaded then
    vim.health.error("Pair could not load: " .. tostring(pair))
    return
  end
  local info = pair.health_info()
  if info.configured then
    vim.health.ok("Pair setup() has run")
  else
    vim.health.warn("Pair setup() has not run. Add require('pair').setup() to your Neovim config")
  end

  vim.health.info("Selected backend: " .. info.backend .. " ("
    .. (info.kind == "direct" and "direct API" or info.transport) .. ")")
  if info.spec_error then
    vim.health.error("Selected backend configuration: " .. info.spec_error)
  elseif info.executable then
    vim.health.ok((info.kind == "direct" and "curl" or "Selected backend executable") .. " is available")
  else
    vim.health.error("Selected backend executable is missing. Install " .. info.backend
      .. " or set its command in setup()")
  end
  if info.kind == "direct" then
    if info.key_present then
      vim.health.ok("Direct API credential is configured (value hidden)")
    else
      vim.health.error("Direct API credential is missing. Set " .. info.key_env
        .. " or setup().api_keys for this provider")
    end
  end
  if info.custom then
    vim.health.info("Custom ACP agent restrictions must be verified in the agent itself")
  end
  if info.backend == "codex" and info.transport == "exec" then
    vim.health.warn("Codex exec cannot verify saved-session restoration or offer a model picker; use app-server")
  end
  vim.health.info("Context: current unsaved buffer is attached by default; limit "
    .. tostring(info.context_max_bytes) .. " bytes; nearby fallback "
    .. tostring(info.context_nearby_lines) .. " lines")

  local state_root = vim.fn.stdpath("state")
  local state_dir = state_root .. "/pair"
  local writable = vim.fn.isdirectory(state_dir) == 1
    and vim.fn.filewritable(state_dir) == 2
    or vim.fn.isdirectory(state_dir) == 0 and vim.fn.filewritable(state_root) == 2
  if writable then
    vim.health.ok("Session state directory is writable: " .. state_dir)
  else
    vim.health.error("Session state directory is not writable: " .. state_dir)
  end

  local session, session_err = require("pair.sessions").inspect(vim.fn.getcwd(), info.backend)
  if not session then
    vim.health.error("Saved session metadata: " .. session_err
      .. ". Use :PairNew after fixing or moving the damaged state files")
  elseif not session.exists then
    vim.health.info("No saved Pair sessions for this workspace and backend yet")
  elseif session.entries > 0 and not session.pointer_saved then
    vim.health.warn("Active transcript has messages but no agent session pointer; it cannot be continued safely")
  else
    vim.health.ok("Session index and active transcript are readable (" .. session.records
      .. " conversation" .. (session.records == 1 and "" or "s") .. ")")
  end

  if require("pair.edit").pending() then
    vim.health.info("A code proposal is pending; use :PairAccept, :PairReject, or :PairDiff")
  end
  vim.health.info("Login, model entitlement, and agent tool permissions are not probed. Send a message to verify access")
end

return M

vim.opt.rtp:append(vim.fn.getcwd())

local sessions = require("pair.sessions")
local root = vim.fn.tempname()
local other_root = vim.fn.tempname()
local state = vim.fn.stdpath("state") .. "/pair/"
local base = state .. vim.fn.sha256(root) .. ".mock"
local other_base = state .. vim.fn.sha256(other_root) .. ".mock"
local backend_base = state .. vim.fn.sha256(root) .. ".other"
vim.fn.mkdir(state, "p")

local old_key = "sk-testvalue123456789abcdef"
vim.fn.writefile({ vim.json.encode({
  { role = "You", text = "OPENAI_API_KEY=secret123 " .. old_key },
  { role = "Agent", text = "Previous answer" },
}) }, base .. ".json")
vim.fn.writefile({ "previous-agent-session" }, base .. ".session")

local first = assert(sessions.current(root, "mock"))
assert(first.id == "legacy" and vim.fn.readfile(first.session)[1] == "previous-agent-session",
  "legacy agent pointer should migrate into the first record")
local migrated = table.concat(vim.fn.readfile(first.transcript), "\n")
assert(migrated:find("Previous answer", 1, true)
  and not migrated:find("secret123", 1, true) and not migrated:find(old_key, 1, true),
  "migration should keep conversation text while redacting recognizable API keys")
assert(vim.fn.filereadable(base .. ".json") == 0
  and vim.fn.filereadable(base .. ".session") == 0,
  "legacy files should move into their indexed record")

local again = assert(sessions.current(root, "mock"))
assert(again.id == first.id and #assert(sessions.list(root, "mock")) == 1,
  "reopening a workspace and backend should reuse its active record")
local second = assert(sessions.create(root, "mock"))
assert(second.id ~= first.id and vim.fn.filereadable(first.session) == 1,
  "creating a chat must keep the earlier pointer")
if vim.fn.has("unix") == 1 then
  assert(vim.fn.getfperm(second.transcript) == "rw-------"
    and vim.fn.getfperm(base .. ".sessions.json") == "rw-------",
    "new Pair transcript and index files must be owner-only")
end
local records = assert(sessions.list(root, "mock"))
assert(#records == 2 and records[1].created_at and records[2].created_at
  and records[2].active and assert(sessions.current(root, "mock")).id == second.id,
  "index should retain timestamped records and identify the active one")
assert(vim.json.decode(table.concat(vim.fn.readfile(second.transcript), "\n"))[1] == nil,
  "new transcript should start empty")
local restored = assert(sessions.activate(root, "mock", first.id, second.id))
assert(restored.id == first.id and assert(sessions.current(root, "mock")).id == first.id,
  "activating a stored record should move the active index")
assert(not sessions.activate(root, "mock", second.id, second.id),
  "activation should reject a stale view of the active index")
assert(assert(sessions.activate(root, "mock", second.id, first.id)).id == second.id,
  "switching back should preserve both records")
vim.fn.writefile({ "not json" }, first.transcript)
assert(not sessions.activate(root, "mock", first.id, second.id)
  and assert(sessions.current(root, "mock")).id == second.id,
  "a corrupt older transcript must not become the active record")

local other_workspace = assert(sessions.current(other_root, "mock"))
local other_backend = assert(sessions.current(root, "other"))
assert(other_workspace.id ~= first.id and other_workspace.transcript ~= second.transcript
  and other_backend.transcript ~= second.transcript,
  "workspace and backend records should have separate storage")
assert(#assert(sessions.list(other_root, "mock")) == 1
  and #assert(sessions.list(root, "other")) == 1,
  "creating another scope must not change the first scope's records")

local ui = require("pair.ui")
ui.history(second.transcript)
ui.add("You", "ANTHROPIC_API_KEY=anotherSecret Bearer token12345")
local stored = table.concat(vim.fn.readfile(second.transcript), "\n")
assert(not stored:find("anotherSecret", 1, true)
  and not stored:find("token12345", 1, true)
  and stored:find("[REDACTED_API_KEY]", 1, true),
  "new transcript writes should redact recognizable credentials")
local index = table.concat(vim.fn.readfile(base .. ".sessions.json"), "\n")
assert(not index:find("secret123", 1, true) and not index:find(old_key, 1, true),
  "session metadata must not contain raw credentials")

for _, prefix in ipairs({ base, other_base, backend_base }) do
  vim.fn.delete(prefix .. ".records", "rf")
  vim.fn.delete(prefix .. ".sessions.json")
end
print("Pair durable session store tests passed")

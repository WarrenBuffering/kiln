-- Observed files and command results, scoped to the dossier definition that
-- produced them. Assistant prose is never treated as verification evidence.
local M = {}

local function clean(value)
  return tostring(value or ''):gsub('[\r\n\t]', ' '):gsub('%c', ''):gsub(' +', ' ')
end
local function runtime(session, id)
  local flow = session.workflow or {}
  return type(flow.steps) == 'table' and flow.steps[id] or nil
end
local function fingerprint(session, id)
  local record = runtime(session, id)
  return record and record.fingerprint
end
local function valid_record(session, id)
  local record = session.evidence and session.evidence.steps and session.evidence.steps[id]
  if record and record.fingerprint ~= fingerprint(session, id) then return nil end
  return record
end
function M.reset(session, id, value)
  session.evidence = session.evidence or { steps = {}, sequence = 0 }
  session.evidence.steps = session.evidence.steps or {}
  session.evidence.steps[id] = { fingerprint = value, files = {}, checks = {}, errors = {}, tools = {}, file_epoch = 0 }
  return session.evidence.steps[id]
end

local function safe_path(value, root)
  if type(value) ~= 'string' or value == '' or value:find('%c') then return nil end
  local path = vim.fs.normalize(value)
  if path:sub(1, 1) == '/' then
    if not root then return nil end
    root = vim.fs.normalize(root):gsub('/+$', '')
    if path:sub(1, #root + 1) ~= root .. '/' then return nil end
    path = path:sub(#root + 2)
  end
  if path == '.' or path == '..' or path:sub(1, 3) == '../' then return nil end
  return path
end

local function command_parts(event)
  local text = tostring(event.text or '')
  local command, output = text:match('^([^\n]*)\n(.*)$')
  command, output = command or text, output or ''
  if command:sub(1, 1) == '{' then
    local ok, value = pcall(vim.json.decode, command)
    if ok and type(value) == 'table' and type(value.command) == 'string' then command = value.command end
  end
  command = vim.trim(command)
  -- Codex exposes its shell wrapper; Claude exposes the JSON command input.
  -- Normalize those wrappers so a successful retry replaces the failed check.
  local inner = command:match('^/[%w/_%-]+%s+%-[lc]+%s+(.+)$')
  if inner then command = inner end
  local quote = command:sub(1, 1)
  if (quote == '"' or quote == "'") and command:sub(-1) == quote then command = command:sub(2, -2) end
  return command, output
end

local function verification_command(command)
  local value = vim.trim(command:lower())
  -- Match an invoked program, not a runner name quoted in echo/cat output.
  -- Unknown wrappers remain inspectable tool activity without invented checks.
  value = value:gsub('^/[%w/_.%-]+/', '')
  for _, pattern in ipairs({ '^elixir%s+[^\n]*%.exs', '^mix%s+test%f[%W]',
    '^pytest%f[%W]', '^python[%.%d]*%s+%-m%s+unittest%f[%W]',
    '^python[%.%d]*%s+%-m%s+pytest%f[%W]',
    '^npm%s+test%f[%W]', '^npm%s+run%s+test%f[%W]',
    '^pnpm%s+test%f[%W]', '^yarn%s+test%f[%W]',
    '^vitest%f[%W]', '^jest%f[%W]', '^cargo%s+test%f[%W]',
    '^go%s+test%f[%W]', '^make%s+test%f[%W]',
    '^git%s+diff%s+%-%-check%f[%W]' }) do
    if value:find(pattern) then return true end
  end
  return false
end

local function counts(output)
  local passed, failed
  -- ExUnit's totals include failures. Match complete summary lines rather
  -- than command input or arbitrary assistant claims.
  for line in (output .. '\n'):gmatch('(.-)\n') do
    line = vim.trim(line:gsub('\27%[[%d;]*m', ''))
    local total, failures = line:match('^(%d+) tests?, (%d+) failures?')
    local line_passed, line_failed
    if total then line_passed, line_failed = tonumber(total) - tonumber(failures), tonumber(failures) end
    local rust_passed, rust_failed = line:match('^test result: %w+%. (%d+) passed; (%d+) failed;')
    if rust_passed then line_passed, line_failed = tonumber(rust_passed), tonumber(rust_failed) end
    if line:match('^=+') and line:match('=+$') or line:match('^Tests:%s')
      or line:match('^Tests%s+%d+') or line:match('^%d+ passed.* in [%d%.]+s$')
      or line:match('^%d+ failed.* in [%d%.]+s$') then
      local p, f = line:match('(%d+) passed'), line:match('(%d+) failed')
      if p or f then line_passed, line_failed = tonumber(p) or 0, tonumber(f) or 0 end
    end
    if line_passed then passed, failed = (passed or 0) + line_passed, (failed or 0) + line_failed end
  end
  return passed, failed
end

function M.observe(session, event, root)
  if root then
    session.evidence = session.evidence or { steps = {}, sequence = 0 }
    session.evidence.root = root
  end
  local id = event.step_id
  root = root or event.root or (session.workspace and session.workspace.root) or session.root
    or (session.evidence and session.evidence.root)
  if type(id) ~= 'string' or id == '' then
    local path = (event.type == 'human' or event.type == 'file') and safe_path(event.path, root)
    if path then
      session.evidence = session.evidence or { steps = {}, sequence = 0 }
      session.evidence.sequence = (session.evidence.sequence or 0) + 1
      if event.type == 'human' then
        session.evidence.unassigned_files = session.evidence.unassigned_files or {}
        session.evidence.unassigned_files[path] = { path = path, action = 'update', actor = 'human',
          sequence = session.evidence.sequence }
      end
      for other_id in pairs(session.evidence.steps or {}) do
        local other = valid_record(session, other_id)
        if other and (event.type == 'human' or other.files[path]) then
          other.file_epoch = (other.file_epoch or 0) + 1
          for _, check in pairs(other.checks) do check.stale = true end
        end
      end
    end
    return
  end
  local expected = fingerprint(session, id)
  if event.step_fingerprint and event.step_fingerprint ~= expected then return end
  if not runtime(session, id) then return end
  local record = valid_record(session, id) or M.reset(session, id, expected)
  session.evidence.sequence = (session.evidence.sequence or 0) + 1
  local sequence = session.evidence.sequence
  if event.type == 'file' or event.type == 'human' then
    local path = safe_path(event.path, root)
    if path then
      -- A successful check describes the source it observed. A later edit to
      -- this outcome (or one of another outcome's files) requires a rerun.
      -- A new human path may be a shared dependency, so invalidate all known
      -- checks rather than claiming it is unrelated without evidence.
      for other_id in pairs(session.evidence.steps) do
        local other = valid_record(session, other_id)
        if other and (other_id == id or other.files[path] or event.type == 'human') then
          other.file_epoch = (other.file_epoch or 0) + 1
          for _, check in pairs(other.checks) do check.stale = true end
        end
      end
      record.files[path] = { path = path, action = event.action or 'update', sequence = sequence,
        actor = event.type == 'human' and 'human' or 'agent' }
      record.last_action = { kind = 'file', path = path, text = 'Changed ' .. path, sequence = sequence, turn_id = event.turn_id }
    end
  elseif event.type == 'tool' then
    local key = event.id or ('anonymous:' .. sequence)
    local command, output = command_parts(event)
    local shell = event.name == 'Shell' or event.name == 'Bash'
    local is_check = shell and verification_command(command)
    local exit = tonumber(output:match('%[exit (%-?%d+)%]%s*$'))
    local status = event.status or 'running'
    if exit and exit ~= 0 then status = 'error' end
    local observed = { id = key, name = event.name, command = command, status = status,
      text = tostring(event.text or ''), sequence = sequence, turn_id = event.turn_id,
      path = safe_path(event.path, root), verification = is_check }
    record.tools[key] = observed
    if is_check or (shell and status == 'error') then
      local passed, failed = counts(output)
      -- A failed tool never creates a green test total, even if earlier output
      -- in that same command includes a passing suite.
      if status ~= 'done' then passed = nil end
      if (failed or 0) > 0 then status, observed.status = 'error', 'error' end
      local check = vim.deepcopy(observed)
      check.tests_passed, check.tests_failed = passed, failed
      check.status = status
      local previous = record.checks[command]
      check.file_epoch = previous and previous.id == key and previous.file_epoch or (record.file_epoch or 0)
      check.stale = check.file_epoch ~= (record.file_epoch or 0)
      record.checks[command] = check
    end
    record.last_action = { kind = is_check and 'check' or 'tool', name = event.name,
      path = observed.path, command = command, status = observed.status, sequence = sequence, turn_id = event.turn_id }
  elseif event.type == 'error' then
    record.errors[event.id or ('error:' .. sequence)] = { text = tostring(event.text or 'Provider error'),
      sequence = sequence, turn_id = event.turn_id }
  end
end

function M.finish(session, id, ok)
  local record = valid_record(session, id)
  if not record then return end
  for _, group in ipairs({ record.tools, record.checks }) do
    for _, item in pairs(group) do
      if item.status == 'running' then item.status = 'stopped' end
    end
  end
  if record.last_action and record.last_action.status == 'running' then record.last_action.status = 'stopped' end
  if ok then record.errors = {} end
end

local function add_check(summary, check)
  summary.checks[#summary.checks + 1] = vim.deepcopy(check)
  if check.status == 'running' then summary.checks_running = summary.checks_running + 1
  elseif check.stale then
    summary.checks_stale = summary.checks_stale + 1
    summary.unresolved[#summary.unresolved + 1] = 'Rerun after edits: ' .. check.command
  elseif check.status == 'error' then
    summary.checks_failed = summary.checks_failed + 1
    summary.tests_failed = summary.tests_failed + (check.tests_failed or 0)
    summary.unresolved[#summary.unresolved + 1] = 'Failed: ' .. check.command
  elseif check.status == 'done' then
    summary.checks_passed = summary.checks_passed + 1
    summary.tests_passed = summary.tests_passed + (check.tests_passed or 0)
  elseif check.status == 'stopped' then
    summary.unresolved[#summary.unresolved + 1] = 'Not finished: ' .. check.command
  end
end
local function blank()
  return { files = {}, checks = {}, tests_passed = 0, tests_failed = 0,
    checks_passed = 0, checks_failed = 0, checks_running = 0, checks_stale = 0, unresolved = {} }
end
local function latest_tools(record)
  local latest = {}
  for _, tool in pairs(record and record.tools or {}) do
    local key = (tool.name or 'Tool') .. '\0' .. (tool.path or tool.command)
    if not latest[key] or tool.sequence > latest[key].sequence then latest[key] = tool end
  end
  return latest
end
local function tool_failures(summary, tools)
  for _, tool in pairs(tools) do
    if tool.status == 'error' and not tool.verification and tool.name ~= 'Shell' and tool.name ~= 'Bash' then
      summary.unresolved[#summary.unresolved + 1] = 'Failed: ' .. (tool.name or 'Tool') .. ' ' .. (tool.path or tool.command)
    end
  end
end
function M.summary(session, id)
  local result, record = blank(), valid_record(session, id)
  if not record then return result end
  for _, file in pairs(record.files) do result.files[#result.files + 1] = vim.deepcopy(file) end
  table.sort(result.files, function(a, b) return a.path < b.path end)
  for _, check in pairs(record.checks) do add_check(result, check) end
  table.sort(result.checks, function(a, b) return a.sequence < b.sequence end)
  for _, error in pairs(record.errors) do result.unresolved[#result.unresolved + 1] = error.text end
  tool_failures(result, latest_tools(record))
  table.sort(result.unresolved)
  result.last_action = vim.deepcopy(record.last_action)
  return result
end

function M.review(session, plan)
  local result = blank()
  result.groups = {}
  local files, checks, tools = {}, {}, {}
  for path, file in pairs(session.evidence and session.evidence.unassigned_files or {}) do files[path] = file end
  for index, step in ipairs(plan and plan.steps or {}) do
    local summary = M.summary(session, step.id)
    local record = runtime(session, step.id) or {}
    summary.id, summary.title, summary.index, summary.status = step.id, step.title, index, record.status or 'pending'
    result.groups[#result.groups + 1] = summary
    for _, file in ipairs(summary.files) do files[file.path] = file end
    for _, check in ipairs(summary.checks) do
      if not checks[check.command] or check.sequence > checks[check.command].sequence then checks[check.command] = check end
    end
    if summary.status ~= 'done' then result.unresolved[#result.unresolved + 1] = step.title .. ': ' .. summary.status end
    if summary.status == 'done' and #summary.checks == 0 then
      result.unresolved[#result.unresolved + 1] = step.title .. ': no check results recorded'
    end
    local observed = valid_record(session, step.id)
    for key, tool in pairs(latest_tools(observed)) do
      if not tools[key] or tool.sequence > tools[key].sequence then tools[key] = tool end
    end
    for _, error in pairs(observed and observed.errors or {}) do result.unresolved[#result.unresolved + 1] = error.text end
  end
  for _, file in pairs(files) do result.files[#result.files + 1] = file end
  table.sort(result.files, function(a, b) return a.path < b.path end)
  for _, check in pairs(checks) do add_check(result, check) end
  tool_failures(result, tools)
  table.sort(result.checks, function(a, b) return a.sequence < b.sequence end)
  return result
end

function M.action(session)
  local flow = session.workflow or {}
  local summary = flow.current and M.summary(session, flow.current) or blank()
  local latest = summary.last_action
  if latest and session.turn_id and latest.turn_id ~= session.turn_id then latest = nil end
  if not latest then
    -- Planning has no dossier step yet. Read the provider's current real turn
    -- directly, excluding old activity from earlier turns or providers.
    for index = #(session.events or {}), 1, -1 do
      local event = session.events[index]
      if (not session.turn_id or event.turn_id == session.turn_id) and event.type == 'tool' then
        local command = command_parts(event)
        latest = { kind = (event.name == 'Shell' or event.name == 'Bash') and verification_command(command) and 'check' or 'tool',
          name = event.name, path = safe_path(event.path, event.root or session.root or
            (session.workspace and session.workspace.root) or (session.evidence and session.evidence.root)),
          command = command, status = event.status, turn_id = event.turn_id }
        break
      end
    end
  end
  if latest and latest.kind == 'check' and latest.status == 'running' then return 'Running checks', latest end
  if latest and latest.kind == 'tool' and latest.status == 'running' then
    if latest.name == 'Read' then return 'Reading ' .. (latest.path or 'files'), latest end
    if latest.name == 'Edit' or latest.name == 'Write' or latest.name == 'Files' then
      return 'Editing ' .. (latest.path or 'files'), latest
    end
    return 'Running ' .. clean(latest.name or 'tool'), latest
  end
  if latest and latest.kind == 'file' then return 'Changed ' .. latest.path, latest end
  return 'Waiting for provider', latest
end

return M

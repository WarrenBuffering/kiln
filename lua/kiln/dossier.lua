-- Dossiers describe justified deliverables. Only explicit dependencies impose ordering.
local M = {}
local function trim(value) return vim.trim(tostring(value or '')) end
local function valid_id(value) return #value <= 64 and value:match('^[A-Za-z0-9][A-Za-z0-9_-]*$') ~= nil end
local function hash(value) return vim.fn.sha256(vim.json.encode(value)) end

local function fence_marker(line)
  local marker, tail = line:match('^%s*(```+)(.*)$')
  if not marker then marker, tail = line:match('^%s*(~~~+)(.*)$') end
  return marker, tail
end

local function advance_fence(line, fence)
  local marker, tail = fence_marker(line)
  if not marker then return fence end
  if not fence then return marker end
  if marker:sub(1, 1) == fence:sub(1, 1) and #marker >= #fence and trim(tail) == '' then return nil end
  return fence
end

-- Hidden Markdown comments cannot supply requirements or executable steps.
-- Preserve line positions and raw instructions, and leave literal code examples alone.
local function visible_lines(raw)
  local result, comment, fence = {}, false, nil
  for _, line in ipairs(raw) do
    if fence or (not comment and fence_marker(line)) then
      result[#result + 1] = line
      fence = advance_fence(line, fence)
    else
      local parts, position = {}, 1
      while position <= #line do
        if comment then
          local finish = line:find('-->', position, true)
          if not finish then break end
          comment, position = false, finish + 3
        else
          local start = line:find('<!--', position, true)
          if not start then parts[#parts + 1] = line:sub(position); break end
          parts[#parts + 1] = line:sub(position, start - 1)
          comment, position = true, start + 4
        end
      end
      local visible = table.concat(parts)
      result[#result + 1] = visible
      if not comment then fence = advance_fence(visible, nil) end
    end
  end
  return result
end

local function fields(body, recognized, label)
  local values, fence = {}, nil
  for _, line in ipairs(visible_lines(body)) do
    local marker = fence_marker(line)
    if marker then
      fence = advance_fence(line, fence)
    elseif not fence then
      local key, value = line:match('^%s*([%w][%w ]-):%s*(.*)$')
      key = key and trim(key):lower()
      if key and recognized[key] then
        if values[key] ~= nil then return nil, label .. ' repeats ' .. recognized[key] .. '.' end
        values[key] = trim(value)
      end
    end
  end
  return values
end

local function required(values, key, label, display)
  if not values[key] or values[key] == '' then return label .. ' needs a nonempty ' .. display .. ': field.' end
end

function M.parse(text)
  if type(text) ~= 'string' then return nil, 'Dossier must be Markdown text.' end
  if text:find('%z') then return nil, 'Dossier cannot contain NUL bytes.' end
  text = text:gsub('\r\n', '\n'):gsub('\r', '\n')
  local plan = { title = nil, brief = '', steps = {} }
  local brief, current, fence = {}, nil, nil
  local seen = {}
  local raw = vim.split(text, '\n', { plain = true })
  for number, line in ipairs(visible_lines(raw)) do
    local marker = fence_marker(line)
    local structural = not fence and not marker
    if marker then fence = advance_fence(line, fence) end
    local title = structural and line:match('^#%s+(.*)$')
    local step_text = structural and line:match('^##%s+[Ss][Tt][Ee][Pp]%s+(.*)$')
    if title then
      if plan.title then return nil, 'Line ' .. number .. ': use one top-level dossier title.' end
      if current then return nil, 'Line ' .. number .. ': dossier title must precede its steps.' end
      plan.title = trim(title)
      if plan.title == '' then return nil, 'Line ' .. number .. ': dossier title cannot be empty.' end
    elseif step_text then
      local id, step_title = step_text:match('^([^:]+):%s*(.*)$')
      id, step_title = id and trim(id), step_title and trim(step_title)
      if not id or not valid_id(id) then return nil, 'Line ' .. number .. ': use ## Step ID: Title with a short alphanumeric ID.' end
      if not step_title or step_title == '' then return nil, 'Line ' .. number .. ': step title cannot be empty.' end
      if seen[id] then return nil, 'Duplicate step ID: ' .. id .. '.' end
      current = { id = id, title = step_title, body = {}, depends_on = {} }
      plan.steps[#plan.steps + 1], seen[id] = current, true
    else
      table.insert(current and current.body or brief, raw[number])
    end
  end
  if fence then return nil, 'Close the fenced code block before adopting the dossier.' end
  if not plan.title then return nil, 'Add a # Dossier title before the brief.' end
  if #plan.steps == 0 then return nil, 'Add at least one justified deliverable using ## Step ID: Title.' end
  plan.brief = trim(table.concat(brief, '\n'))
  local shared, err = fields(brief, { approach = 'Approach', ['why this approach'] = 'Why this approach' }, 'The shared brief')
  if not shared then return nil, err end
  err = required(shared, 'approach', 'The shared brief', 'Approach')
    or required(shared, 'why this approach', 'The shared brief', 'Why this approach')
  if err then return nil, err end
  plan.approach, plan.rationale = shared.approach, shared['why this approach']
  local by_id = {}
  for _, step in ipairs(plan.steps) do
    local label = 'Step ' .. step.id
    local values
    values, err = fields(step.body, { outcome = 'Outcome', why = 'Why', verify = 'Verify', depends = 'Depends',
      provider = 'Provider', model = 'Model',
      ['dependency reason'] = 'Dependency reason' }, label)
    if not values then return nil, err end
    err = required(values, 'outcome', label, 'Outcome') or required(values, 'why', label, 'Why')
      or required(values, 'verify', label, 'Verify')
    if err then return nil, err end
    step.outcome, step.rationale, step.verify = values.outcome, values.why, values.verify
    if values.provider ~= nil then
      if values.provider ~= 'codex' and values.provider ~= 'claude' then
        return nil, label .. ': Provider must be codex or claude.'
      end
      step.provider = values.provider
    end
    if values.model ~= nil then
      if values.model == '' or values.model:find('%c') then return nil, label .. ': Model must be a nonempty single-line ID.' end
      step.model = values.model
    end
    step.dependency_reason = values['dependency reason']
    local depends = values.depends
    if depends ~= nil and depends:lower() ~= 'none' then
      if depends == '' then return nil, label .. ': Depends must be none or comma-separated step IDs.' end
      local dependencies = {}
      for _, id in ipairs(vim.split(depends, ',', { plain = true })) do
        id = trim(id)
        if not valid_id(id) then return nil, label .. ': invalid dependency ID ' .. id .. '.' end
        if dependencies[id] then return nil, label .. ': repeated dependency ' .. id .. '.' end
        if id == step.id then return nil, label .. ' cannot depend on itself.' end
        dependencies[id] = true
        step.depends_on[#step.depends_on + 1] = id
      end
      err = required(values, 'dependency reason', label, 'Dependency reason')
      if err then return nil, err end
    end
    step.instructions = trim(table.concat(step.body, '\n'))
    step.body = nil
    -- Shared-brief revisions affect future launches, not the identity of dispatched deliverables.
    step.fingerprint = hash({ step.id, step.title, step.instructions, step.depends_on })
    by_id[step.id] = step
  end
  for _, step in ipairs(plan.steps) do
    for _, id in ipairs(step.depends_on) do
      if not by_id[id] then return nil, 'Step ' .. step.id .. ' depends on missing step ' .. id .. '.' end
    end
  end
  local visiting, complete = {}, {}
  local function visit(id)
    if visiting[id] then return false, 'Dependency cycle includes step ' .. id .. '.' end
    if complete[id] then return true end
    visiting[id] = true
    for _, parent in ipairs(by_id[id].depends_on) do
      local valid, reason = visit(parent)
      if not valid then return false, reason end
    end
    visiting[id], complete[id] = nil, true
    return true
  end
  for _, step in ipairs(plan.steps) do
    local valid, reason = visit(step.id)
    if not valid then return nil, reason end
  end
  local fingerprints = {}
  for _, step in ipairs(plan.steps) do fingerprints[#fingerprints + 1] = step.fingerprint end
  plan.fingerprint = hash({ plan.title, plan.brief, fingerprints })
  return plan
end

function M.template(title)
  return table.concat({ '# ' .. (trim(title) ~= '' and trim(title):gsub('[\r\n]', ' ') or 'Feature dossier'), '',
    'Approach: ', 'Why this approach: ', '', '## Step deliver: Deliver the requested behavior', '',
    'Outcome: ', 'Why: ', 'Verify: ', 'Depends: none', '',
    '<!-- Keep one cohesive deliverable when that is sufficient. Add another only when its outcome justifies separate review. -->', '' }, '\n')
end

function M.render(plan)
  local out = { '# ' .. plan.title, '', plan.brief or '' }
  for _, step in ipairs(plan.steps or {}) do
    vim.list_extend(out, { '', '## Step ' .. step.id .. ': ' .. step.title, '', step.instructions or '' })
  end
  return table.concat(out, '\n') .. '\n'
end

function M.readiness(plan, sessions)
  local by_session, by_step = {}, {}
  for index, session in ipairs(sessions or {}) do
    if session.id then by_session[session.id] = { session = session, index = index } end
  end
  for _, step in ipairs(plan and plan.steps or {}) do by_step[step.id] = step end
  local rows = {}
  for _, step in ipairs(plan and plan.steps or {}) do
    local binding = step.session_id and by_session[step.session_id]
    local session = binding and binding.session
    local row = { id = step.id, title = step.title, step = step, session = session,
      index = binding and binding.index, ready = false, status = 'pending', reason = '' }
    local unmet = {}
    for _, id in ipairs(step.depends_on or {}) do
      local parent = by_step[id]
      local assigned = parent and parent.session_id and by_session[parent.session_id]
      if not assigned or assigned.session.work_status ~= 'integrated' then unmet[#unmet + 1] = id end
    end
    if session and (session.job or session.native_job or session.operation) then
      row.status = 'running'
      row.reason = session.stopping and 'Waiting for the agent to stop' or 'Task is active'
    elseif session and session.work_status == 'integrated' then
      row.status, row.reason = 'integrated', 'Integrated into the main checkout'
    elseif session and session.human_control then
      row.status, row.reason = 'blocked', 'You are handcoding this task'
    elseif session and (session.work_status == 'missing' or session.status == 'error' or session.status == 'blocked'
        or session.status == 'interrupted' or session.status == 'stopped' or session.status == 'running'
        or session.status == 'native' or session.status == 'stopping') then
      row.status, row.reason = 'blocked', 'Task needs your attention before continuing'
    elseif session and session.status == 'done' then
      row.status, row.reviewed = 'review', session.reviewed == true
      row.reason = row.reviewed and 'Reviewed; ready to integrate' or 'Awaiting your review'
    elseif step.session_id and not session then
      row.status, row.reason = 'blocked', 'Assigned task session is unavailable'
    elseif session then
      row.status, row.reason = 'blocked', 'Continue the assigned task in its existing worktree'
    elseif #unmet > 0 then
      row.status, row.reason = 'pending', 'Waiting for integration: ' .. table.concat(unmet, ', ')
    else
      row.status, row.reason, row.ready = 'ready', 'Ready to dispatch', true
    end
    row.unmet_dependencies = unmet
    rows[#rows + 1] = row
  end
  return rows
end

return M

-- One conversation owns planning and sequential implementation. Provider process
-- control remains in init.lua; this module never creates sessions or worktrees.
local M = {}
local dossier = require('kiln.dossier')
local config, state

local function busy(session) return session.job or session.native_job or session.operation end
local function update()
  if config.refresh then config.refresh() end
  if config.persist then config.persist() end
end
local function tell(message) if config.notify then config.notify(message) end end
local function dirty(session)
  if config.dirty then return config.dirty(session) end
  return false
end
local function item(plan, id)
  for index, step in ipairs(plan and plan.steps or {}) do
    if step.id == id then return step, index end
  end
end
local function archive(workflow, id, record, reason)
  if not record then return end
  workflow.history[#workflow.history + 1] = {
    id = id, revision = workflow.revision, reason = reason, record = vim.deepcopy(record),
  }
end
local function definition(plan, step)
  return { title = step.title, instructions = step.instructions, verify = step.verify,
    brief = plan.brief, fingerprint = step.fingerprint }
end

function M.setup(options)
  config, state = options, assert(options.state, 'workflow state is required')
end

function M.init(session, restored)
  if type(session.workflow) ~= 'table' then
    session.workflow = { phase = 'planning', steps = {}, revision = 0, epoch = 0, history = {}, auto_run = false }
  end
  local flow = session.workflow
  flow.steps, flow.history = flow.steps or {}, flow.history or {}
  flow.revision, flow.epoch = tonumber(flow.revision) or 0, tonumber(flow.epoch) or 0
  if restored then
    flow.epoch, flow.auto_run, flow.turn = flow.epoch + 1, false, nil
    if flow.phase == 'running' then
      flow.phase, flow.reason = 'paused', 'Session restored. Resume when you are ready.'
      if flow.current and flow.steps[flow.current] and flow.steps[flow.current].status == 'running' then
        flow.steps[flow.current].status = 'paused'
      end
    end
  end
  return flow
end

function M.pause(session, reason)
  local flow = M.init(session)
  flow.epoch, flow.auto_run = flow.epoch + 1, false
  flow.phase, flow.reason = 'paused', reason or 'Paused by you.'
  local current = flow.current and flow.steps[flow.current]
  if current and current.status == 'running' then current.status, current.reason = 'paused', flow.reason end
  if busy(session) and config.stop then config.stop(session) end
  update()
end

function M.plan(session)
  M.pause(session, 'Planning in this conversation.')
  local flow = session.workflow
  flow.phase, flow.approved, flow.current, flow.turn, flow.proposal = 'planning', false, nil, nil, nil
  session.mode = 'plan'
  update()
  if config.focus_prompt then config.focus_prompt() end
end

-- Called before the owner replaces state.dossier. Editing an implemented or
-- active definition invalidates its progress and later outcomes, retaining an
-- audit of the old definition rather than calling stale work complete.
function M.accept(session, plan, previous)
  local flow = M.init(session)
  local was_planning = flow.phase == 'planning'
  if not plan or type(plan.steps) ~= 'table' or #plan.steps == 0 then return false, 'The dossier needs at least one step.' end
  local earliest
  if previous and (previous.brief ~= plan.brief or previous.title ~= plan.title) then earliest = 1 end
  for index, step in ipairs(plan.steps) do
    local old = previous and previous.steps[index]
    if previous and (not old or old.id ~= step.id or old.fingerprint ~= step.fingerprint) then
      earliest = math.min(earliest or index, index)
    end
  end
  if previous and #previous.steps > #plan.steps then earliest = math.min(earliest or (#plan.steps + 1), #plan.steps + 1) end
  local changed = not previous or previous.fingerprint ~= plan.fingerprint
  if previous and not earliest and changed then earliest = 1 end
  if earliest then M.pause(session, 'Dossier changed. Review the revised steps, then resume.') end
  if changed then flow.revision = flow.revision + 1 end
  local retained = {}
  for index, step in ipairs(plan.steps) do
    local old = flow.steps[step.id]
    if old and (not earliest or index < earliest) and old.fingerprint == step.fingerprint then
      retained[step.id] = old
    else
      if old then archive(flow, step.id, old, 'Dossier revision') end
      retained[step.id] = { status = 'pending', fingerprint = step.fingerprint, definition = definition(plan, step) }
    end
  end
  for id, old in pairs(flow.steps) do
    if not retained[id] then archive(flow, id, old, 'Removed from dossier') end
  end
  flow.steps = retained
  if flow.current and not retained[flow.current] then flow.current = nil end
  if not previous or was_planning then
    flow.phase, flow.reason, flow.auto_run = 'ready', 'Plan ready. Run it when you are ready.', false
  elseif earliest then
    flow.current = nil
    for _, step in ipairs(plan.steps) do
      if retained[step.id].status ~= 'done' then flow.current = step.id; break end
    end
  end
  update()
  return true
end

local function last_assistant(session, after)
  for index = #(session.events or {}), (after or 0) + 1, -1 do
    local event = session.events[index]
    if event.type == 'message' and event.role == 'assistant' then return event.text or '' end
  end
end

local function proposal(text)
  if type(text) ~= 'string' then return nil end
  local candidates, fence, body = {}, nil, {}
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    if not fence then
      local marker, language = line:match('^%s*(```+)%s*([%w_-]*)%s*$')
      if marker then fence, body = { marker = marker, keep = language == 'dossier' or language == 'markdown' }, {} end
    elseif line:match('^%s*' .. fence.marker .. '`*%s*$') then
      if fence.keep then candidates[#candidates + 1] = table.concat(body, '\n') end
      fence, body = nil, {}
    else body[#body + 1] = line end
  end
  if vim.trim(text):sub(1, 2) == '# ' then candidates[#candidates + 1] = vim.trim(text) end
  for index = #candidates, 1, -1 do
    if dossier.parse(candidates[index]) then return candidates[index] end
  end
end

local function completion(text, id)
  if type(text) ~= 'string' then return false end
  local fenced, last, visible = false, nil, false
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    if vim.trim(line) ~= '' then last, visible = vim.trim(line), not fenced end
    if line:match('^%s*```') or line:match('^%s*~~~') then fenced, visible = not fenced, false end
  end
  return visible and last == '<kiln_step_complete id="' .. id .. '"/>'
end

local planning_instructions = table.concat({
  'Continue this single planning conversation. Inspect the repository in read-only mode; do not edit files yet.',
  'Help the user turn their desired change into a specific, justified implementation dossier.',
  'Ask concise questions when a missing decision matters. Discuss tradeoffs and revise the plan in this chat.',
  'Use the smallest useful set of reviewable outcomes. Never add steps just for opening files, routine commands, or ceremony.',
  'Order the steps for sequential implementation. A dependency may refer only to an earlier step, and needs a concrete reason.',
  'Once the plan is coherent, explain it briefly and include its complete Markdown in one fenced ```dossier block.',
  'Use this format inside that block:',
  '# Descriptive title', 'Goal: desired result', 'Approach: repository-specific approach',
  'Why this approach: concrete reason', 'Constraints: relevant constraints', '',
  '## Step stable-id: Observable outcome', 'Outcome: exact behavior', 'Why: why this outcome is needed',
  'Verify: observable checks for this outcome', 'Depends: none',
  'For a dependency use Depends: earlier-id and Dependency reason: concrete prerequisite.',
  'Repeat only for justified outcomes. This one conversation and provider will implement every step.',
  'A dossier proposal does not start implementation. Do not claim files changed or checks passed in planning mode.',
}, '\n')

local function step_prompt(session, step, instruction)
  local plan, flow = state.dossier, session.workflow
  local _, index = item(plan, step.id)
  return table.concat({
    'Implement the current step of our agreed dossier in this same conversation and workspace.',
    'Explain the meaningful change before each edit and identify the file. Keep explanations concise and concrete.',
    'The user can interrupt and edit at any time. Re-read saved editor handoffs and preserve unrelated human changes.',
    'Work only on this step. Run its specified checks and report their actual results. Do not invent passing verification.',
    'If a decision, permission, failing check, or missing information blocks completion, explain it and stop without a completion marker.',
    'When this step is implemented and its specified checks succeed, end your final response with this exact standalone line:',
    '<kiln_step_complete id="' .. step.id .. '"/>',
    'That marker reports implementation completion, not human review or integration. Do not commit, merge, push, or deploy.',
    'Kiln will send the next step separately. Do not start later steps in this turn.', '',
    'DOSSIER: ' .. plan.title, plan.brief or '', '',
    'CURRENT STEP ' .. index .. '/' .. #plan.steps .. ' (revision ' .. flow.revision .. '): ' .. step.id .. ' — ' .. step.title,
    step.instructions or '', '', instruction or '',
  }, '\n')
end

-- Called exactly once immediately before launching an actual provider turn.
-- The boundary excludes old completion markers and earlier dossier proposals.
function M.prepare(session, prompt, meta)
  local flow = M.init(session)
  local actual, step = prompt, item(state.dossier, flow.current)
  if (flow.phase == 'paused' or flow.phase == 'running') and step
    and flow.steps[step.id] and flow.steps[step.id].status == 'done' then
    step = nil
    for _, candidate in ipairs(state.dossier.steps) do
      if not flow.steps[candidate.id] or flow.steps[candidate.id].status ~= 'done' then step = candidate; break end
    end
    flow.current = step and step.id or nil
  end
  if meta and meta.workflow_internal then
    session.mode = 'edit'
  elseif (flow.phase == 'paused' or flow.phase == 'running') and step then
    flow.phase, flow.reason, flow.auto_run = 'running', nil, flow.approved == true
    flow.steps[step.id].status, flow.steps[step.id].reason = 'running', nil
    flow.steps[step.id].pinned_definition = definition(state.dossier, step)
    session.mode = 'edit'
    actual = step_prompt(session, step, 'USER DIRECTION:\n' .. prompt)
  else
    flow.epoch, flow.auto_run, flow.phase, flow.current = flow.epoch + 1, false, 'planning', nil
    session.mode = 'plan'
    local current = state.dossier_text and ('\nCURRENT DOSSIER:\n' .. state.dossier_text) or ''
    actual = planning_instructions .. current .. '\n\nUSER MESSAGE:\n' .. prompt
  end
  flow.turn = { after = #(session.events or {}), epoch = flow.epoch, revision = flow.revision,
    mode = session.mode, step = session.mode == 'edit' and flow.current or nil,
    fingerprint = step and step.fingerprint or nil }
  update()
  return actual
end

local function validate_order(plan)
  local seen = {}
  for _, step in ipairs(plan.steps) do
    for _, dependency in ipairs(step.depends_on or {}) do
      if not seen[dependency] then return false, 'Place prerequisite ' .. dependency .. ' before ' .. step.id .. ' in the dossier.' end
    end
    seen[step.id] = true
  end
  return true
end

function M.run(session)
  local flow = M.init(session)
  if busy(session) then tell('Pause the current turn before resuming the dossier.'); return false end
  local unsafe, reason = dirty(session)
  if unsafe then M.pause(session, reason or 'Save your edits before resuming the dossier.'); return false end
  if flow.proposal then
    tell('A newer proposed dossier is waiting. Adopt it before running, or return to planning.')
    return false
  end
  local plan = state.dossier
  if not plan or state.dossier_invalid then tell(state.dossier_invalid or 'Plan the change in this chat first.'); return false end
  local valid, error = validate_order(plan)
  if not valid then M.pause(session, error); tell(error); return false end
  local step
  for _, candidate in ipairs(plan.steps) do
    flow.steps[candidate.id] = flow.steps[candidate.id] or { status = 'pending', fingerprint = candidate.fingerprint }
    if flow.steps[candidate.id].status ~= 'done' then step = candidate; break end
  end
  if not step then
    flow.phase, flow.current, flow.auto_run, flow.reason = 'review', nil, false, 'Implementation complete. Review the changes.'
    update(); return true
  end
  flow.epoch, flow.phase, flow.current = flow.epoch + 1, 'running', step.id
  flow.approved, flow.auto_run, flow.reason = true, true, nil
  flow.steps[step.id].status, flow.steps[step.id].reason = 'running', nil
  flow.steps[step.id].pinned_fingerprint = step.fingerprint
  flow.steps[step.id].pinned_definition = definition(plan, step)
  session.mode = 'edit'
  update()
  local sent = config.send(session, step_prompt(session, step), 'edit', { workflow_internal = true, step_id = step.id })
  if sent == false then M.pause(session, 'The step could not start. Resolve the reported problem, then resume.'); return false end
  return true
end

function M.adopt(session)
  local flow = M.init(session)
  if not flow.proposal then tell('There is no deferred dossier proposal to adopt.'); return false end
  if busy(session) then tell('Wait for the current turn before adopting its proposal.'); return false end
  local unsafe, reason = dirty(session)
  if unsafe then tell(reason or 'Save your edits before adopting the proposal.'); return false end
  if not config.load_plan(flow.proposal, session) then return false end
  flow.proposal = nil
  if config.show_plan then config.show_plan() end
  update()
  return true
end

function M.completed(session, ok)
  local flow = M.init(session)
  if busy(session) then return end
  local turn = flow.turn
  flow.turn = nil
  if not turn or turn.epoch ~= flow.epoch or turn.revision ~= flow.revision then return end
  local response = last_assistant(session, turn.after)
  if turn.mode == 'plan' then
    if not ok then flow.reason = 'Planning turn failed. Continue in this chat.'; update(); return end
    local text = proposal(response)
    if text then
      local unsafe, reason = dirty(session)
      if unsafe then
        flow.proposal, flow.reason = text, reason or 'Save your edits before applying the proposed dossier.'
        tell(flow.reason)
      elseif config.load_plan(text, session) then
        flow.proposal = nil
        if config.show_plan then config.show_plan() end
        tell('Dossier ready. Continue discussing it, edit its steps, or run it.')
      end
    end
    update(); return
  end
  local step = item(state.dossier, turn.step)
  if not step or step.fingerprint ~= turn.fingerprint then return end
  local record = flow.steps[step.id]
  if not ok then
    flow.phase, flow.auto_run, flow.reason = 'paused', false, 'The current step failed or was interrupted.'
    record.status, record.reason = 'blocked', flow.reason
    update(); return
  end
  if not completion(response, step.id) then
    flow.phase, flow.auto_run, flow.reason = 'paused', false, 'The agent has not reported this step complete. Continue in the chat.'
    record.status, record.reason = 'paused', flow.reason
    update(); return
  end
  record.status, record.reason, record.completed_revision = 'done', nil, flow.revision
  record.completion = 'agent-reported'
  archive(flow, step.id, record, 'Implementation reported complete')
  local next_step
  for _, candidate in ipairs(state.dossier.steps) do
    if flow.steps[candidate.id].status ~= 'done' then next_step = candidate; break end
  end
  if not next_step then
    flow.phase, flow.auto_run, flow.current, flow.reason = 'review', false, nil, 'Implementation complete. Review the changes.'
    update(); return
  end
  local unsafe, reason = dirty(session)
  if unsafe then M.pause(session, reason or 'Save your edits before continuing.'); return end
  update()
  if not flow.auto_run then return end
  local epoch = flow.epoch
  local schedule = config.schedule or function(callback) vim.defer_fn(callback, 250) end
  schedule(function()
    if state.closing or session.workflow ~= flow or flow.epoch ~= epoch or not flow.auto_run or flow.phase ~= 'running' then return end
    if busy(session) then return end
    M.run(session)
  end)
end

return M

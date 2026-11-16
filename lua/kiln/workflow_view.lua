-- Compact dossier checklist. Details are inspected on Enter; visible progress
-- comes from the actual workflow and observed file/check evidence.
local M = {}
local fn = vim.fn
local evidence = require('kiln.evidence')

local function clip(value, width)
  local text = tostring(value or ''):gsub('[\r\n\t]', ' '):gsub('%c', ''):gsub(' +', ' ')
  if fn.strdisplaywidth(text) <= width then return text end
  local count = fn.strchars(text)
  while count > 0 and fn.strdisplaywidth(fn.strcharpart(text, 0, count)) > width - 1 do count = count - 1 end
  return fn.strcharpart(text, 0, count) .. '…'
end
local statuses = {
  pending = { '○', 'Waiting', 'KilnMuted' }, running = { '›', 'Working', 'KilnRunning' },
  paused = { '|', 'Paused', 'KilnUser' }, done = { '✓', 'Implemented', 'KilnSuccess' },
  blocked = { '!', 'Needs attention', 'KilnError' },
}
local function runtime_status(workflow, step)
  local runtime = type(workflow.steps) == 'table' and workflow.steps[step.id] or nil
  runtime = type(runtime) == 'table' and runtime or {}
  local status = statuses[runtime.status] and runtime.status or 'pending'
  if workflow.current == step.id and workflow.phase == 'paused' and status == 'running' then status = 'paused' end
  return status, runtime
end
local function progress(session, step, status)
  local summary = evidence.summary(session, step.id)
  if summary.checks_failed > 0 then return summary.checks_failed .. ' check(s) failed', 'KilnError' end
  if status == 'blocked' then return 'Needs attention', 'KilnError' end
  if status == 'paused' then return 'Paused', 'KilnUser' end
  if summary.checks_running > 0 then return 'Running checks', 'KilnRunning' end
  if summary.checks_stale > 0 then return 'Checks need rerun', 'KilnUser' end
  if status == 'running' and summary.last_action then
    local action = evidence.action(session)
    return action, 'KilnMuted'
  end
  if summary.tests_passed > 0 then return summary.tests_passed .. ' tests passed', 'KilnSuccess' end
  if summary.checks_passed > 0 then return summary.checks_passed .. ' check(s) passed', 'KilnSuccess' end
  if #summary.files > 0 then return #summary.files .. ' file(s) changed', 'KilnMuted' end
  return statuses[status][2], statuses[status][3]
end
function M.steps(state, width, height)
  state = state or {}
  width = math.max(1, math.floor(tonumber(width) or 30))
  local view = { lines = {}, marks = {}, rows = {}, completed = 0, total = 0 }
  local function add(value, group, step, index, status)
    local text = clip(value, width)
    if group == 'KilnCurrent' then text = text .. string.rep(' ', math.max(0, width - fn.strdisplaywidth(text))) end
    view.lines[#view.lines + 1] = text
    local row = #view.lines
    if group then view.marks[#view.marks + 1] = { row = row, group = group } end
    if step then view.rows[row] = { id = step.id, index = index, status = status } end
    return row
  end
  local session = state.sessions and state.sessions[state.selected or 1] or {}
  local workflow = session.workflow or {}
  local plan = state.dossier
  if not plan or not plan.steps or #plan.steps == 0 then
    add('Plan in the chat', 'KilnTitle')
    add('Steps appear when ready.', 'KilnMuted')
    return view
  end
  view.total = #plan.steps
  local active, details
  for _, step in ipairs(plan.steps) do
    local status = runtime_status(workflow, step)
    if status == 'done' then view.completed = view.completed + 1 end
    if step.id == workflow.current then active = step end
    if step.id == state.workflow_focus then details = step end
  end
  if not details then
    details = active
    if not details then
      for _, step in ipairs(plan.steps) do
        if runtime_status(workflow, step) ~= 'done' then details = step; break end
      end
    end
    details = details or plan.steps[#plan.steps]
  end
  view.active_id, view.detail_id = active and active.id, details and details.id
  add(' ' .. plan.title, 'KilnTitle')
  add(string.format(' %d / %d implemented', view.completed, view.total), 'KilnMuted')
  add('')
  -- Every outcome stays in the scrollable buffer, including small terminals.
  for index, step in ipairs(plan.steps) do
    local status = runtime_status(workflow, step)
    local current = step == active
    local row = add(string.format(' %s %02d %s', statuses[status][1], index, step.title),
      current and 'KilnCurrent' or statuses[status][3], step, index, status)
    if current then view.active_row = row end
    local detail, group = progress(session, step, status)
    add('   ' .. detail, group, step, index, status)
  end
  add('')
  local primary = workflow.phase == 'review' and 'Review' or (workflow.phase == 'ready' and 'Start' or 'Resume')
  if session.stopping then primary = 'Stopping…'
  elseif session.job or session.native_job or session.operation then primary = 'Take over' end
  if workflow.phase == 'planning' then primary = 'Plan in chat' end
  if state.current_action and state.current_action.primary then primary = state.current_action.primary end
  if state.dossier_invalid then add(' Plan needs correction', 'KilnError') end
  if workflow.phase == 'review' then add(' Ready for review', 'KilnTitle') end
  add(' Space Enter  ' .. primary, 'KilnAccent')
  add(' Enter  Step details', 'KilnMuted')
  add(' Space ?  All commands', 'KilnMuted')
  return view
end
return M

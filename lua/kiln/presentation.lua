-- Truthful control ownership and one current action, derived from local state.
local M = {}
local function clean(text) return tostring(text or ''):gsub('%c', ' '):gsub('%s+', ' ') end
function M.clip(text, width)
  text = clean(text)
  if vim.fn.strdisplaywidth(text) <= width then return text end
  local count = vim.fn.strchars(text)
  while count > 0 and vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, count) .. '…') > width do count = count - 1 end
  return vim.fn.strcharpart(text, 0, count) .. '…'
end

function M.current(session, plan, options)
  options = options or {}
  local flow = session.workflow or {}
  local busy = session.job or session.native_job or session.operation
  local index
  for i, step in ipairs(plan and plan.steps or {}) do if step.id == flow.current then index = i end end
  local prefix = index and ('Step ' .. index .. '/' .. #plan.steps .. ' · ') or ''
  local view = { primary = 'Plan', control = 'PLANNING', group = 'KilnAccent' }
  if session.stopping and busy then
    view.control, view.primary, view.text = 'STOPPING', 'Wait', 'Waiting for the agent to stop before handing over'
  elseif busy then
    view.primary, view.control = 'Take over', session.resuming and 'RESUMING' or 'AGENT WORKING'
    local action = options.action
    if session.resuming then action = #(options.handoff or {}) > 0 and 'Resuming with your saved edits' or 'Resuming the plan'
    elseif not action or action == '' then action = 'Waiting for provider' end
    view.text = prefix .. session.provider .. ' · ' .. action
    view.group = 'KilnRunning'
  elseif options.human_control then
    view.control, view.group = 'YOU HAVE CONTROL', 'KilnUser'
    view.primary = plan and 'Resume' or 'Plan'
    if options.dirty then view.text = 'Save your code before resuming'
    elseif #(options.handoff or {}) > 0 then
      view.text = table.concat(options.handoff, ', ') .. ' saved · will be reread on resume'
    else view.text = 'Inspect or edit the code · resume when ready' end
  elseif flow.phase == 'review' then
    view.control, view.primary, view.group = 'READY FOR REVIEW', 'Review', 'KilnSuccess'
    view.text = options.review_summary or 'Implementation complete · inspect changes and checks'
  elseif flow.phase == 'ready' then
    view.control, view.primary = 'PLAN READY', 'Start'
    view.text = tostring(#(plan and plan.steps or {})) .. ' justified steps · edit the plan or start'
  elseif flow.phase == 'paused' then
    view.control, view.primary, view.group = 'PAUSED', plan and 'Resume' or 'Plan', 'KilnUser'
    view.text = flow.reason or 'Continue in the chat or resume the plan'
  elseif flow.phase == 'running' then
    view.control, view.primary, view.text = 'CONTINUING', 'Pause', 'Preparing the next step'
  else view.text = 'Discuss the change · agree on a plan before implementation' end
  if options.pinned and busy then view.text = view.text .. ' · code pinned' end
  view.text = clean(view.text)
  return view
end

function M.bar(view, width)
  local right = view.primary == 'Wait' and 'Stopping…' or ('Space Enter ' .. view.primary)
  local left = view.control .. ' · ' .. view.text
  return M.clip(left, math.max(8, width - vim.fn.strdisplaywidth(right) - 5)), right
end
return M

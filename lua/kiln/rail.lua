-- A compact, persistent dossier beside the editor. Every status comes from
-- actual task state; selecting an outcome never starts or advances its work.
local M = {}
local fn = vim.fn
local dossier = require('kiln.dossier')

local function clean(value)
  return tostring(value or ''):gsub('[\r\n\t]', ' '):gsub('%c', ''):gsub(' +', ' ')
end

local function clip(value, width)
  local text = clean(value)
  if fn.strdisplaywidth(text) <= width then return text end
  if width < 1 then return '' end
  local chars = fn.strchars(text)
  while chars > 0 and fn.strdisplaywidth(fn.strcharpart(text, 0, chars)) > width - 1 do chars = chars - 1 end
  return fn.strcharpart(text, 0, chars) .. '…'
end

local function wrapped(value, width, limit)
  local result, line = {}, ''
  for word in clean(value):gmatch('%S+') do
    local candidate = line == '' and word or (line .. ' ' .. word)
    if fn.strdisplaywidth(candidate) > width and line ~= '' then
      result[#result + 1], line = line, word
    else line = candidate end
  end
  if line ~= '' then result[#result + 1] = line end
  if #result == 0 then result[1] = '' end
  if #result > limit then
    local rest = {}
    for index = limit, #result do rest[#rest + 1] = result[index] end
    result[limit] = table.concat(rest, ' ')
    while #result > limit do table.remove(result) end
  end
  for index, text in ipairs(result) do result[index] = clip(text, width) end
  return result
end

local function status(item)
  local task = item.session
  if item.status == 'integrated' then return 'DONE', 'KilnSuccess' end
  if item.status == 'running' then
    if task.stopping then return 'STOPPING', 'KilnRunning' end
    if task.work_status == 'creating' then return 'PREPARING', 'KilnRunning' end
    if task.work_status == 'integrating' then return 'INTEGRATING', 'KilnRunning' end
    if task.operation then return 'CHECKING', 'KilnRunning' end
    if task.mode == 'plan' then return 'PLANNING', 'KilnRunning' end
    return 'IMPLEMENTING', 'KilnRunning'
  end
  if task and task.human_control then return 'YOU EDIT', 'KilnUser' end
  if item.status == 'review' then return item.reviewed and 'REVIEWED' or 'REVIEW', 'KilnTitle' end
  if item.status == 'ready' then return 'READY', 'KilnAccent' end
  if item.status == 'pending' then return 'WAITING', 'KilnMuted' end
  return 'ATTENTION', 'KilnError'
end

local function current_file(state, task)
  if not task then return nil end
  local root = task.workspace and task.workspace.root or state.root
  local ctx = state.contexts and state.contexts[root] or {}
  local activity = ctx.file_activity or task.file_activity or {}
  local path
  local human = ctx.human or task.human
  if task.human_control and human and human.path then path = human.path
  elseif ctx.pending_follow then path = ctx.pending_follow
  elseif ctx.last_file then path = ctx.last_file
  else
    local newest = -math.huge
    for file, event in pairs(activity) do
      if type(file) == 'string' and type(event) == 'table' and type(event.at) == 'number'
          and (event.at > newest or (event.at == newest and (not path or file < path))) then
        path, newest = file, event.at
      end
    end
  end
  if not path or path == '' then return nil end
  local event = activity[path]
  if root and path:sub(1, #root + 1) == root .. '/' then path = path:sub(#root + 2) end
  event = event or activity[path] or (root and activity[root .. '/' .. path])
  local actor
  if task.human_control and human and human.path then actor = 'YOU'
  elseif type(event) == 'table' and event.actor == 'human' then actor = 'YOU'
  elseif type(event) == 'table' and event.actor == 'agent' and event.provider then actor = clean(event.provider):upper() end
  return path, actor
end

function M.render(state, width, height)
  width, height = math.max(1, tonumber(width) or 40), math.max(1, tonumber(height) or 22)
  local view = { lines = {}, marks = {}, rows = {} }
  local function add(text, group, item, path)
    local line = clip(text, width)
    if group == 'KilnCurrent' then line = line .. string.rep(' ', math.max(0, width - fn.strdisplaywidth(line))) end
    view.lines[#view.lines + 1] = line
    local row = #view.lines
    if group then view.marks[#view.marks + 1] = { row = row, group = group } end
    if item then view.rows[row] = { id = item.id, session = item.index, path = path, status = item.status } end
    return row
  end
  local plan = state.dossier
  if not plan then
    add('Your dossier stays beside the code.', 'KilnTitle')
    add('')
    add('Space L  write the outcome', 'KilnAccent')
    add('Space P  ask the agent to plan', 'KilnMuted')
    return view
  end
  local items = dossier.readiness(plan, state.sessions)
  local selected = state.sessions and state.sessions[state.selected or 1]
  local chosen
  for _, item in ipairs(items) do
    if state.dossier_focus and item.id == state.dossier_focus then chosen = item; break end
  end
  if not chosen and selected then
    for _, item in ipairs(items) do
      if item.session == selected then chosen = item; break end
    end
  end
  if not chosen then
    for _, item in ipairs(items) do if item.status ~= 'integrated' then chosen = item; break end end
  end
  chosen = chosen or items[#items]
  view.active_id = chosen and chosen.id
  local done = 0
  for _, item in ipairs(items) do if item.status == 'integrated' then done = done + 1 end end
  add(' ' .. clean(plan.title), 'KilnTitle')
  local goal = tostring(plan.brief or ''):match('^Goal:[ \t]*([^\n]+)') or tostring(plan.brief or ''):match('\nGoal:[ \t]*([^\n]+)')
  if goal then add(' ' .. goal, 'KilnMuted') end
  add(' ' .. done .. ' / ' .. #items .. ' integrated', done == #items and 'KilnSuccess' or 'KilnMuted')
  add('')
  for index, item in ipairs(items) do
    local is_current = item == chosen
    local label, group = status(item)
    local row = add((is_current and '> ' or '  ') .. index .. '  ' .. item.title,
      is_current and 'KilnCurrent' or (item.status == 'integrated' and 'KilnSuccess' or 'KilnMuted'), item)
    if is_current then view.active_row = row end
    local provider = item.session and item.session.provider or item.step.provider
    add('     ' .. label .. (provider and (' · ' .. clean(provider)) or ''),
      is_current and 'KilnCurrent' or group, item)
  end
  if chosen then
    add('')
    local task, step = chosen.session, chosen.step
    local provider = task and task.provider or step.provider
    local model = task and task.model or step.model
    add(' ' .. (provider and clean(provider):upper() or 'SELECTED PROVIDER')
      .. (model and model ~= '' and (' / ' .. clean(model)) or ' / default'), 'KilnAccent', chosen)
    local path, actor = current_file(state, task)
    if path then
      view.current_file, view.file_actor = path, actor
      add(' ' .. (actor and (actor .. ' · ') or 'FILE · ') .. path, 'KilnAccent', chosen, path)
    end
    local remaining = math.max(2, height - #view.lines - 2)
    local why_limit = math.max(1, math.min(2, math.floor(remaining / 2)))
    local verify_limit = math.max(1, math.min(3, remaining - why_limit))
    for _, text in ipairs(wrapped('Why: ' .. step.rationale, math.max(1, width - 1), why_limit)) do add(' ' .. text, 'KilnMuted', chosen) end
    for _, text in ipairs(wrapped('Verify: ' .. step.verify, math.max(1, width - 1), verify_limit)) do add(' ' .. text, 'KilnMuted', chosen) end
    if chosen.status == 'blocked' or chosen.status == 'pending' then add(' ' .. chosen.reason, 'KilnMuted', chosen) end
    if state.dossier_invalid then add(' ' .. state.dossier_invalid, 'KilnError') end
  end
  add('')
  add(' Enter inspect · Space N implement', 'KilnMuted')
  return view
end

return M

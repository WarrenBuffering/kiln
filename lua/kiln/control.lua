-- Mission-control views are derived from recorded state, never estimated progress.
local M = {}
local fn = vim.fn

local function one_line(value)
  return tostring(value or ''):gsub('[\r\n\t]', ' '):gsub('%c', ''):gsub(' +', ' ')
end

local function filename(value)
  return tostring(value or ''):gsub('\r', '\\r'):gsub('\n', '\\n'):gsub('\t', '\\t')
end

local function clip(value, width)
  local text = tostring(value or '')
  width = math.max(0, width)
  if fn.strdisplaywidth(text) <= width then return text end
  if width == 0 then return '' end
  local count = fn.strchars(text)
  while count > 0 and fn.strdisplaywidth(fn.strcharpart(text, 0, count)) > width - 1 do count = count - 1 end
  return fn.strcharpart(text, 0, count) .. '…'
end

local function workspace_root(state, session)
  return session and session.workspace and session.workspace.root or state.root or ''
end

local function relative(state, path, session)
  local root = session and workspace_root(state, session) or state.view_root or state.root or ''
  path = tostring(path or '')
  if root ~= '' and path:sub(1, #root + 1) == root .. '/' then return path:sub(#root + 2) end
  return path
end

local function live(session)
  return session.job or session.native_job
end

function M.role(session)
  if type(session.role) == 'string' and session.role ~= '' then return one_line(session.role):upper() end
  return session.mode == 'plan' and 'REVIEWER' or 'BUILDER'
end

function M.status(session)
  if live(session) then
    if session.stopping or session.status == 'stopping' then return 'STOPPING', 'KilnRunning' end
    if session.native_job then return 'NATIVE', 'KilnRunning' end
    return 'WORKING', 'KilnRunning'
  end
  if session.work_status == 'creating' then return 'PREPARING', 'KilnRunning' end
  if session.work_status == 'inspecting' then return 'CHECKING', 'KilnRunning' end
  if session.work_status == 'integrating' then return 'INTEGRATING', 'KilnRunning' end
  if session.work_status == 'missing' then return 'MISSING', 'KilnError' end
  if session.work_status == 'integrated' then return 'INTEGRATED', 'KilnSuccess' end
  if session.human_control then return 'HANDCODING', 'KilnUser' end
  if session.status == 'done' then
    if session.reviewed then return 'REVIEWED', 'KilnSuccess' end
    return 'REVIEW', 'KilnTitle'
  end
  if session.status == 'error' or session.status == 'blocked' then return 'ATTENTION', 'KilnError' end
  if session.status == 'running' or session.status == 'native' or session.status == 'stopping'
      or session.status == 'interrupted' then return 'INTERRUPTED', 'KilnError' end
  if session.status == 'stopped' then return 'STOPPED', 'KilnMuted' end
  if session.status == 'demo' then return 'DEMO', 'KilnMuted' end
  return 'READY', 'KilnMuted'
end

local function title(session)
  local value = session.task
  if not value or value == '' then value = session.title end
  if not value or value == '' or value == 'New session' then return 'Describe the next task in the prompt' end
  return one_line(value)
end

local function fleet(state)
  local result = { builders = {}, reviewers = {}, active = 0, review = 0, handcoding = 0, integrated = 0,
    owners = {}, collisions = 0 }
  for index, session in ipairs(state.sessions or {}) do
    if live(session) then
      result.active = result.active + 1
      local bucket = session.mode == 'plan' and result.reviewers or result.builders
      bucket[#bucket + 1] = { index = index, session = session }
      if session.mode ~= 'plan' then
        local root = workspace_root(state, session)
        result.owners[root] = result.owners[root] or {}
        table.insert(result.owners[root], { index = index, session = session })
      end
    end
    local status = M.status(session)
    if status == 'REVIEW' then result.review = result.review + 1 end
    if status == 'HANDCODING' then result.handcoding = result.handcoding + 1 end
    if status == 'INTEGRATED' then result.integrated = result.integrated + 1 end
  end
  for _, owners in pairs(result.owners) do if #owners > 1 then result.collisions = result.collisions + 1 end end
  return result
end

local function owner_text(team, state, session)
  local owners = team.owners[workspace_root(state, session)] or {}
  if #owners > 1 then return 'MULTIPLE · ' .. #owners .. ' builders', 'KilnError' end
  if #owners == 1 then
    local owner = owners[1]
    return '#' .. owner.index .. ' ' .. one_line(owner.session.provider):upper(), 'KilnAccent', owner.index
  end
  if session and session.human_control then return 'YOU · agents paused here', 'KilnUser' end
  return 'No agent writer', 'KilnMuted'
end

local function human_text(state, session)
  local human = session and session.human or state.human
  if type(human) ~= 'table' or not human.path or human.path == '' then return nil end
  local verb = human.saved and 'SAVED' or (human.active and 'EDITING' or 'VIEWING')
  return 'YOU ' .. verb .. '  ' .. filename(relative(state, human.path, session)),
    human.active and not human.saved and 'KilnUser' or 'KilnAccent'
end

local function changed_files(state, session)
  if session and type(session.changed_files) == 'table' then return session.changed_files end
  if state.changes and type(state.changes.list) == 'function' then return state.changes.list() end
  return state.changed_files or {}
end

local function activity_for(state, path, session)
  local activity = session and session.file_activity or state.file_activity or {}
  local root = session and workspace_root(state, session) or state.view_root or state.root or ''
  return activity[path] or activity[root .. '/' .. path]
end

local function actor_label(state, path, session)
  local activity = activity_for(state, path, session)
  if type(activity) ~= 'table' then return '' end
  if activity.actor == 'human' then return 'YOU' end
  if activity.actor == 'agent' and activity.provider then return one_line(activity.provider):upper() end
  return ''
end

local function touched_files(state, session)
  local out, seen = {}, {}
  local function add(path)
    if type(path) ~= 'string' or path == '' then return end
    path = relative(state, path, session)
    if not seen[path] then seen[path] = true; out[#out + 1] = path end
  end
  if type(session.changed_files) == 'table' then
    for _, file in ipairs(session.changed_files) do add(file.path) end
    table.sort(out)
    return out
  end
  for _, event in ipairs(session.events or {}) do if event.type == 'file' then add(event.path) end end
  -- Accept the optional persisted index as well as historical provider events.
  for key, value in pairs(session.files or {}) do
    if type(key) == 'string' then add(key)
    elseif type(value) == 'string' then add(value)
    elseif type(value) == 'table' then add(value.path) end
  end
  table.sort(out)
  return out
end

local function last_action(state, session)
  for index = #(session.events or {}), 1, -1 do
    local event = session.events[index]
    -- A newly submitted task must not inherit the last turn's warning/action.
    if event.type == 'message' and event.role == 'user' then break end
    if event.type == 'error' then return 'Needs your attention', 'KilnError' end
    if event.type == 'human' and event.path then
      return 'You saved ' .. filename(relative(state, event.path, session)), 'KilnUser'
    end
    if event.type == 'file' and event.path then
      return 'Updated ' .. filename(relative(state, event.path, session)), 'KilnAccent'
    end
    if event.type == 'tool' then
      local text = one_line(event.name or 'Tool')
      if event.path and event.path ~= '' then text = text .. ' · ' .. filename(relative(state, event.path, session)) end
      if event.status == 'error' then return text .. (event.blocked and ' · blocked' or ' · error'), 'KilnError' end
      return text .. ' · ' .. (event.status == 'running' and 'running' or one_line(event.status or 'reported')),
        event.status == 'running' and 'KilnRunning' or 'KilnTool'
    end
  end
  local text = live(session) and 'Waiting for provider activity' or
    (session.status == 'done' and 'Response ready for review' or 'Ready for your direction')
  return text, 'KilnMuted'
end

local function view(width)
  local out = { lines = {}, marks = {}, rows = {} }
  local function add(text, group, row)
    out.lines[#out.lines + 1] = clip(text, width)
    if group then out.marks[#out.marks + 1] = { row = #out.lines, group = group } end
    if row then out.rows[#out.lines] = row end
  end
  return out, add
end

local function file_line(state, file, width, session)
  local path = relative(state, file.path, session)
  local left = ' ' .. one_line(file.status or 'M') .. ' ' .. filename(path)
  local actor = actor_label(state, path, session)
  if actor == '' then return clip(left, width) end
  local room = math.max(1, width - fn.strdisplaywidth(actor) - 2)
  left = clip(left, room)
  return left .. string.rep(' ', math.max(1, width - fn.strdisplaywidth(left) - fn.strdisplaywidth(actor) - 1)) .. actor
end

local function workspace_label(session)
  if session.workspace then return one_line(session.workspace.branch or session.workspace.root) end
  if session.isolated then return 'New worktree · from committed HEAD' end
  return 'Shared project'
end

-- Width applies to terminal display cells, including non-ASCII task/file names.
-- rows can use the same Enter dispatch as the existing monitor and pickers.
function M.monitor(state)
  local width = math.max(20, tonumber(state.control_width) or 39)
  local out, add = view(width)
  local sessions = state.sessions or {}
  local index = math.max(1, math.min(state.selected or 1, #sessions))
  local session = sessions[index]
  if not session then
    add(' MISSION CONTROL', 'KilnTitle')
    add(' No agent task yet', 'KilnMuted')
    add(' Space n  create a task', 'KilnAccent')
    out.height = #out.lines
    return out
  end
  local task_row = { session = index }
  local team = fleet(state)
  local owner, owner_group, owner_index = owner_text(team, state, session)
  local status, status_group = M.status(session)
  add(' TASK ' .. index .. '/' .. #sessions .. '   Space g', 'KilnTitle', task_row)
  add(' ' .. title(session), 'KilnAccent', task_row)
  local provider = one_line(session.provider):upper()
  local model = session.model and session.model ~= '' and one_line(session.model) or 'default'
  add(' ' .. M.role(session) .. '  ' .. provider .. ' / ' .. model, 'KilnMuted', task_row)
  add(' ' .. status .. (status == 'REVIEW' and '  ·  Space v when reviewed' or
    ('  ·  follow ' .. (state.follow and 'on' or 'off'))), status_group, task_row)
  local reviewers = #team.reviewers > 0 and (' · ' .. #team.reviewers
    .. (#team.reviewers == 1 and ' reviewer' or ' reviewers')) or ''
  add(' OWNER ' .. owner .. reviewers, owner_group,
    owner_index and { session = owner_index } or nil)
  local isolated = session.workspace or session.isolated
  if isolated then add(' TREE ' .. workspace_label(session), 'KilnMuted', task_row) end
  local human, human_group = human_text(state, session)
  add(human and (' ' .. human) or (state.follow and ' LIVE  Agent file changes open here' or ' HOLD  You choose the file'),
    human_group or (state.follow and 'KilnAccent' or 'KilnUser'))
  local changed = changed_files(state, session)
  add(' CHANGES ' .. #changed .. '   Space d', 'KilnTitle')
  for i = 1, isolated and 2 or 3 do
    local file = changed[i]
    if file then
      add(file_line(state, file, width, session), actor_label(state, relative(state, file.path, session), session) == 'YOU' and 'KilnUser' or 'KilnMuted',
        { session = index, path = relative(state, file.path, session) })
    elseif i == 1 then add(' No working-tree changes', 'KilnMuted')
    else add('') end
  end
  local action, action_group = last_action(state, session)
  add(' LAST  ' .. action, action_group)
  add(isolated and ' Space h handcode · Space g team' or ' Space q task  ·  Space a direct', 'KilnMuted')
  out.height = #out.lines
  return out
end

function M.overview(state)
  local width = math.max(32, tonumber(state.overview_width) or 86)
  local out, add = view(width)
  local sessions = state.sessions or {}
  local team = fleet(state)
  local selected = sessions[state.selected or 1]
  local owner, owner_group, owner_index = owner_text(team, state, selected)
  add(' MISSION CONTROL', 'KilnTitle')
  add(' ' .. #sessions .. (#sessions == 1 and ' task' or ' tasks') .. '  ·  '
    .. #team.builders .. (#team.builders == 1 and ' builder' or ' builders') .. ' active  ·  '
    .. #team.reviewers .. (#team.reviewers == 1 and ' reviewer' or ' reviewers') .. ' active', 'KilnMuted')
  add(' REVIEW QUEUE ' .. team.review .. '  ·  HANDCODING ' .. team.handcoding .. '  ·  INTEGRATED ' .. team.integrated, 'KilnTitle')
  add(' EDIT OWNER  ' .. owner .. (selected and selected.workspace and '  ·  selected worktree' or ''), owner_group,
    owner_index and { session = owner_index } or nil)
  if team.collisions > 0 then add(' ATTENTION  Multiple writers share ' .. team.collisions .. ' workspace(s)', 'KilnError') end
  local human, human_group = human_text(state, selected)
  if human then add(' ' .. human, human_group) end
  add('')
  for index, session in ipairs(sessions) do
    local row = { session = index }
    local status, group = M.status(session)
    local marker = index == state.selected and ' > ' or '   '
    local model = session.model and session.model ~= '' and one_line(session.model) or 'default'
    add(marker .. string.format('%02d', index) .. '  ' .. status .. '  ·  ' .. M.role(session)
      .. '  ·  ' .. one_line(session.provider):upper() .. ' / ' .. model, group, row)
    add('      ' .. title(session), 'KilnAccent', row)
    if session.workspace or session.isolated then
      local base = session.workspace and session.workspace.base
      add('      TREE ' .. workspace_label(session) .. (base and '  ·  base ' .. tostring(base):sub(1, 8) or ''), 'KilnMuted', row)
    end
    local files = touched_files(state, session)
    if type(session.changed_files) == 'table' then
      add('      CHANGES ' .. #files .. '  ·  Space d review all', 'KilnTitle', row)
      for i = 1, math.min(3, #session.changed_files) do
        local file = session.changed_files[i]
        local path = relative(state, file.path, session)
        add('     ' .. file_line(state, file, width - 5, session),
          actor_label(state, path, session) == 'YOU' and 'KilnUser' or 'KilnMuted', { session = index, path = path })
      end
      if #files > 3 then add('      +' .. (#files - 3) .. ' more files', 'KilnMuted', row) end
    elseif #files > 0 then
      local names = {}
      for _, path in ipairs(files) do names[#names + 1] = filename(path) end
      add('      FILES ' .. #files .. '  ' .. table.concat(names, ' · '), 'KilnMuted', row)
    else add('      No file changes reported', 'KilnMuted', row) end
    local action, action_group = last_action(state, session)
    add('      LAST  ' .. action, action_group, row)
    add('')
  end
  if #sessions == 0 then add(' Describe a task in the prompt to begin.', 'KilnMuted'); add('') end
  add(' Enter task / file  ·  Space n new task  ·  Space q objective  ·  Space x stop', 'KilnTitle')
  add(' Space h handcode  ·  Space a direct  ·  Space d diff  ·  Space v reviewed  ·  Space i integrate', 'KilnMuted')
  add(' Space R add reviewer  ·  q close', 'KilnMuted')
  out.height = #out.lines
  return out
end

return M

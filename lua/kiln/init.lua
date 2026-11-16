local M = {}
local api, fn = vim.api, vim.fn
local uv = vim.uv or vim.loop
local S = { sessions = {}, selected = 1, buffers = {}, windows = {}, contexts = {}, follow = true, demo = false,
  human_version = 0, human_changes = {}, file_activity = {} }
local control = require('kiln.control')
local workspaces = require('kiln.workspaces')
local planning = require('kiln.planning')
local rail = require('kiln.rail')
local narration = require('kiln.narration')
local workflow = require('kiln.workflow')
local workflow_view = require('kiln.workflow_view')
local conversation = require('kiln.conversation')
local evidence = require('kiln.evidence')
local presentation = require('kiln.presentation')
M.state = S
local ns = api.nvim_create_namespace('kiln')
local render, persist, select_session, attach_context, activate_context, provision, refresh, dirty_buffers
local function valid_win(win) return win and api.nvim_win_is_valid(win) end
local function valid_buf(buf) return buf and api.nvim_buf_is_valid(buf) end
local function active() return S.sessions[S.selected] end
local function session_root(session) return session and session.workspace and session.workspace.root or S.root end
local function context(session) return S.contexts[session_root(session or active())] end
local function same_workspace(a, b) return session_root(a) == session_root(b) end
local function busy(session) return session.job or session.native_job or session.operation end
local function trim(s) return vim.trim(s or '') end
-- Keep byte budgets without splitting a UTF-8 code point.
local function continuation(byte) return byte and byte >= 128 and byte < 192 end
local function text_prefix(text, limit)
  if #text <= limit then return text end
  local boundary = limit + 1
  while boundary > 1 and continuation(text:byte(boundary)) do boundary = boundary - 1 end
  return text:sub(1, boundary - 1)
end
local function text_suffix(text, limit)
  if #text <= limit then return text end
  local boundary = #text - limit + 1
  while continuation(text:byte(boundary)) do boundary = boundary + 1 end
  return text:sub(boundary)
end
local function display(s) return tostring(s or ''):gsub('\r', '\\r'):gsub('\n', '\\n') end
local function lines(s) return vim.split(tostring(s or ''), '\n', { plain = true }) end
local function relative(path, root)
  root = root or S.view_root or S.root
  if type(path) ~= 'string' or path == '' then return nil end
  local full = path:sub(1, 1) == '/' and path or (root .. '/' .. path)
  local parent = uv.fs_realpath(fn.fnamemodify(full, ':h'))
  full = uv.fs_realpath(full) or ((parent or fn.fnamemodify(full, ':h')) .. '/' .. fn.fnamemodify(full, ':t'))
  if full:sub(1, #root + 1) == root .. '/' then return full:sub(#root + 2) end
end
local function owns_path(root, path)
  if not relative(path, root) then return false end
  for other in pairs(S.contexts) do
    if #other > #root and relative(path, other) then return false end
  end
  return true
end
local function notify(s, level) vim.notify(s, level or vim.log.levels.INFO, { title = 'Kiln' }) end
local function put(buf, content)
  if not valid_buf(buf) then return end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, #content > 0 and content or { '' })
  vim.bo[buf].modifiable = false
end
local function scratch(name, editable)
  local b = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(b, 'kiln://' .. name)
  vim.bo[b].bufhidden = 'hide'
  vim.bo[b].swapfile = false
  vim.bo[b].filetype = 'kiln'
  vim.bo[b].modifiable = editable or false
  return b
end
local function style(win, label)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].foldcolumn = '0'
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true
  vim.wo[win].cursorline = false
  vim.wo[win].winfixwidth = true
  vim.wo[win].winbar = '%#KilnTitle# ' .. label
  vim.wo[win].statusline = '%#KilnMuted#  Kiln  %=%l:%c '
end
local function add(session, event)
  if session.workflow then
    local turn = session.workflow.turn
    event.step_id = event.step_id or (turn and turn.step) or session.workflow.current
    event.step_fingerprint = event.step_fingerprint or (turn and turn.fingerprint)
    event.turn_id = event.turn_id or session.turn_id
    if event.type == 'file' and event.path then event.path = relative(event.path, session_root(session)) or event.path end
    evidence.observe(session, event, session_root(session))
  end
  if event.id then
    for i = #session.events, 1, -1 do
      if session.events[i].id == event.id and session.events[i].type == event.type then
        event.paths = event.paths or session.events[i].paths
        session.events[i] = event
        return
      end
    end
  end
  table.insert(session.events, event)
end
local function draft_save()
  if active() and valid_buf(S.buffers.prompt) then
    active().draft = table.concat(api.nvim_buf_get_lines(S.buffers.prompt, 0, -1, false), '\n')
  end
end
persist = function()
  if S.demo or not S.state_file then return end
  local saved = { version = 2, selected = S.selected, sessions = {}, contexts = {},
    dossier = S.dossier, dossier_text = S.dossier_text }
  for root, ctx in pairs(S.contexts) do
    saved.contexts[root] = { human_version = ctx.human_version, human_changes = ctx.human_changes,
      file_activity = ctx.file_activity, human = ctx.human, human_control = ctx.human_control, follow = ctx.follow }
  end
  for _, session in ipairs(S.sessions) do
    local item = {}
    for _, k in ipairs({ 'id', 'provider', 'model', 'mode', 'native_id', 'events', 'draft', 'status', 'title', 'handoff', 'usage',
      'task', 'reviewed', 'last_human_version', 'workspace', 'isolated', 'review_fingerprint', 'work_status',
      'dossier_step', 'dossier_planner', 'workflow', 'provider_sessions', 'evidence', 'reviewed_files' }) do
      item[k] = session[k]
    end
    saved.sessions[#saved.sessions + 1] = item
  end
  local ok, encoded = pcall(vim.json.encode, saved)
  if ok then
    if encoded == S.saved_json then return end
    local temp = S.state_file .. '.tmp'
    local wrote = pcall(fn.writefile, { encoded }, temp)
    if wrote then
      uv.fs_chmod(temp, 384)
      local renamed, err = uv.fs_rename(temp, S.state_file)
      if not renamed then notify('Cannot save sessions: ' .. tostring(err), vim.log.levels.ERROR)
      else S.saved_json = encoded end
    else notify('Cannot save Kiln sessions.', vim.log.levels.ERROR) end
  end
end
local pending = false
refresh = function()
  if pending or S.closing then return end
  pending = true
  vim.defer_fn(function()
    pending = false
    if S.closing then return end
    render()
    persist()
  end, 90)
end
local function new_session(provider, model, options)
  options = options or {}
  local session = { id = string.format('%.0f', uv.hrtime()), provider = provider or 'codex', model = model or '',
    mode = options.mode or 'edit', events = {}, status = 'idle', draft = '', title = 'New session',
    isolated = options.isolated or false, workspace = options.workspace }
  table.insert(S.sessions, session)
  return session
end
local function sync_context(ctx)
  if ctx.changes and ctx.changes.set_follow then ctx.changes.set_follow(ctx.follow) end
  for _, session in ipairs(S.sessions) do
    if session_root(session) == ctx.root then
      session.changed_files, session.file_activity = ctx.changed_files, ctx.file_activity
      session.human, session.human_control = ctx.human, ctx.human_control
    end
  end
  if context() == ctx then
    S.view_root, S.changes, S.follow = ctx.root, ctx.changes, ctx.follow
    S.human_version, S.human_changes, S.file_activity, S.human = ctx.human_version, ctx.human_changes, ctx.file_activity, ctx.human
    S.pending_follow = ctx.pending_follow
  end
end
local function invalidate_review(ctx)
  ctx.revision = (ctx.revision or 0) + 1
  for _, session in ipairs(S.sessions) do
    if session_root(session) == ctx.root then session.reviewed, session.review_fingerprint = false, nil end
  end
end
local function workspace_args(session)
  return { root = S.root, workspace = session.workspace.root, branch = session.workspace.branch, base = session.workspace.base }
end
attach_context = function(session)
  local root = session_root(session)
  if S.contexts[root] then sync_context(S.contexts[root]); return S.contexts[root] end
  local saved = S.saved_contexts and S.saved_contexts[root] or {}
  local ctx = { root = root, follow = saved.follow ~= false, human_version = tonumber(saved.human_version) or 0,
    human_changes = type(saved.human_changes) == 'table' and saved.human_changes or {},
    file_activity = type(saved.file_activity) == 'table' and saved.file_activity or {},
    human = saved.human, human_control = saved.human_control or false, changed_files = {}, revision = 0 }
  S.contexts[root] = ctx
  local changes_module = require('kiln.changes')
  ctx.changes = changes_module.new()
  ctx.changes.setup({ root = root, base = session.workspace and session.workspace.base,
    owns_path = function(path) return owns_path(root, path) end,
    on_update = function(changes)
      ctx.changed_files = changes
      sync_context(ctx)
      if context() == ctx and ctx.follow and ctx.pending_follow then
        for _, change in ipairs(changes) do
          if change.path == ctx.pending_follow then
            ctx.pending_follow = nil
            if active() and (active().dossier_step or active().workflow) then ctx.changes.show_live(change.path, S.windows.code)
            else ctx.changes.show_diff(change.path, S.windows.code) end
            break
          end
        end
      end
      -- Review is a snapshot, not a permanent blessing of a mutable branch.
      if not ctx.checking_review and uv.hrtime() / 1e9 > (ctx.next_review_check or 0) then
        for _, task in ipairs(S.sessions) do
          if session_root(task) == root and task.workspace and task.reviewed and task.review_fingerprint then
            ctx.checking_review, ctx.next_review_check = true, uv.hrtime() / 1e9 + 3
            local expected = task.review_fingerprint
            workspaces.run('inspect', workspace_args(task), function(result)
              ctx.checking_review = false
              if S.closing then return end
              if task.reviewed and task.review_fingerprint == expected and (not result.ok or result.fingerprint ~= expected) then
                invalidate_review(ctx); refresh()
              end
            end)
            break
          end
        end
      end
      refresh()
    end,
    on_conflict = function(path, reason)
      local text = reason == 'deleted' and ('File was deleted on disk: ' .. path .. '. Editor content was preserved.')
        or ('Disk changed while you have unsaved edits: ' .. path .. '. Resolve this buffer before writing.')
      for _, task in ipairs(S.sessions) do
        if session_root(task) == root then add(task, { type = 'error', id = 'conflict:' .. path, text = text }) end
      end
      refresh()
    end,
    on_error = function(message)
      if context() == ctx then notify(message, vim.log.levels.WARN) end
    end })
  sync_context(ctx)
  return ctx
end
activate_context = function(session)
  local ctx = attach_context(session)
  local previous = S.current_context
  if previous ~= ctx then
    local previous_path
    if not previous and ctx.root ~= S.root and valid_win(S.windows.code) then
      previous_path = relative(api.nvim_buf_get_name(api.nvim_win_get_buf(S.windows.code)), S.root)
    end
    if previous and valid_win(S.windows.code) then
      previous.changes.close_diff()
      local buf = api.nvim_win_get_buf(S.windows.code)
      previous_path = relative(api.nvim_buf_get_name(buf), previous.root)
      if previous_path then previous.code_buf, previous.cursor = buf, api.nvim_win_get_cursor(S.windows.code) end
    end
    S.current_context = ctx
    if (previous or ctx.root ~= S.root) and valid_win(S.windows.code) then
      local buf = valid_buf(ctx.code_buf) and ctx.code_buf or nil
      if not buf then
        local path = previous_path and (ctx.root .. '/' .. previous_path) or (ctx.root .. '/README.md')
        if fn.filereadable(path) == 1 then buf = fn.bufadd(path); fn.bufload(buf)
        else buf = api.nvim_create_buf(true, false) end
      end
      api.nvim_win_set_buf(S.windows.code, buf)
      if ctx.cursor then pcall(api.nvim_win_set_cursor, S.windows.code, ctx.cursor) end
    end
    if uv.fs_stat(ctx.root) then api.nvim_set_current_dir(ctx.root) end
  end
  sync_context(ctx)
  if valid_win(S.windows.code) and not ctx.changes.is_diff_open() then
    local branch = session.workspace and session.workspace.branch or (session.isolated and 'NEW TASK · waiting for worktree' or 'MAIN CHECKOUT')
    vim.wo[S.windows.code].winbar = '%#KilnTitle# ' .. branch:gsub('%%', '%%%%')
  end
end
provision = function(session, callback)
  if not session.isolated or session.workspace then callback(); return end
  if session.operation then return end
  if S.demo then notify('Worktrees are disabled in the offline demo.'); return end
  session.work_status = 'creating'
  session.operation = workspaces.run('create', { root = S.root, storage = S.storage .. '/worktrees', id = session.id }, function(result)
    session.operation = nil
    if not result.ok then
      session.work_status = 'missing'
      add(session, { type = 'error', text = result.error })
      refresh(); return
    end
    session.workspace = { root = result.root, branch = result.branch, base = result.base, repo_root = result.repo_root }
    session.work_status = nil
    add(session, { type = 'notice', text = 'Isolated task: ' .. result.branch .. '\n' .. result.root
      .. '\nStarts from committed HEAD ' .. result.base:sub(1, 10)
      .. (result.source_dirty and '. Uncommitted changes in the main checkout were not copied.' or '.') })
    if S.closing then persist(); return end
    attach_context(session)
    if active() == session then activate_context(session) end
    render(); persist(); callback()
  end)
  refresh()
end
local function pane_width()
  return math.min(math.max(24, math.floor(vim.o.columns * 0.25)), math.max(24, vim.o.columns - 30))
end
local function dossier_sidebar()
  return S.dossier_editing or (S.dossier and S.sidebar_mode ~= 'task')
end
local function resize()
  if active() and active().workflow then
    if valid_win(S.windows.transcript) then
      api.nvim_win_set_width(S.windows.transcript, math.max(24, math.min(52, math.floor(vim.o.columns * 0.29))))
      pcall(api.nvim_win_set_height, S.windows.prompt, math.max(4, math.min(9, math.floor(vim.o.lines * 0.19))))
    end
    if valid_win(S.windows.steps) then
      api.nvim_win_set_width(S.windows.steps, math.max(18, math.min(30, math.floor(vim.o.columns * 0.18))))
    end
    return
  end
  if valid_win(S.windows.monitor) then
    api.nvim_win_set_width(S.windows.monitor, pane_width())
    local height = dossier_sidebar() and math.max(6, math.floor(vim.o.lines * 0.55))
      or math.min(13, math.max(5, math.floor(vim.o.lines * 0.31)))
    pcall(api.nvim_win_set_height, S.windows.monitor, height)
    pcall(api.nvim_win_set_height, S.windows.prompt, math.min(8, math.max(3, math.floor(vim.o.lines * 0.18))))
  end
end
local function layout()
  local kind = active() and active().workflow and 'workflow' or 'tasks'
  local current = api.nvim_get_current_win()
  if not valid_win(S.windows.code) then S.windows.code = current end
  if S.layout_kind and S.layout_kind ~= kind then
    local seen = {}
    for _, name in ipairs({ 'monitor', 'steps', 'transcript', 'prompt' }) do
      local win = S.windows[name]
      if valid_win(win) and win ~= S.windows.code and not seen[win] then
        seen[win] = true; api.nvim_win_close(win, true)
      end
      S.windows[name] = nil
    end
  end
  S.layout_kind = kind
  if kind == 'workflow' then
    if not valid_win(S.windows.transcript) or not valid_win(S.windows.prompt) then
      api.nvim_set_current_win(S.windows.code)
      vim.cmd('botright vsplit')
      S.windows.transcript = api.nvim_get_current_win()
      api.nvim_win_set_buf(S.windows.transcript, S.buffers.transcript)
      vim.cmd('belowright split')
      S.windows.prompt = api.nvim_get_current_win()
      api.nvim_win_set_buf(S.windows.prompt, S.buffers.prompt)
      style(S.windows.transcript, 'CHAT / PLAN TO IMPLEMENTATION')
      style(S.windows.prompt, 'MESSAGE / Ctrl-s send')
    end
    if (S.dossier or S.dossier_editing) and not valid_win(S.windows.steps) then
      api.nvim_set_current_win(S.windows.code)
      vim.cmd('topleft vsplit')
      S.windows.steps = api.nvim_get_current_win()
      api.nvim_win_set_buf(S.windows.steps, S.buffers.steps)
      style(S.windows.steps, 'DOSSIER / STEPS')
      vim.wo[S.windows.steps].wrap = false
    end
    resize()
    api.nvim_set_current_win(valid_win(current) and current or S.windows.code)
    return
  end
  if valid_win(S.windows.transcript) and valid_win(S.windows.prompt) and valid_win(S.windows.monitor) then return end
  api.nvim_set_current_win(S.windows.code)
  vim.cmd('botright vsplit')
  S.windows.monitor = api.nvim_get_current_win()
  api.nvim_win_set_buf(S.windows.monitor, S.buffers.monitor)
  vim.cmd('belowright split')
  S.windows.transcript = api.nvim_get_current_win()
  api.nvim_win_set_buf(S.windows.transcript, S.buffers.transcript)
  vim.cmd('belowright split')
  S.windows.prompt = api.nvim_get_current_win()
  api.nvim_win_set_buf(S.windows.prompt, S.buffers.prompt)
  style(S.windows.monitor, 'K I L N   /   MISSION CONTROL')
  style(S.windows.transcript, 'ACTIVITY')
  style(S.windows.prompt, 'PROMPT   /   ^S send')
  resize()
  api.nvim_set_current_win(valid_win(current) and current or S.windows.code)
end
local function highlight(buf, row, group)
  api.nvim_buf_add_highlight(buf, ns, group, row - 1, 0, -1)
end
render = function()
  if not active() or not valid_buf(S.buffers.transcript) then return end
  planning.refresh()
  local a = active()
  layout()
  if a.workflow then
    local ctx, handoff = context(a), {}
    for path, change in pairs(ctx.human_changes or {}) do
      if change.version > (a.last_human_version or 0) then handoff[#handoff + 1] = path end
    end
    table.sort(handoff)
    S.current_action = presentation.current(a, S.dossier, {
      human_control = ctx.human_control, dirty = dirty_buffers and dirty_buffers(ctx.root),
      handoff = handoff, action = evidence.action(a, S.dossier), pinned = not ctx.follow,
    })
    if a.workflow.phase == 'review' and not busy(a) and not ctx.human_control then
      local review = evidence.review(a, S.dossier)
      S.current_action.text = string.format('%d files changed · %d tests passed · %d unresolved',
        #review.files, review.tests_passed, #review.unresolved)
    end
    local left, right = presentation.bar(S.current_action, vim.o.columns)
    vim.o.laststatus = 3
    vim.o.statusline = '%#' .. S.current_action.group .. '# ' .. left:gsub('%%', '%%%%')
      .. '%=%#KilnTitle# ' .. right:gsub('%%', '%%%%') .. ' '
    for _, win in pairs(S.windows) do if valid_win(win) then vim.wo[win].statusline = '' end end
  elseif S.current_action then
    S.current_action = nil
    vim.o.laststatus = 2
  end
  local step_id = a.workflow and a.workflow.current or a.dossier_step
  if step_id and S.dossier and valid_win(S.windows.code) and not S.changes.is_diff_open() then
    local buf = api.nvim_win_get_buf(S.windows.code)
    local file = relative(api.nvim_buf_get_name(buf)) or (vim.bo[buf].buftype == 'terminal' and 'checks' or 'code')
    for index, step in ipairs(S.dossier.steps) do
      if step.id == step_id then
        local owner = a.workflow and a.workflow.phase:upper() or (a.work_status == 'integrated' and 'INTEGRATED'
          or (a.human_control and 'YOU EDIT' or (S.follow and 'FOLLOW' or 'PAUSED'))
        )
        local label = string.format(' %02d  %s  /  %s   %s', index, step.title, display(file), owner)
        vim.wo[S.windows.code].winbar = '%#KilnTitle#' .. label:gsub('%%', '%%%%')
        break
      end
    end
  elseif a.workflow and valid_win(S.windows.code) and not S.changes.is_diff_open() then
    local file = relative(api.nvim_buf_get_name(api.nvim_win_get_buf(S.windows.code))) or 'code'
    vim.wo[S.windows.code].winbar = '%#KilnTitle# ' .. display(file):gsub('%%', '%%%%') .. ' / '
      .. (a.workflow.phase == 'review' and 'READY FOR REVIEW' or a.workflow.phase:upper())
  end
  if a.workflow and valid_win(S.windows.code) and not S.changes.is_diff_open() then
    local file = relative(api.nvim_buf_get_name(api.nvim_win_get_buf(S.windows.code))) or 'code'
    vim.wo[S.windows.code].winbar = '%#KilnTitle# ' .. display(file):gsub('%%', '%%%%')
      .. '%#KilnMuted#  · ' .. (S.follow and 'following changes' or 'view pinned')
  end
  if a.workflow then
    local win = S.windows.steps
    if valid_win(win) and not S.dossier_editing then
      local view = workflow_view.steps(S, api.nvim_win_get_width(win), api.nvim_win_get_height(win) - 1)
      local cursor = api.nvim_win_get_cursor(win)
      put(S.buffers.steps, view.lines)
      api.nvim_buf_clear_namespace(S.buffers.steps, ns, 0, -1)
      for _, mark in ipairs(view.marks) do highlight(S.buffers.steps, mark.row, mark.group) end
      S.workflow_rows = view.rows
      local row = math.min(cursor[1], #view.lines)
      if S.workflow_active_id ~= view.active_id and api.nvim_get_current_win() ~= win then row = view.active_row or row end
      api.nvim_win_set_cursor(win, { math.max(1, row), 0 })
      S.workflow_active_id = view.active_id
      vim.wo[win].winbar = '%#KilnTitle# PLAN'
    end
  else
  S.control_width = valid_win(S.windows.monitor) and api.nvim_win_get_width(S.windows.monitor) or pane_width()
  local panel = dossier_sidebar() and 'dossier' or 'task'
  if S.panel_layout ~= panel then resize(); S.panel_layout = panel end
  local monitor = panel == 'dossier' and S.dossier and rail.render(S, S.control_width,
    api.nvim_win_get_height(S.windows.monitor) - 1) or control.monitor(S)
  local monitor_cursor = api.nvim_win_get_cursor(S.windows.monitor)
  S.monitor_rows = monitor.rows
  put(S.buffers.monitor, monitor.lines)
  api.nvim_buf_clear_namespace(S.buffers.monitor, ns, 0, -1)
  for _, mark in ipairs(monitor.marks) do highlight(S.buffers.monitor, mark.row, mark.group) end
  if not S.dossier_editing and valid_win(S.windows.monitor) then
    local win = S.windows.monitor
    api.nvim_win_set_cursor(win, { math.min(monitor_cursor[1], #monitor.lines), 0 })
    vim.wo[win].wrap = false
    vim.wo[win].winbar = panel == 'dossier'
      and '%#KilnTitle# DOSSIER%#KilnMuted#  /  task · Tab'
      or '%#KilnMuted# dossier%#KilnTitle#  /  TASK%#KilnMuted# · Tab'
    if monitor.active_id ~= S.rail_active_id and api.nvim_get_current_win() ~= win and monitor.active_row then
      api.nvim_win_set_cursor(win, { monitor.active_row, 0 })
      api.nvim_win_call(win, function() vim.cmd('normal! zz') end)
    end
    S.rail_active_id = monitor.active_id
    S.rail_active_row = monitor.active_row
  end
  end
  if S.overview and valid_win(S.overview.win) and valid_buf(S.overview.buf) then
    local board = control.overview(S)
    local cursor = api.nvim_win_get_cursor(S.overview.win)
    S.overview.rows = board.rows
    put(S.overview.buf, board.lines)
    api.nvim_buf_clear_namespace(S.overview.buf, ns, 0, -1)
    for _, mark in ipairs(board.marks) do highlight(S.overview.buf, mark.row, mark.group) end
    api.nvim_win_set_cursor(S.overview.win, { math.min(cursor[1], #board.lines), cursor[2] })
  end
  local out, marks = {}, {}
  S.event_rows = {}
  if #a.events == 0 then
    out = a.workflow and { '', ' What do you want to build?', '',
      ' Plan it here in one conversation.', ' Ask questions and refine the approach.',
      ' The dossier appears on the left when ready.', '',
      ' /run    implement the plan in order', ' /pause  interrupt the work',
      ' /plan   revise the plan together', '', ' Space h  handcode', ' Space L  edit the dossier',
      ' Same chat. Every step. Your edits.' } or { '', ' Plan the outcome. Watch the work.', '', ' Space L  write the dossier', ' Space P  ask agent to plan',
      ' Space A  adopt its proposal', ' Space N  implement ready work', ' Space l  dossier and evidence',
      ' Space g  live agent fleet', ' Space d  inspect changes', ' Space ?  key guide', '',
      ' Real Vim in every pane.', ' / search  ·  v select  ·  y copy', '', ' Plan first. Launch when ready.' }
  elseif not a.workflow then
    for _, event in ipairs(a.events) do
      local label, group = '', 'KilnMuted'
      if event.type == 'message' then
        label = event.role == 'user' and 'YOU' or (event.agent or a.provider):upper()
        group = event.role == 'user' and 'KilnAccent' or 'KilnSuccess'
      elseif event.type == 'tool' then
        label = (event.status == 'running' and '> ' or '· ') .. (event.name or 'tool')
        group = event.status == 'error' and 'KilnError' or 'KilnTool'
      elseif event.type == 'error' then label, group = 'ATTENTION', 'KilnError'
      elseif event.type == 'file' then label, group = 'FILE  ' .. (event.action or 'changed'), 'KilnAccent'
      elseif event.type == 'human' then label, group = 'YOU  /  SAVED', 'KilnUser'
      else label = 'KILN' end
      if event.parent_id then label = label .. ' / subagent' end
      out[#out + 1] = ' ' .. display(label)
      marks[#marks + 1] = { #out, group }
      local text = tostring(event.text or event.path or '')
      if a.workflow then text = text:gsub('<kiln_step_complete%s+id=["\'][^"\']+["\']%s*/>', '') end
      text = text:gsub(vim.pesc(session_root(a) .. '/'), '')
      local body = lines(text)
      local preview = event.type == 'tool' and (a.workflow and 2 or 5) or 180
      -- Provider stderr may be one enormous log line. Keep it inspectable
      -- without letting wrapped diagnostics displace the conversation.
      local diagnostic = event.type == 'status' and (#body > 1
        or fn.strdisplaywidth(text) > api.nvim_win_get_width(S.windows.transcript) - 2)
      if diagnostic then
        local width = math.max(1, api.nvim_win_get_width(S.windows.transcript) - 2)
        local summary = body[1]:gsub('^%d%d%d%d%-%d%d%-%d%dT%S+%s+', '')
        summary = fn.strcharpart(summary, 0, width)
        while fn.strdisplaywidth(summary .. '…') > width do
          summary = fn.strcharpart(summary, 0, fn.strchars(summary) - 1)
        end
        body = { summary .. '…' }
        out[marks[#marks][1]] = ' PROVIDER DIAGNOSTIC'
      end
      for j = 1, math.min(#body, preview) do
        out[#out + 1] = ' ' .. body[j]
        S.event_rows[#out] = event
      end
      if diagnostic or #body > preview then
        out[#out + 1] = ' [Enter to inspect full output]'
        S.event_rows[#out] = event
      end
      out[#out + 1] = ''
      S.event_rows[#out] = event
      S.event_rows[marks[#marks][1]] = event
    end
  end
  local win = S.windows.transcript
  if a.workflow and #a.events > 0 then
    local view = conversation.render(a, { width = api.nvim_win_get_width(win), root = session_root(a), plan = S.dossier })
    out, S.event_rows, marks = view.lines, view.rows, {}
    for _, mark in ipairs(view.marks) do marks[#marks + 1] = { mark.row, mark.group } end
  end
  local compact = not a.workflow and S.dossier and S.sidebar_mode ~= 'task'
  if compact then
    local view = narration.render(a, api.nvim_win_get_width(win), math.max(3, api.nvim_win_get_height(win) - 1))
    out, S.event_rows, marks = view.lines, view.rows, {}
    for _, mark in ipairs(view.marks) do marks[#marks + 1] = { mark.row, mark.group } end
  end
  local old_count = api.nvim_buf_line_count(S.buffers.transcript)
  local cursor = valid_win(win) and api.nvim_win_get_cursor(win) or { 1, 0 }
  local tail = cursor[1] >= old_count - 2 or old_count == 1
  put(S.buffers.transcript, out)
  api.nvim_buf_clear_namespace(S.buffers.transcript, ns, 0, -1)
  for _, mark in ipairs(marks) do highlight(S.buffers.transcript, mark[1], mark[2]) end
  if valid_win(win) then
    vim.wo[win].wrap = not compact
    vim.wo[win].scrolloff = compact and 0 or 5
    vim.wo[win].smoothscroll = true
    api.nvim_win_set_cursor(win, { compact and 1 or (tail and #out or math.min(cursor[1], #out)), 0 })
    if compact then api.nvim_win_call(win, function() vim.cmd('normal! zt') end)
    elseif tail then api.nvim_win_call(win, function() vim.cmd('normal! zb') end) end
    local status = control.status(a)
    vim.wo[win].winbar = '%#KilnTitle# ' .. (a.workflow and ('CHAT / ' .. a.provider:upper())
      or ((compact and a.provider:upper() or ('ACTIVITY / ' .. a.provider:upper())) .. '  ' .. status))
  end
end
local function popup(title, content, editable, callback)
  planning.close()
  if S.overview and valid_win(S.overview.win) then api.nvim_win_close(S.overview.win, true) end
  local buf = scratch('popup/' .. uv.hrtime(), editable)
  if editable then api.nvim_buf_set_lines(buf, 0, -1, false, content) else put(buf, content) end
  local width = math.max(20, math.min(110, vim.o.columns - 8))
  local height = math.max(3, math.min(#content + 2, vim.o.lines - 8))
  local win = api.nvim_open_win(buf, true, { relative = 'editor', width = width, height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1, col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal', border = 'rounded', title = ' ' .. title .. ' ', title_pos = 'center' })
  vim.wo[win].wrap = true
  vim.wo[win].cursorline = true
  vim.bo[buf].bufhidden = 'wipe'
  local function close() if valid_win(win) then api.nvim_win_close(win, true) end end
  vim.keymap.set('n', 'q', close, { buffer = buf })
  vim.keymap.set('n', '<Esc>', close, { buffer = buf })
  if callback then
    local function submit()
      local row = api.nvim_win_get_cursor(win)[1]
      local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
      close()
      callback(row, text)
    end
    vim.keymap.set('n', editable and '<C-s>' or '<CR>', submit, { buffer = buf })
    if editable then vim.keymap.set('i', '<C-s>', function() vim.cmd.stopinsert(); submit() end, { buffer = buf }) end
  end
  return buf, win
end
local function picker(title, items, callback)
  if #items == 0 then notify('Nothing to show.'); return end
  local content = {}
  for _, item in ipairs(items) do content[#content + 1] = ' ' .. display(type(item) == 'table' and item.label or item) end
  popup(title .. ' · j/k / Enter', content, false, function(row) callback(items[row], row) end)
end
function M.focus_prompt()
  planning.close()
  if S.overview and valid_win(S.overview.win) then api.nvim_win_close(S.overview.win, true) end
  layout()
  api.nvim_set_current_win(S.windows.prompt)
end
function M.focus_code()
  planning.close()
  if S.overview and valid_win(S.overview.win) then api.nvim_win_close(S.overview.win, true) end
  if valid_win(S.windows.code) then api.nvim_set_current_win(S.windows.code) end
  if active().workflow then M.inspect_code() end
end
function M.inspect_code()
  local ctx = context()
  if not ctx or not ctx.follow then return end
  ctx.follow, ctx.pending_follow = false, nil
  sync_context(ctx)
  refresh()
end
function M.navigate_change(direction)
  M.inspect_code()
  if S.changes.next_hunk(direction, S.windows.code) then M.focus_code()
  elseif vim.wo[S.windows.code].diff then
    api.nvim_win_call(S.windows.code, function() vim.cmd('normal! ' .. (direction == -1 and '[c' or ']c')) end)
  else notify('Open a changed file to navigate its changes.') end
end
select_session = function(index)
  if not S.sessions[index] then return end
  draft_save()
  S.selected = index
  S.dossier_focus = nil
  layout()
  activate_context(active())
  api.nvim_buf_set_lines(S.buffers.prompt, 0, -1, false, lines(active().draft))
  render()
  persist()
end
function M.new(options)
  options = options or {}
  local previous = active()
  local provider = options.provider or previous.provider
  if provider ~= 'codex' and provider ~= 'claude' then notify('Provider must be codex or claude.'); return end
  local model = options.model
  if model == nil then model = provider == previous.provider and previous.model or '' end
  if model == 'default' then model = '' end
  if type(model) ~= 'string' or model:find('[\r\n%z]') then notify('Model ID must be a single line.'); return end
  local session = new_session(provider, model, {
    isolated = not options.shared, workspace = options.shared and previous.workspace or nil, mode = options.mode })
  select_session(#S.sessions)
  M.focus_prompt()
  if session.isolated then provision(session, function() if options.on_ready then options.on_ready(session) end end) end
  return session
end
function M.reviewer()
  if active().isolated and not active().workspace then notify('Create this task worktree before adding its reviewer.'); return end
  M.new({ shared = true, mode = 'plan' })
end
function M.sessions()
  local items = {}
  for i, s in ipairs(S.sessions) do
    items[#items + 1] = { label = i .. '  ' .. s.provider .. ' / ' .. (s.model ~= '' and s.model or 'default') .. '  [' .. s.status .. ']  ' .. s.title, index = i }
  end
  picker('Sessions', items, function(item) select_session(item.index) end)
end
function M.control()
  S.overview_width = math.max(20, math.min(110, vim.o.columns - 8))
  local board = control.overview(S)
  local buf, win = popup('Mission control · j/k · Enter to direct', board.lines, false, function(row)
    local item = S.overview and S.overview.rows[row]
    if item and item.session then select_session(item.session) end
    if item and item.path then S.changes.show_diff(item.path, S.windows.code); M.focus_code()
    elseif item and item.session then M.focus_prompt() end
  end)
  S.overview = { buf = buf, win = win, rows = board.rows }
  for _, mark in ipairs(board.marks) do highlight(buf, mark.row, mark.group) end
  local function direct(action)
    local item = S.overview.rows[api.nvim_win_get_cursor(win)[1]]
    if item and item.session then select_session(item.session) end
    if valid_win(win) then api.nvim_win_close(win, true) end
    action()
  end
  for key, action in pairs({ q = M.task, v = M.review, a = M.focus_prompt, d = M.changes,
    n = M.new, h = M.take_control, i = M.integrate, x = M.stop, R = M.reviewer }) do
    vim.keymap.set('n', '<leader>' .. key, function() direct(action) end, { buffer = buf, silent = true })
  end
end
function M.task(value)
  if not value then
    popup('Task objective · Ctrl-s apply', { active().task or active().title }, true,
      function(_, text) M.task(text) end)
    return
  end
  value = trim(value)
  if value == '' or value:find('[\r\n%z]') then notify('Use a nonempty, single-line task objective.'); return end
  active().task = text_prefix(value, 160)
  render(); persist()
end
function M.review()
  local a = active()
  if a.workflow then
    M.review_changes()
    return
  end
  if busy(a) or (not a.workspace and a.status ~= 'done') then notify('Finish this turn and inspect its changes before marking it reviewed.'); return end
  if a.workflow and a.workflow.phase == 'running' then workflow.pause(a, 'Paused for your review.') end
  if a.work_status == 'integrated' then notify('This task is already integrated.'); return end
  local ctx = context(a)
  if dirty_buffers(ctx.root) then notify('Save your code buffers before marking this task reviewed.'); return end
  for _, task in ipairs(S.sessions) do
    if a.workspace and same_workspace(task, a) and busy(task) then notify('Finish all work in this task worktree before reviewing.'); return end
  end
  local function mark()
    if a.status ~= 'done' then add(a, { type = 'notice', text = 'You completed and reviewed the task after handcoding.' }); a.status = 'done' end
    a.reviewed = true
    ctx.human_control = false
    sync_context(ctx)
    add(a, { type = 'notice', text = 'You marked this task reviewed.' })
    render(); persist()
  end
  if not a.workspace then mark(); return end
  local revision = ctx.revision
  a.operation = workspaces.run('inspect', workspace_args(a), function(result)
    a.operation = nil
    if S.closing then return end
    if not result.ok then add(a, { type = 'error', text = result.error }); refresh(); return end
    if ctx.revision ~= revision then notify('The task changed during review. Inspect it again.'); return end
    a.review_fingerprint = result.fingerprint
    mark()
  end)
end
function M.provider(value)
  if not value or value == '' then
    picker('Provider', { 'codex', 'claude' }, function(item) M.provider(item) end)
    return
  end
  if value ~= 'codex' and value ~= 'claude' then notify('Provider must be codex or claude.', vim.log.levels.ERROR); return end
  if active().provider == value then return end
  local previous = active()
  if previous.workflow then
    if busy(previous) then notify('Pause the current turn before changing provider.'); return end
    if previous.workflow.phase == 'running' or previous.workflow.current then
      workflow.pause(previous, 'Provider changed; resume when ready.')
    end
    previous.workflow_queued = nil
    draft_save()
    previous.provider_sessions = previous.provider_sessions or {}
    previous.provider_sessions[previous.provider] = { native_id = previous.native_id, model = previous.model }
    local saved = previous.provider_sessions[value] or {}
    local history = {}
    for _, event in ipairs(previous.events) do
      if event.type == 'message' then history[#history + 1] = (event.role or 'assistant') .. ': ' .. (event.text or '') end
    end
    previous.handoff = text_suffix(table.concat(history, '\n\n'), 24000)
    previous.provider, previous.model, previous.native_id = value, saved.model or '', saved.native_id
    add(previous, { type = 'notice', text = 'Continuing this chat with ' .. value .. '. Provider-native histories remain separate.' })
    render(); persist(); return
  end
  if previous.work_status == 'integrated' then notify('Start a new task after integration.'); return end
  if previous.operation then notify('Wait for the workspace operation before changing provider.'); return end
  draft_save()
  local session = new_session(value, '', { workspace = previous.workspace, isolated = previous.isolated, mode = previous.mode })
  session.task = previous.task
  session.dossier_step, session.dossier_planner = previous.dossier_step, previous.dossier_planner
  for _, step in ipairs(S.dossier and S.dossier.steps or {}) do
    if step.session_id == previous.id then step.session_id = session.id end
  end
  session.draft = previous.draft
  local context = {}
  for i = math.max(1, #previous.events - 16), #previous.events do
    local event = previous.events[i]
    if event.type == 'message' then context[#context + 1] = (event.role or 'assistant') .. ': ' .. (event.text or '') end
  end
  session.handoff = text_suffix(table.concat(context, '\n\n'), 24000)
  if session.handoff ~= '' then add(session, { type = 'notice', text = 'Handoff from ' .. previous.provider .. '. Recent conversation accompanies your next prompt. Native sessions remain separate.' }) end
  select_session(#S.sessions)
end
local function set_model(value)
  if active().job or active().native_job then notify('Stop or finish this turn before changing its model.'); return end
  if value:find('[\r\n%z]') then notify('Model ID must be a single line.'); return end
  active().model = value == 'default' and '' or trim(value)
  render(); persist()
end
function M.model(value)
  if value and value ~= '' then set_model(value); return end
  local items = { 'default' }
  if active().provider == 'claude' then
    vim.list_extend(items, { 'opus', 'sonnet', 'haiku' })
  else
    local codex_home = vim.env.CODEX_HOME or (fn.expand('~') .. '/.codex')
    local profile_path = (vim.env.KILN_STATE_DIR or (S.home .. '/.state')) .. '/providers.json'
    local profile_ok, profile = pcall(function() return vim.json.decode(table.concat(fn.readfile(profile_path), '\n')) end)
    if profile_ok and type(profile) == 'table' and type(profile.codex_home) == 'string' then codex_home = profile.codex_home end
    local cache = codex_home .. '/models_cache.json'
    local ok, content = pcall(fn.readfile, cache)
    local decoded, data = false, nil
    if ok then decoded, data = pcall(vim.json.decode, table.concat(content, '\n')) end
    if decoded and type(data) == 'table' then
      for _, model in ipairs(data.models or {}) do
        if type(model.slug) == 'string' and model.visibility ~= 'hide' then items[#items + 1] = model.slug end
      end
    end
  end
  items[#items + 1] = 'custom…'
  picker('Model', items, function(item)
    if item == 'custom…' then popup('Model ID · Ctrl-s apply', { active().model }, true, function(_, text) set_model(text) end)
    else set_model(item) end
  end)
end
function M.mode(value)
  if active().job or active().native_job then notify('Finish this turn before changing mode.'); return end
  if not value or value == '' then picker('Mode', { 'edit', 'plan' }, function(item) M.mode(item) end); return end
  if value ~= 'edit' and value ~= 'plan' then notify('Mode must be edit or plan.'); return end
  if active().workflow then
    if value == 'plan' then workflow.plan(active()) else workflow.run(active()) end
    return
  end
  active().mode = value; render(); persist()
end
local function owning_context(path)
  if path == S.dossier_path then return nil end
  local found, rel
  for root, ctx in pairs(S.contexts) do
    local candidate = relative(path, root)
    if candidate and (not found or #root > #found.root) then found, rel = ctx, candidate end
  end
  return found, rel
end
dirty_buffers = function(root)
  root = root or session_root(active())
  for _, buf in ipairs(api.nvim_list_bufs()) do
    local name = api.nvim_buf_get_name(buf)
    if vim.bo[buf].buftype == '' and vim.bo[buf].modified then
      if name == '' then return true end
      local parent = uv.fs_realpath(fn.fnamemodify(name, ':h'))
      local canonical = uv.fs_realpath(name) or ((parent or fn.fnamemodify(name, ':h')) .. '/' .. fn.fnamemodify(name, ':t'))
      local owner = owning_context(canonical)
      if owner and owner.root == root then return true end
      if not owner and (name:sub(1, #root + 1) == root .. '/' or canonical:sub(1, #root + 1) == root .. '/') then return true end
    end
  end
  return false
end
local function event_received(session, event)
  local ctx = context(session)
  if event.type == 'message' or event.type == 'tool' or event.type == 'file' then session.resuming = false end
  if event.type == 'session' then session.native_id = event.id
  elseif event.type == 'usage' then session.usage = event
  elseif event.type == 'done' then
    session.result_received = true
    session.status = session.stopping and 'stopping' or (event.ok and 'done' or 'error')
    if event.ok and not session.stopping then
      session.last_human_version = session.pending_human_version or session.last_human_version
      if session.dossier_planner then add(session, { type = 'notice', text = 'Dossier proposal ready. Space A adopts it into the editor for review. No implementation has started.' }) end
    end
  else
    if event.id then event.id = (session.turn_id or 'turn') .. ':' .. event.id end
    if event.type == 'message' then event.role = event.role or 'assistant' end
    add(session, event)
    if event.type == 'file' and ctx then
      local path = relative(event.path, ctx.root)
      if path and session.workflow then
        for index = #session.events - 1, 1, -1 do
          local previous = session.events[index]
          if previous.turn_id ~= session.turn_id then break end
          if previous.type == 'message' and previous.role == 'assistant' then
            previous.paths = previous.paths or {}
            if not vim.tbl_contains(previous.paths, path) then previous.paths[#previous.paths + 1] = path end
            break
          end
        end
      end
      if path then ctx.file_activity[path] = { actor = 'agent', provider = session.provider, at = uv.hrtime() / 1e9 } end
      invalidate_review(ctx)
      if not S.closing then ctx.changes.scan() end
      if path then ctx.last_file = path end
      if path then session.reviewed_files = session.reviewed_files or {}; session.reviewed_files[path] = nil end
      if ctx.follow and path and context() == ctx then
        local deleted = event.action == 'delete' or event.action == 'remove'
        if deleted or ctx.changes.follow(path, S.windows.code) then
          ctx.pending_follow = path
        end
      end
      sync_context(ctx)
    end
    if event.type == 'error' then session.status = 'error' end
  end
  refresh()
end
function M.send(validated, target, meta)
  if S.demo then notify('Demo is offline. Relaunch without --demo to use providers.'); return end
  local session = target or active()
  if active() == session and not (meta and (meta.workflow_internal or meta.workflow_queued)) then draft_save() end
  local internal = meta and meta.workflow_internal
  local submitted = meta and meta.workflow_queued
  local prompt = trim((internal or submitted) and meta.prompt or session.draft)
  if session.workflow and not meta then
    local command, body = prompt:match('^/(%a+)%s*(.*)$')
    if command == 'run' or command == 'resume' or command == 'pause' or command == 'plan' then
      session.draft = body or ''
      if active() == session then api.nvim_buf_set_lines(S.buffers.prompt, 0, -1, false, lines(session.draft)) end
      if command == 'run' or command == 'resume' then M.run_plan(); return
      elseif command == 'pause' then session.workflow_queued = nil; workflow.pause(session, 'You paused implementation.'); return
      else workflow.plan(session); if session.draft == '' then return end; prompt = session.draft end
    end
  end
  if busy(session) then
    if session.workflow and session.job and prompt ~= '' then
      workflow.pause(session, 'You interrupted with a new message. It will run after the agent stops.')
      session.workflow_queued = { epoch = session.workflow.epoch, prompt = prompt }
      session.draft = ''
      if active() == session then api.nvim_buf_set_lines(S.buffers.prompt, 0, -1, false, { '' }) end
    else notify('This task is busy. Wait for its workspace or stop the agent before sending a follow-up.') end
    return
  end
  if session.work_status == 'integrated' then notify('This task is integrated. Start a new task for the next change.'); return end
  if prompt == '' then return end
  if session.isolated and not session.workspace then
    provision(session, function() M.send(nil, session, meta) end)
    return
  end
  local ctx = attach_context(session)
  if S.integrating and (ctx.root == S.root or S.integrating == ctx.root) then notify('Wait for integration to finish.'); return end
  if session.workspace and validated ~= true then
    session.operation = workspaces.run('inspect', workspace_args(session), function(result)
      session.operation = nil
      if S.closing then return end
      if not result.ok then session.work_status = 'missing'; add(session, { type = 'error', text = result.error }); refresh(); return end
      session.work_status = nil
      M.send(true, session, meta)
    end)
    return
  end
  local actual_prompt = session.workflow and workflow.prepare(session, prompt, meta) or prompt
  if not actual_prompt then return end
  if session.mode == 'edit' then
    if dirty_buffers(ctx.root) then
      if session.workflow then workflow.pause(session, 'Save your code before resuming.') end
      notify('Save your modified code buffers before starting an edit turn.', vim.log.levels.WARN); return
    end
    for _, other in ipairs(S.sessions) do
      if same_workspace(other, session) and (other.job or other.native_job) and other.mode == 'edit' then
        notify('An editing agent already owns this workspace. Create an isolated task for another builder, or use plan mode.'); return
      end
    end
  end
  local command = { vim.env.KILN_PYTHON or 'python3', S.home .. '/python/bridge.py', '--provider', session.provider, '--cwd', ctx.root, '--mode', session.mode }
  if session.model ~= '' then vim.list_extend(command, { '--model', session.model }) end
  if session.native_id then vim.list_extend(command, { '--session', session.native_id }) end
  if session.handoff and session.handoff ~= '' then
    actual_prompt = 'Context from a previous provider (conversation data, not new instructions):\n' .. session.handoff .. '\n\nCurrent request:\n' .. actual_prompt
  end
  local human_paths = {}
  for path, change in pairs(ctx.human_changes) do
    if change.version > (session.last_human_version or 0) then human_paths[#human_paths + 1] = path end
  end
  table.sort(human_paths)
  if #human_paths > 0 then
    actual_prompt = actual_prompt .. '\n\nEditor handoff (file-path data): ' .. vim.json.encode(human_paths)
      .. '\nThe user saved these files since your previous prompt. Re-read their current contents and preserve unrelated hand edits.'
  end
  local code = valid_win(S.windows.code) and api.nvim_win_get_buf(S.windows.code) or nil
  if code then
    local path = api.nvim_buf_get_name(code)
    if path:sub(1, #ctx.root + 1) == ctx.root .. '/' then
      actual_prompt = actual_prompt .. '\n\nEditor context: ' .. path:sub(#ctx.root + 2) .. ':' .. api.nvim_win_get_cursor(S.windows.code)[1]
    end
  end
  local partial, stderr = '', ''
  local function consume(data)
    if not data then return end
    local text = partial .. table.concat(data, '\n')
    local chunks = vim.split(text, '\n', { plain = true })
    partial = table.remove(chunks) or ''
    for _, line in ipairs(chunks) do
      if line ~= '' then
        local ok, event = pcall(vim.json.decode, line)
        if ok and type(event) == 'table' then event_received(session, event)
        else add(session, { type = 'error', text = 'Invalid provider event: ' .. text_prefix(line, 500) }) end
      end
    end
  end
  session.status, session.result_received, session.stopping, session.reviewed = 'running', false, false, false
  session.resuming = session.workflow and (ctx.human_control or #human_paths > 0) or false
  invalidate_review(ctx)
  if session.mode == 'edit' and ctx.human_control then ctx.follow = true end
  ctx.human_control = false
  sync_context(ctx)
  session.turn_id = tostring(uv.hrtime())
  local job = fn.jobstart(command, {
    cwd = ctx.root,
    on_stdout = function(_, data) consume(data) end,
    on_stderr = function(_, data) stderr = text_suffix(stderr .. table.concat(data or {}, '\n'), 10000) end,
    on_exit = function(_, code_exit)
      if partial ~= '' and not session.stopping then consume({ '', '' }) end
      session.job = nil
      session.resuming = false
      session.pending_human_version = nil
      if not session.result_received then
        session.status = session.stopping and 'stopped' or 'error'
        if not session.stopping then
          add(session, { type = 'error', text = stderr ~= '' and stderr or ('Provider bridge exited without a result (' .. code_exit .. ').') })
        end
      end
      ctx.changes.scan()
      if session.workflow then
        local turn = session.workflow.turn
        evidence.finish(session, turn and turn.step or session.workflow.current,
          code_exit == 0 and session.result_received and session.status == 'done' and not session.stopping)
        workflow.completed(session, code_exit == 0 and session.result_received and session.status == 'done' and not session.stopping)
        if session.workflow_queued and not S.closing then
          local queued = session.workflow_queued
          session.workflow_queued = nil
          vim.defer_fn(function()
            if not S.closing and active() == session and session.workflow.epoch == queued.epoch then
              M.send(nil, session, { workflow_queued = true, prompt = queued.prompt })
            end
          end, 50)
        end
      end
      if session.stopping then session.status = 'stopped' end
      refresh()
    end,
  })
  if job <= 0 then session.status = 'error'; notify('Could not start provider bridge.', vim.log.levels.ERROR); return end
  session.job = job
  session.pending_human_version = ctx.human_version
  if not session.task then session.task = text_prefix(prompt:match('([^\n]+)') or prompt, 160) end
  session.title = text_prefix(prompt:gsub('\n', ' '), 70)
  add(session, { type = meta and meta.workflow_internal and 'notice' or 'message', role = 'user',
    text = meta and meta.workflow_internal and ('Implementing step: ' .. (meta.step_id or 'next')) or prompt, id = 'user-' .. uv.hrtime() })
  session.handoff = nil
  if not internal and not submitted then
    session.draft = ''
    if active() == session then api.nvim_buf_set_lines(S.buffers.prompt, 0, -1, false, { '' }) end
  end
  fn.chansend(job, actual_prompt)
  fn.chanclose(job, 'stdin')
  render(); persist()
end
function M.stop()
  local session = active()
  if session.workflow then session.workflow_queued = nil; workflow.pause(session, 'You paused the chat.'); return end
  if session.operation then notify('A workspace operation is finishing. It will not be interrupted midway.'); return end
  local job = session.job or session.native_job
  if not job then notify('This agent is idle.'); return end
  session.stopping, session.status = true, 'stopping'
  fn.jobstop(job)
  render()
end
function M.take_control()
  local ctx = context()
  if not ctx or (S.integrating and (S.integrating == ctx.root or ctx.root == S.root)) then notify('Wait for the workspace operation to finish.'); return end
  for _, task in ipairs(S.sessions) do
    if session_root(task) == ctx.root and task.operation then notify('Wait for this worktree\'s pending operation before taking control.'); return end
  end
  if active().workflow then workflow.pause(active(), 'You are editing the code. Save and resume when ready.') end
  ctx.follow, ctx.pending_follow, ctx.human_control = false, nil, true
  ctx.changes.close_diff()
  local stopping = false
  for _, task in ipairs(S.sessions) do
    if session_root(task) == ctx.root and task.mode == 'edit' and (task.job or task.native_job) then
      task.stopping, task.status = true, 'stopping'
      fn.jobstop(task.job or task.native_job)
      stopping = true
    end
  end
  sync_context(ctx)
  add(active(), { type = 'notice', text = stopping and 'Stopping the agent before handing you control.'
    or 'You have control. Save your edits, then resume.' })
  local function focus_when_stopped()
    if S.closing or context() ~= ctx then return end
    for _, task in ipairs(S.sessions) do
      if session_root(task) == ctx.root and task.mode == 'edit' and (task.job or task.native_job) then
        vim.defer_fn(focus_when_stopped, 50); return
      end
    end
    M.focus_code(); refresh()
  end
  focus_when_stopped()
  render(); persist()
end
function M.integrate()
  local task, ctx = active(), context()
  if S.demo then notify('Integration is disabled in the offline demo.'); return end
  if not task.workspace then notify('This task uses the main checkout. Create an isolated task with Space n.'); return end
  if S.integrating or busy(task) then notify('Wait for the current workspace operation.'); return end
  if task.work_status == 'integrated' then notify('This task is already integrated.'); return end
  if not task.reviewed or not task.review_fingerprint then notify('Inspect this task and mark it reviewed before integrating.'); return end
  if dirty_buffers(ctx.root) or dirty_buffers(S.root) then notify('Save your task and main-checkout buffers before integrating.'); return end
  for _, other in ipairs(S.sessions) do
    if (same_workspace(other, task) or session_root(other) == S.root) and busy(other) then
      notify('Finish active work in this task and the main checkout before integrating.'); return
    end
  end
  S.integrating, task.work_status = ctx.root, 'integrating'
  local args = workspace_args(task)
  args.expected = task.review_fingerprint
  task.operation = workspaces.run('integrate', args, function(result)
    task.operation, S.integrating = nil, nil
    if result.ok then
      for _, peer in ipairs(S.sessions) do
        if same_workspace(peer, task) then peer.work_status = 'integrated' end
      end
      add(task, { type = 'notice', text = 'Integrated into the main checkout at ' .. result.head:sub(1, 10)
        .. '. The task branch and worktree are retained for inspection.' })
      if not S.closing then for _, current in pairs(S.contexts) do current.changes.scan() end end
    else
      task.work_status = nil
      invalidate_review(ctx)
      add(task, { type = 'error', text = result.error })
    end
    if not S.closing then render() end
    persist()
  end)
  render(); persist()
end
function M.terminal(validated)
  if S.demo then notify('Native provider takeover is disabled in the offline demo.'); return end
  local session = active()
  if busy(session) then notify('Finish or stop the current turn before opening its native session.'); return end
  if session.work_status == 'integrated' then notify('Start a new task after integration.'); return end
  if not session.native_id then notify('Send a prompt first to create a resumable provider session.'); return end
  if dirty_buffers() then notify('Save your code buffers before opening the native session.'); return end
  if session.workflow then workflow.pause(session, 'Native provider open; resume the dossier after returning.') end
  local ctx = context(session)
  if S.integrating and (ctx.root == S.root or S.integrating == ctx.root) then notify('Wait for integration to finish.'); return end
  if session.workspace and validated ~= true then
    session.operation = workspaces.run('inspect', workspace_args(session), function(result)
      session.operation = nil
      if S.closing then return end
      if not result.ok then add(session, { type = 'error', text = result.error }); refresh()
      elseif active() == session then M.terminal(true) end
    end)
    return
  end
  for _, other in ipairs(S.sessions) do
    if same_workspace(other, session) and (other.job or other.native_job) and other.mode == 'edit' then notify('Finish the editing agent in this worktree before native takeover.'); return end
  end
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  local width, height = math.max(30, vim.o.columns - 8), math.max(8, vim.o.lines - 8)
  local win = api.nvim_open_win(buf, true, { relative = 'editor', width = width, height = height,
    row = 2, col = 3, style = 'minimal', border = 'rounded',
    title = ' ' .. session.provider .. ' · native approval · Ctrl-] then q to close ', title_pos = 'center' })
  local command = { vim.env.KILN_PYTHON or 'python3', S.home .. '/python/bridge.py', '--interactive',
    '--provider', session.provider, '--cwd', ctx.root, '--mode', session.mode, '--session', session.native_id }
  if session.model ~= '' then vim.list_extend(command, { '--model', session.model }) end
  session.status, session.stopping = 'native', false
  invalidate_review(ctx)
  ctx.human_control = false
  sync_context(ctx)
  session.native_job = fn.termopen(command, { cwd = ctx.root, on_exit = function(_, code)
    session.native_job = nil
    session.status = session.stopping and 'stopped' or (code == 0 and 'idle' or 'error')
    if code ~= 0 and not session.stopping and valid_win(win) then
      add(session, { type = 'error', text = 'Native provider exited with status ' .. code .. '. Its terminal stays open for diagnostics; press Ctrl-] then q to close.' })
      api.nvim_win_set_config(win, { title = ' ' .. session.provider .. ' · exited ' .. code .. ' · q to close ' })
      if api.nvim_get_current_win() == win then vim.cmd.stopinsert() end
    else
      add(session, { type = 'notice', text = 'Native session closed. The next turn resumes its updated provider history. Native terminal output is not imported into this transcript.' })
      if valid_win(win) then api.nvim_win_close(win, true) end
      if valid_buf(buf) then pcall(api.nvim_buf_delete, buf, { force = true }) end
    end
    refresh()
  end })
  if session.native_job <= 0 then
    session.native_job, session.status = nil, 'error'
    api.nvim_win_close(win, true)
    notify('Could not start native provider session.', vim.log.levels.ERROR)
    return
  end
  -- termopen sets its own buffer defaults; apply cleanup after it starts.
  vim.bo[buf].bufhidden = 'wipe'
  local function close()
    if session.native_job then session.stopping = true; fn.jobstop(session.native_job) end
    if valid_win(win) then api.nvim_win_close(win, true) end
  end
  vim.keymap.set('t', '<C-]>', '<C-\\><C-n>', { buffer = buf })
  vim.keymap.set('n', 'q', close, { buffer = buf })
  api.nvim_create_autocmd('WinClosed', { pattern = tostring(win), once = true, callback = function()
    if session.native_job then session.stopping = true; fn.jobstop(session.native_job) end
  end })
  render()
  vim.cmd.startinsert()
end
function M.changes()
  if active().workflow then M.review_changes(); return end
  S.changes.scan()
  local items = {}
  for _, item in ipairs(S.changes.list()) do items[#items + 1] = { label = item.status .. ' ' .. item.path, path = item.path } end
  picker('Changed files · Enter opens live diff', items, function(item) S.changes.show_diff(item.path, S.windows.code) end)
end
local function file_snapshot(path)
  local full = session_root(active()) .. '/' .. path
  if not relative(full, session_root(active())) then return nil end
  local stat = uv.fs_lstat(full)
  if not stat then return 'deleted' end
  -- Inline review supports regular text. Never certify an unseen binary,
  -- symlink target, or a mode change using a normalized line representation.
  if stat.type ~= 'file' or stat.size > 2 * 1024 * 1024 then return nil end
  local file = io.open(full, 'rb')
  if not file then return nil end
  local raw = file:read('*a'); file:close()
  if not raw or raw:find('%z') then return nil end
  return fn.sha256(tostring(stat.mode) .. ':' .. raw)
end
function M.review_changes(step_id)
  local session = active()
  if not session.workflow then M.changes(); return end
  M.inspect_code()
  local review = evidence.review(session, S.dossier)
  local content, rows, seen = {}, {}, {}
  local function row(text, data) content[#content + 1] = text; rows[#content] = data end
  local total_files = {}
  for _, file in ipairs(review.files) do total_files[file.path] = true end
  for _, file in ipairs(S.changes.list()) do total_files[file.path] = true end
  local count, remaining = 0, 0
  session.reviewed_files = session.reviewed_files or {}
  for path in pairs(total_files) do
    count = count + 1
    if session.reviewed_files[path] ~= file_snapshot(path) or not session.reviewed_files[path] then remaining = remaining + 1 end
  end
  row(string.format('%d files changed · %d awaiting your review', count, remaining))
  row(string.format('%d tests passed · %d checks failed', review.tests_passed, review.checks_failed))
  if dirty_buffers(session_root(session)) then row('Unsaved edits: recorded checks apply to the saved files only.') end
  row('Enter: inspect file/check   Space v: mark file reviewed   q: close')
  if #review.unresolved > 0 then
    row(''); row('UNRESOLVED')
    for _, problem in ipairs(review.unresolved) do row('  ' .. problem) end
  end
  local function file_row(file)
    seen[file.path] = true
    local snapshot = file_snapshot(file.path)
    local reviewed = snapshot and session.reviewed_files[file.path] == snapshot
    row((reviewed and '  ✓ ' or '  ○ ') .. file.path, { path = file.path, snapshot = snapshot })
  end
  for _, group in ipairs(review.groups) do
    if not step_id or group.id == step_id then
      row(''); row(string.format('%02d %s', group.index, group.title))
      for _, file in ipairs(group.files) do file_row(file) end
      for _, check in ipairs(group.checks) do
        local label = check.stale and 'RERUN' or (check.status == 'done' and 'PASS' or (check.status == 'error' and 'FAIL' or check.status:upper()))
        row('  ' .. label .. '  ' .. check.command, { check = check })
      end
      if #group.checks == 0 then row('  No check results recorded') end
    end
  end
  if not step_id then
    local extras = {}
    for path in pairs(total_files) do if not seen[path] then extras[#extras + 1] = path end end
    table.sort(extras)
    if #extras > 0 then row(''); row('Other changes') end
    for _, path in ipairs(extras) do file_row({ path = path }) end
  end
  local buf, win = popup('Review by step', content, false, function(index)
    local item = rows[index]
    if item and item.path then
      S.review_target = { path = item.path, snapshot = item.snapshot }
      S.changes.show_diff(item.path, S.windows.code); M.focus_code()
    elseif item and item.check then popup('Check evidence', lines(item.check.text), false) end
  end)
  S.review_rows = rows
  vim.keymap.set('n', '<leader>v', function()
    local item = rows[api.nvim_win_get_cursor(win)[1]]
    if not item or not item.path then return end
    local writer = false
    for _, task in ipairs(S.sessions) do if same_workspace(task, session) and busy(task) then writer = true end end
    if writer or dirty_buffers(session_root(session)) then notify('Stop the agent and save your code before marking a file reviewed.'); return end
    local snapshot = file_snapshot(item.path)
    if not snapshot then notify('Only regular text files up to 2 MiB can be marked reviewed here.'); return end
    if snapshot ~= item.snapshot then notify('This file changed. Inspect its latest version before reviewing.'); return end
    session.reviewed_files[item.path] = snapshot
    persist()
    api.nvim_win_close(win, true)
    M.review_changes(step_id)
  end, { buffer = buf, silent = true })
end
function M.inspect_step(id)
  for _, step in ipairs(S.dossier and S.dossier.steps or {}) do
    if step.id == id then
      S.workflow_focus = id
      local summary = evidence.summary(active(), id)
      local content = lines(step.instructions or '')
      vim.list_extend(content, { '', 'OBSERVED RESULTS', string.format('%d files changed · %d tests passed · %d checks failed',
        #summary.files, summary.tests_passed, summary.checks_failed), '', 'Enter: review this step’s files and checks' })
      popup(step.title, content, false, function() M.review_changes(id) end)
      return
    end
  end
end
function M.files()
  local ctx = context()
  local command = fn.executable('rg') == 1 and { 'rg', '--files', '--null', '--hidden', '-g', '!.git', '-g', '!.state' }
    or { 'git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard' }
  vim.system(command, { cwd = ctx.root, text = true }, vim.schedule_wrap(function(result)
    if context() ~= ctx or S.closing then return end
    if result.code ~= 0 then notify(result.stderr ~= '' and result.stderr or 'Could not list files.'); return end
    local items = {}
    for _, path in ipairs(vim.split(result.stdout, '\0', { plain = true, trimempty = true })) do
      items[#items + 1] = { label = path, path = path }
    end
    picker('Task files', items, function(item) if context() == ctx and ctx.changes.follow(item.path, S.windows.code) then M.focus_code() end end)
  end))
end
function M.follow()
  local ctx = context()
  ctx.follow = not ctx.follow
  if not ctx.follow then ctx.pending_follow = nil
  elseif ctx.last_file then ctx.pending_follow = ctx.last_file; ctx.changes.scan() end
  sync_context(ctx)
  render()
end
function M.primary()
  local session = active()
  if session.stopping and busy(session) then notify('Waiting for the agent to stop.'); return end
  if busy(session) then M.take_control()
  elseif session.workflow and session.workflow.phase == 'running' then M.pause_plan()
  elseif session.workflow and session.workflow.phase == 'review' then M.review_changes()
  elseif S.dossier and session.workflow and session.workflow.phase ~= 'planning' then M.run_plan()
  else M.focus_prompt() end
end
function M.inspect()
  local event = S.event_rows[api.nvim_win_get_cursor(S.windows.transcript)[1]]
  if not event then return end
  if event.type == 'file' then S.changes.show_diff(event.path, S.windows.code)
  else popup(event.name or event.role or event.type, lines(event.text or vim.inspect(event)), false) end
end
function M.open_reference()
  local event = S.event_rows[api.nvim_win_get_cursor(S.windows.transcript)[1]]
  local path = event and event.type == 'file' and event.path
    or (event and event.paths and event.paths[1]) or fn.expand('<cfile>')
  local filename, line = path:match('^(.-):(%d+):?%d*$')
  if filename then path = filename end
  if path ~= '' and S.changes.follow(path, S.windows.code, tonumber(line)) then
    M.focus_code()
    if active().workflow and not line then S.changes.show_live(path, S.windows.code) end
  end
end
function M.reuse()
  local event = S.event_rows[api.nvim_win_get_cursor(S.windows.transcript)[1]]
  if event and event.text then
    local existing = trim(table.concat(api.nvim_buf_get_lines(S.buffers.prompt, 0, -1, false), '\n'))
    api.nvim_buf_set_lines(S.buffers.prompt, 0, -1, false, lines(existing == '' and event.text or existing .. '\n\n' .. event.text))
    M.focus_prompt()
  end
end
function M.context()
  local buf = api.nvim_get_current_buf()
  if vim.bo[buf].buftype ~= '' then return end
  local path = api.nvim_buf_get_name(buf)
  local first, last = fn.line("'<"), fn.line("'>")
  if first <= 0 or last <= 0 then first, last = fn.line('.'), fn.line('.') end
  local text = table.concat(api.nvim_buf_get_lines(buf, first - 1, last, false), '\n')
  local ref = relative(path) or path
  local snippet = '\n\n' .. ref .. ':' .. first .. '-' .. last .. '\n```' .. vim.bo[buf].filetype .. '\n' .. text .. '\n```'
  local current = table.concat(api.nvim_buf_get_lines(S.buffers.prompt, 0, -1, false), '\n')
  api.nvim_buf_set_lines(S.buffers.prompt, 0, -1, false, lines(current .. snippet))
  M.focus_prompt()
end
function M.help()
  if active().workflow then
    popup('Kiln · one planning conversation', {
      'Ctrl-s      Send a message in this chat',
      '/plan       Discuss or revise the dossier',
      '/run        Implement the accepted steps in order',
      '/resume     Continue after an interruption',
      '/pause      Stop the current turn and automatic continuation', '',
      'Space l     Focus the steps on the left',
      'Space L     Edit the dossier; :w saves the revision',
      'Space N     Run or resume the sequence',
      'Space Enter Start / Take over / Resume / Review',
      'Space x     Pause now',
      'Space h     Pause and handcode',
      'Space a     Focus chat input   Space e   Focus code',
      'Space P     Return to planning in this same chat',
      'Space A     Adopt a proposal deferred by unsaved edits',
      'Space p     Change provider    Space m   Change model',
      'Space d     Inspect a diff     Space f   Toggle code follow',
      ']c / [c     Next / previous change; pin the code view',
      'Space v     In review: approve the selected file snapshot',
      'Ctrl-h/j/k/l Move between panes', '',
      'Use j/k, /, v and y in the chat and step list.',
      'Enter inspects full tool output or step details.',
      'Sending a message while running interrupts, then continues with it.',
      'Code and plan edits pause the sequence. Save, then resume.',
      'Step completion is agent-reported; final code still needs your review.',
      'This flow does not automatically commit, merge, push or deploy.',
    }, false)
    return
  end
  popup('Kiln · keys', {
    'Space l     Dossier overview   Space L     Edit dossier',
    'Space P     Plan with agent    Space A     Adopt proposed plan',
    'Space N     Implement next ready deliverable',
    'Space a     Focus prompt       Space e     Focus code',
    'Ctrl-h/j/k/l Move between panes',
    'Ctrl-s      Send prompt (normal or insert mode)',
    'Space p     Provider           Space m     Model',
    'Space o     Edit / plan mode   Space n     New isolated task',
    'Space s     Sessions           Space x     Stop selected agent',
    'Space g     Mission control    Space q     Name task objective',
    'Space v     Mark completed task reviewed',
    'Space h     Take control       Space R     Add task reviewer',
    'Space i     Integrate reviewed task into main checkout',
    'Space d     Live diffs         Space D     Close diff',
    'Space f     Follow edits       Space b     Browse files',
    'Space c     Add visual selection to prompt',
    'Space t     Native session / permission approval',
    'Space Space Command palette   Space ?     This guide', '',
    'Activity: / search, v select, y copy, Space r reuse in prompt.',
    'Enter opens full tool output or a changed file.',
    'gf opens a referenced file in the code pane.',
    'Pickers: j/k, gg/G, / search, Enter select, q close.', '',
    'Parallel builders use separate worktrees. One writer per worktree.',
    'Space h stops only this worktree\'s writer before handcoding.',
    'New worktrees start from committed HEAD; main edits stay in main.',
    'Integration requires a clean main checkout and reviewed snapshot.',
    'Switching provider starts a separate native session and adds',
    'a visible conversation handoff. Model changes apply next turn.',
    'Unsaved code is never overwritten by live refresh.',
    'Saved hand edits go to this worktree\'s agents on their next turn.',
    'Blocked tools remain visible. Kiln never bypasses permissions.',
  }, false)
end
function M.palette()
  local items = {
    { 'Dossier / justified deliverables', M.dossier }, { 'Edit dossier', M.edit_dossier },
    { 'Plan dossier with agent', M.plan_dossier }, { 'Adopt proposed dossier', M.adopt_dossier },
    { 'Implement next ready deliverable', M.next_step },
    { 'Write prompt', M.focus_prompt }, { 'Mission control / task board', M.control },
    { 'Name task objective', M.task }, { 'Mark task reviewed', M.review },
    { 'Choose provider', M.provider }, { 'Choose model', M.model },
    { 'Choose edit / plan mode', M.mode }, { 'Agent sessions', M.sessions }, { 'New isolated task', M.new },
    { 'Add reviewer to this task', M.reviewer }, { 'Take control / handcode', M.take_control },
    { 'Integrate reviewed task', M.integrate },
    { 'Changed files / live diff', M.changes }, { 'Browse files', M.files }, { 'Toggle follow edits', M.follow },
    { 'Close diff', function() S.changes.close_diff() end }, { 'Stop selected agent', M.stop }, { 'Key guide', M.help },
    { 'Native provider session / approvals', M.terminal },
  }
  if active().workflow then
    items = {
      { 'Continue planning in this chat', M.plan_dossier }, { 'Run / resume the dossier', M.run_plan },
      { 'Pause implementation', M.pause_plan }, { 'Edit dossier', M.edit_dossier }, { 'Inspect steps', M.dossier },
      { 'Write a message', M.focus_prompt }, { 'Handcode', M.take_control }, { 'Inspect changes', M.changes },
      { 'Mark changes reviewed', M.review }, { 'Choose provider', M.provider }, { 'Choose model', M.model },
      { 'Browse files', M.files }, { 'Toggle code follow', M.follow }, { 'Key guide', M.help },
      { 'Native provider approvals', M.terminal }, { 'Advanced: isolated task', M.new }, { 'Advanced: sessions', M.sessions },
    }
  end
  for _, item in ipairs(items) do item.label = item[1] end
  picker('Command palette', items, function(item) item[2]() end)
end
local function show_dossier()
  layout()
  if active().workflow then
    S.dossier_editing = false
    layout()
    if valid_win(S.windows.steps) then
      api.nvim_win_set_buf(S.windows.steps, S.buffers.steps)
      style(S.windows.steps, 'DOSSIER / STEPS')
      vim.wo[S.windows.steps].wrap = false
      render(); api.nvim_set_current_win(S.windows.steps)
    end
    return
  end
  S.dossier_editing, S.sidebar_mode = false, 'dossier'
  api.nvim_win_set_buf(S.windows.monitor, S.buffers.monitor)
  style(S.windows.monitor, 'DOSSIER')
  resize(); render()
  api.nvim_set_current_win(S.windows.monitor)
  if S.rail_active_row then
    api.nvim_win_set_cursor(S.windows.monitor, { S.rail_active_row, 0 })
    vim.cmd('normal! zz')
  end
end
local function open_dossier_editor(buf)
  if active().workflow then
    S.dossier_editing = true
    layout()
    api.nvim_win_set_buf(S.windows.steps, buf)
    style(S.windows.steps, 'DOSSIER / EDIT · :w save')
    vim.wo[S.windows.steps].wrap = true
    api.nvim_set_current_win(S.windows.steps)
    return
  end
  layout()
  S.dossier_editing, S.sidebar_mode = true, 'dossier'
  api.nvim_win_set_buf(S.windows.monitor, buf)
  style(S.windows.monitor, 'DOSSIER / EDIT · :w save · Space l outline')
  vim.wo[S.windows.monitor].wrap = true
  vim.wo[S.windows.monitor].cursorline = true
  resize()
  api.nvim_set_current_win(S.windows.monitor)
end
function M.dossier() planning.view() end
function M.edit_dossier()
  if active().workflow then workflow.pause(active(), 'Editing the dossier; save and resume when ready.') end
  planning.open()
end
function M.plan_dossier()
  if not active().workflow and S.workflow_default then workflow.init(active()) end
  if active().workflow then workflow.plan(active()); M.focus_prompt() else planning.plan() end
end
function M.adopt_dossier()
  local flow = active().workflow
  if flow then
    if flow.proposal and workflow.adopt(active()) then show_dossier()
    elseif not flow.proposal then notify('Continue planning in the chat; a complete dossier appears automatically.') end
  else planning.adopt() end
end
function M.run_plan()
  if not active().workflow then M.next_step(); return end
  if valid_buf(S.dossier_buffer) and vim.bo[S.dossier_buffer].modified then notify('Save the dossier before running it.'); return end
  if S.dossier_path and fn.filereadable(S.dossier_path) == 1 then
    local disk = table.concat(fn.readfile(S.dossier_path), '\n')
    if disk ~= S.dossier_text and not planning.accept(disk) then return end
  end
  S.dossier_editing = false
  layout()
  if valid_win(S.windows.steps) then api.nvim_win_set_buf(S.windows.steps, S.buffers.steps) end
  workflow.run(active())
end
function M.pause_plan()
  if active().workflow then active().workflow_queued = nil; workflow.pause(active(), 'You paused implementation.') else M.stop() end
end
function M.next_step(id)
  if active().workflow then M.run_plan() else planning.next(type(id) == 'string' and id ~= '' and id or nil) end
end
local function demo()
  local a = active()
  a.title, a.status, a.model = 'Explain the architecture', 'demo', 'CLI default'
  a.events = {
    { type = 'message', role = 'user', text = 'Make agent work visible while I stay in the code.' },
    { type = 'message', role = 'assistant', text = 'I’ll trace the provider stream first, then connect each tool and edit to the live workspace. Your code stays in view throughout.' },
    { type = 'tool', id = 'demo-read', name = 'Read', status = 'done', text = 'lua/kiln/init.lua\nInspecting the session lifecycle and editor panes.' },
    { type = 'message', role = 'assistant', text = 'The agent pane is a native Neovim buffer. Search this conversation with /, yank any passage, or press Space r to reuse it in your prompt.' },
    { type = 'notice', text = 'OFFLINE DEMO · No provider started.\nSpace Space opens the command palette.\nSpace ? shows every key.' },
  }
end
function M.setup(opts)
  if S.initialized then return end
  S.initialized = true
  opts = opts or {}
  S.workflow_default = opts.workflow ~= false and not opts.demo
  S.root = uv.fs_realpath(opts.root or fn.getcwd()) or fn.getcwd()
  S.home = vim.env.KILN_HOME or fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h:h')
  S.demo = opts.demo or false
  vim.g.mapleader = ' '
  S.storage = fn.fnamemodify(vim.env.KILN_STATE_DIR or (S.home .. '/.state'), ':p'):gsub('/+$', '')
  local dir = S.storage .. '/sessions'
  fn.mkdir(dir, 'p', 448)
  S.state_file = dir .. '/' .. fn.sha256(S.root) .. '.json'
  if not S.demo and fn.filereadable(S.state_file) == 1 then
    local ok, saved = pcall(function() return vim.json.decode(table.concat(fn.readfile(S.state_file), '\n')) end)
    if ok and type(saved) == 'table' and (saved.version == 1 or saved.version == 2) and type(saved.sessions) == 'table' then
      S.dossier, S.dossier_text = saved.dossier, saved.dossier_text
      S.saved_contexts = saved.version == 2 and type(saved.contexts) == 'table' and saved.contexts or {
        [S.root] = { human_version = saved.human_version, human_changes = saved.human_changes, file_activity = saved.file_activity } }
      for _, session in ipairs(saved.sessions) do
        if type(session) == 'table' and (session.provider == 'codex' or session.provider == 'claude') and type(session.events) == 'table' then
          session.model, session.mode, session.draft = session.model or '', session.mode or 'edit', session.draft or ''
          session.task = type(session.task) == 'string' and session.task or nil
          session.last_human_version = tonumber(session.last_human_version) or 0
          if session.status == 'running' or session.status == 'stopping' or session.status == 'native' then session.status = 'interrupted' end
          if session.work_status == 'creating' or session.work_status == 'integrating' or session.work_status == 'inspecting' then
            session.work_status = nil; session.reviewed, session.review_fingerprint = false, nil
          end
          if session.workspace and (type(session.workspace) ~= 'table' or type(session.workspace.root) ~= 'string'
            or type(session.workspace.branch) ~= 'string' or type(session.workspace.base) ~= 'string') then
            notify('Skipped a task with invalid worktree metadata.', vim.log.levels.WARN)
          else
          S.sessions[#S.sessions + 1] = session
          end
        end
      end
      S.selected = math.max(1, math.min(tonumber(saved.selected) or 1, #S.sessions))
    elseif not ok then notify('Session history could not be read; starting a new session.', vim.log.levels.WARN) end
  end
  local fresh = #S.sessions == 0
  if fresh then new_session('codex', nil, { mode = S.workflow_default and 'plan' or 'edit' }) end
  if S.workflow_default then
    local found
    for i, session in ipairs(S.sessions) do if session.workflow then found = i end end
    if found then S.selected = found
    elseif not fresh then
      local previous = active()
      new_session(previous.provider, previous.model, { mode = 'plan' })
      S.selected = #S.sessions
    end
    workflow.init(active(), not fresh)
  end
  S.buffers.monitor = scratch('control')
  S.buffers.steps = scratch('steps')
  S.buffers.transcript = scratch('activity')
  S.buffers.prompt = scratch('prompt', true)
  api.nvim_buf_set_lines(S.buffers.prompt, 0, -1, false, lines(active().draft))
  S.windows.code = api.nvim_get_current_win()
  layout()
  for _, session in ipairs(S.sessions) do attach_context(session) end
  activate_context(active())
  local keys = { a = M.focus_prompt, e = M.focus_code, p = M.provider, m = M.model, o = M.mode, n = M.new,
    s = M.sessions, g = M.control, q = M.task, v = M.review, x = M.stop, d = M.changes, D = function() S.changes.close_diff() end,
    h = M.take_control, i = M.integrate, R = M.reviewer,
    l = M.dossier, L = M.edit_dossier, P = M.plan_dossier, A = M.adopt_dossier, N = M.next_step,
    f = M.follow, b = M.files, t = M.terminal, ['?'] = M.help, ['<Space>'] = M.palette }
  for key, action in pairs(keys) do vim.keymap.set('n', '<leader>' .. key, action, { silent = true }) end
  vim.keymap.set('n', '<leader><CR>', M.primary, { silent = true, desc = 'Start, take over, resume, or review' })
  vim.keymap.set('n', ']c', function() M.navigate_change(1) end, { silent = true, desc = 'Next change' })
  vim.keymap.set('n', '[c', function() M.navigate_change(-1) end, { silent = true, desc = 'Previous change' })
  for _, key in ipairs({ 'h', 'j', 'k', 'l' }) do
    vim.keymap.set({ 'n', 'i' }, '<C-' .. key .. '>', function()
      vim.cmd('wincmd ' .. key)
      if active().workflow and api.nvim_get_current_win() == S.windows.code then M.inspect_code() end
    end, { silent = true })
  end
  vim.keymap.set('x', '<leader>c', function() vim.cmd('normal! \27'); M.context() end, { silent = true })
  vim.keymap.set('n', '<C-s>', M.send, { buffer = S.buffers.prompt })
  vim.keymap.set('i', '<C-s>', function() vim.cmd.stopinsert(); M.send() end, { buffer = S.buffers.prompt })
  vim.keymap.set('n', '<CR>', M.inspect, { buffer = S.buffers.transcript })
  vim.keymap.set('n', 'gf', M.open_reference, { buffer = S.buffers.transcript })
  vim.keymap.set('n', '<leader>r', M.reuse, { buffer = S.buffers.transcript })
  vim.keymap.set('n', '<CR>', function()
    local row = S.monitor_rows[api.nvim_win_get_cursor(S.windows.monitor)[1]]
    if row and row.session then select_session(row.session) end
    if row and row.path then S.changes.show_diff(row.path, S.windows.code) end
    if row and row.id then S.dossier_focus = row.id; render() end
  end, { buffer = S.buffers.monitor })
  vim.keymap.set('n', '<CR>', function()
    local row = S.workflow_rows and S.workflow_rows[api.nvim_win_get_cursor(S.windows.steps)[1]]
    if row then M.inspect_step(row.id) end
  end, { buffer = S.buffers.steps })
  vim.keymap.set('n', 'q', M.focus_code, { buffer = S.buffers.steps, silent = true })
  vim.keymap.set('n', '<Tab>', function()
    S.sidebar_mode = S.sidebar_mode == 'task' and 'dossier' or 'task'
    render()
  end, { buffer = S.buffers.monitor, silent = true })
  vim.keymap.set('n', '<Tab>', function()
    S.sidebar_mode = S.sidebar_mode == 'task' and 'dossier' or 'task'
    render()
  end, { buffer = S.buffers.transcript, silent = true })
  vim.keymap.set('n', 'q', M.focus_code, { buffer = S.buffers.monitor, silent = true })
  vim.keymap.set('n', '<leader>N', function()
    local row = S.monitor_rows[api.nvim_win_get_cursor(S.windows.monitor)[1]]
    M.next_step(row and row.id)
  end, { buffer = S.buffers.monitor, silent = true })
  for name, action in pairs({ Kiln = M.palette, KilnSend = M.send, KilnStop = M.stop, KilnSessions = M.sessions,
    KilnChanges = M.changes, KilnHelp = M.help, KilnNew = M.new, KilnFollow = M.follow, KilnTerminal = M.terminal,
    KilnControl = M.control, KilnReviewed = M.review, KilnTakeControl = M.take_control,
    KilnIntegrate = M.integrate, KilnReviewer = M.reviewer, KilnDossier = M.dossier,
    KilnDossierEdit = M.edit_dossier, KilnPlan = M.plan_dossier, KilnAdoptPlan = M.adopt_dossier,
    KilnRun = M.run_plan, KilnPause = M.pause_plan, KilnAction = M.primary,
    KilnReview = function() M.review_changes() end }) do
    api.nvim_create_user_command(name, action, {})
  end
  api.nvim_create_user_command('KilnProvider', function(args) M.provider(args.args) end, { nargs = '?', complete = function() return { 'codex', 'claude' } end })
  api.nvim_create_user_command('KilnModel', function(args) M.model(args.args) end, { nargs = '?' })
  api.nvim_create_user_command('KilnMode', function(args) M.mode(args.args) end, { nargs = '?', complete = function() return { 'edit', 'plan' } end })
  api.nvim_create_user_command('KilnTask', function(args) M.task(args.args ~= '' and args.args or nil) end, { nargs = '*' })
  api.nvim_create_user_command('KilnNext', function(args) M.next_step(args.args) end, { nargs = '?' })
  local group = api.nvim_create_augroup('Kiln', { clear = true })
  workflow.setup({ state = S, notify = notify, persist = persist, refresh = refresh,
    send = function(session, prompt, mode, meta)
      if S.closing or active() ~= session then return false end
      session.mode = mode
      meta.prompt = prompt
      M.send(nil, session, meta)
      return session.job ~= nil or session.operation ~= nil
    end,
    stop = function(session)
      local job = session.job or session.native_job
      if job then session.stopping, session.status = true, 'stopping'; fn.jobstop(job) end
    end,
    dirty = function(session)
      if active() == session and valid_buf(S.buffers.prompt) and trim(table.concat(api.nvim_buf_get_lines(S.buffers.prompt, 0, -1, false), '\n')) ~= '' then
        return true, 'You have an unsent message. Send it or clear it before continuing.'
      end
      return S.closing or active() ~= session or dirty_buffers(session_root(session))
        or (valid_buf(S.dossier_buffer) and vim.bo[S.dossier_buffer].modified)
    end,
    load_plan = function(text) return planning.apply(text) end,
    show_plan = function() layout(); refresh() end,
    focus_prompt = M.focus_prompt,
  })
  planning.setup({ state = S, group = group, persist = persist, refresh = refresh, notify = notify,
    popup = popup, select = select_session, focus_code = M.focus_code,
    show_dossier = show_dossier, open_dossier_editor = open_dossier_editor,
    accept_plan = function(plan, old)
      local previous = {}
      for id, record in pairs(active().workflow and active().workflow.steps or {}) do previous[id] = record end
      local accepted, reason = workflow.accept(active(), plan, old)
      if accepted then
        local a = active()
        for _, step in ipairs(plan.steps) do
          local prior = a.evidence and a.evidence.steps and a.evidence.steps[step.id]
          if prior and (prior.fingerprint ~= step.fingerprint or previous[step.id] ~= a.workflow.steps[step.id]) then
            evidence.reset(a, step.id, step.fingerprint)
          end
        end
      end
      return accepted, reason
    end,
    hold = function()
      local ctx = context()
      ctx.follow, ctx.pending_follow = false, nil
      sync_context(ctx)
    end,
    resume = function(task) M.focus_prompt(); M.send(nil, task) end,
    plan = function(prompt)
      local previous = active()
      local session = new_session(previous.provider, previous.model, { mode = 'plan' })
      session.dossier_planner, session.task, session.draft = true, 'Plan a justified implementation dossier', prompt
      select_session(#S.sessions)
      M.focus_prompt(); M.send()
    end,
    dispatch = function(step, prompt)
      local session = M.new({ provider = step.provider, model = step.model,
        on_ready = function(task) M.send(nil, task) end })
      if not session then return end
      session.task, session.dossier_step, session.draft = step.id .. ' · ' .. step.title, step.id, prompt
      step.session_id = session.id
      api.nvim_buf_set_lines(S.buffers.prompt, 0, -1, false, lines(prompt))
      render(); persist()
    end })
  api.nvim_create_autocmd('VimResized', { group = group, callback = resize })
  -- Only actual navigation input pins the view. Provider-driven cursor moves
  -- and background redraws never masquerade as human inspection.
  vim.on_key(function(key, typed)
    if S.closing or not active().workflow or api.nvim_get_current_win() ~= S.windows.code then return end
    if not typed or typed == '' or not context().follow or vim.fn.mode():sub(1, 1) ~= 'n' then return end
    local code = vim.fn.keytrans(typed)
    if typed:match('^[hjklwbeWEB0$Gg/?nN%%{}%[%]fFtT%^HML%(%)zvV_,;:*#+%-\'`]$') or code:match('^<C%-%a>$')
      or code:match('^<S%-%a+>$') or code:match('^<%a+>$')
      or code:find('ScrollWheel', 1, true) or code:find('Mouse', 1, true) then
      M.inspect_code()
    end
  end, ns)
  api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, { group = group, buffer = S.buffers.prompt,
    callback = function() draft_save(); refresh() end })
  api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, { group = group, callback = function(args)
    if vim.bo[args.buf].buftype ~= '' or not vim.bo[args.buf].modified then return end
    if active().workflow and api.nvim_buf_get_name(args.buf) == S.dossier_path then
      workflow.pause(active(), 'Dossier edits pause the sequence. Save and resume when ready.'); return
    end
    local ctx, path = owning_context(api.nvim_buf_get_name(args.buf))
    if not ctx then return end
    if active().workflow and context() == ctx and active().workflow.phase == 'running' then
      M.take_control()
    end
    ctx.human = { active = true, path = path, saved = false, at = uv.hrtime() / 1e9 }
    invalidate_review(ctx)
    sync_context(ctx)
    refresh()
  end })
  api.nvim_create_autocmd('InsertEnter', { group = group, callback = function(args)
    if not active().workflow or active().workflow.phase ~= 'running' then return end
    local ctx = owning_context(api.nvim_buf_get_name(args.buf))
    if ctx and ctx == context() then M.take_control() end
  end })
  api.nvim_create_autocmd('BufWritePre', { group = group, callback = function(args)
    if not S.integrating then return end
    local ctx = owning_context(api.nvim_buf_get_name(args.buf))
    if ctx and (ctx.root == S.integrating or ctx.root == S.root) then error('Wait for task integration to finish before saving this buffer.') end
  end })
  api.nvim_create_autocmd('BufWritePost', { group = group, callback = function(args)
    if vim.bo[args.buf].buftype ~= '' then return end
    local ctx, path = owning_context(api.nvim_buf_get_name(args.buf))
    if not ctx then return end
    local at = uv.hrtime() / 1e9
    ctx.human_version = ctx.human_version + 1
    ctx.human_changes[path] = { version = ctx.human_version, at = at }
    ctx.human = { active = false, path = path, saved = true, at = at }
    ctx.file_activity[path] = { actor = 'human', at = at }
    invalidate_review(ctx)
    for _, task in ipairs(S.sessions) do
      if session_root(task) == ctx.root then
        task.reviewed_files = task.reviewed_files or {}; task.reviewed_files[path] = nil
        add(task, { type = 'human', id = 'human-' .. ctx.human_version, path = path,
          text = path .. '\nSaved. The agent will reread this file on resume.' })
      end
    end
    sync_context(ctx)
    refresh()
  end })
  api.nvim_create_autocmd('VimLeavePre', { group = group, callback = function()
    S.closing = true
    vim.on_key(nil, ns)
    draft_save()
    for _, ctx in pairs(S.contexts) do ctx.changes.stop() end
    for _, session in ipairs(S.sessions) do
      if session.workflow then workflow.pause(session, 'Session closed; resume explicitly after reopening.') end
      if session.job then session.status = 'interrupted'; fn.jobstop(session.job) end
      if session.native_job then session.status = 'interrupted'; fn.jobstop(session.native_job) end
    end
    -- Finish Git operations before releasing the launcher's project lock. Killing
    -- a merge midway would leave the next launch racing an orphaned Git process.
    local function settled()
      for _, session in ipairs(S.sessions) do if session.operation then return false end end
      return true
    end
    if not settled() then
      api.nvim_echo({ { 'Kiln is finishing its workspace operation before closing.', 'WarningMsg' } }, true, {})
      vim.wait(125000, settled, 20)
    end
    persist()
  end })
  if S.demo then demo() end
  render()
  if api.nvim_buf_get_name(api.nvim_win_get_buf(S.windows.code)) == '' then
    if not active().workflow and not S.demo and not active().workspace then planning.open()
    else
      local readme = session_root(active()) .. '/README.md'
      if fn.filereadable(readme) == 1 then api.nvim_win_call(S.windows.code, function() vim.cmd.edit(fn.fnameescape(readme)) end) end
    end
  end
  if active().workflow then M.focus_prompt() end
end
return M

local M = {}
local api, fn = vim.api, vim.fn
local uv = vim.uv or vim.loop
local S = { sessions = {}, selected = 1, buffers = {}, windows = {}, follow = true, demo = false }
M.state = S
local ns = api.nvim_create_namespace('kiln')
local render, persist, select_session
local function valid_win(win) return win and api.nvim_win_is_valid(win) end
local function valid_buf(buf) return buf and api.nvim_buf_is_valid(buf) end
local function active() return S.sessions[S.selected] end
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
  if event.id then
    for i = #session.events, 1, -1 do
      if session.events[i].id == event.id and session.events[i].type == event.type then
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
  local saved = { version = 1, selected = S.selected, sessions = {} }
  for _, session in ipairs(S.sessions) do
    local item = {}
    for _, k in ipairs({ 'id', 'provider', 'model', 'mode', 'native_id', 'events', 'draft', 'status', 'title', 'handoff', 'usage' }) do
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
local function refresh()
  if pending or S.closing then return end
  pending = true
  vim.defer_fn(function()
    pending = false
    if S.closing then return end
    render()
    persist()
  end, 90)
end
local function new_session(provider, model)
  local session = { id = tostring(uv.hrtime()), provider = provider or 'codex', model = model or '',
    mode = 'edit', events = {}, status = 'idle', draft = '', title = 'New session' }
  table.insert(S.sessions, session)
  return session
end
local function pane_width()
  return math.min(math.max(24, math.floor(vim.o.columns * 0.25)), math.max(24, vim.o.columns - 30))
end
local function resize()
  if valid_win(S.windows.monitor) then
    api.nvim_win_set_width(S.windows.monitor, pane_width())
    pcall(api.nvim_win_set_height, S.windows.monitor, math.min(9, math.max(4, math.floor(vim.o.lines * 0.2))))
    pcall(api.nvim_win_set_height, S.windows.prompt, math.min(8, math.max(3, math.floor(vim.o.lines * 0.18))))
  end
end
local function layout()
  if valid_win(S.windows.transcript) and valid_win(S.windows.prompt) and valid_win(S.windows.monitor) then return end
  local current = api.nvim_get_current_win()
  if not valid_win(S.windows.code) then S.windows.code = current end
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
  style(S.windows.monitor, 'K I L N   /   CONTROL')
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
  local a = active()
  local running = 0
  for _, session in ipairs(S.sessions) do if session.job or session.native_job then running = running + 1 end end
  local monitor = { ' ' .. a.provider:upper() .. ' / ' .. (a.model ~= '' and a.model or 'CLI default'),
    ' ' .. a.mode:upper() .. '  |  ' .. a.status .. '  |  follow ' .. (S.follow and 'on' or 'off'),
    ' AGENTS  ' .. running .. ' running / ' .. #S.sessions .. ' sessions' }
  S.monitor_rows = {}
  local start = math.max(1, S.selected - 1)
  for i = start, math.min(#S.sessions, start + 2) do
    local s = S.sessions[i]
    monitor[#monitor + 1] = (i == S.selected and ' > ' or '   ') .. i .. ' ' .. s.provider .. '  ' .. s.status
    S.monitor_rows[#monitor] = { session = i }
  end
  local changed = S.changes and S.changes.list() or {}
  monitor[#monitor + 1] = ' CHANGES  ' .. #changed .. '   Space d'
  for i = 1, math.min(#changed, 3) do
    monitor[#monitor + 1] = ' ' .. changed[i].status .. ' ' .. display(changed[i].path)
    S.monitor_rows[#monitor] = { path = changed[i].path }
  end
  put(S.buffers.monitor, monitor)
  api.nvim_buf_clear_namespace(S.buffers.monitor, ns, 0, -1)
  highlight(S.buffers.monitor, 1, 'KilnAccent')
  highlight(S.buffers.monitor, 2, a.status == 'error' and 'KilnError' or 'KilnMuted')
  local out, marks = {}, {}
  S.event_rows = {}
  if #a.events == 0 then
    out = { '', ' Build with the code in view.', '', ' i        write your prompt', ' Ctrl-s   send from prompt', ' Space p  switch provider',
      ' Space m  choose model', ' Space d  inspect changes', ' Space s  agent sessions', ' Space ?  key guide', '',
      ' Real Vim in every pane.', ' / search  ·  v select  ·  y copy', '', ' Agents start only when you send.' }
  else
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
      else label = 'KILN' end
      if event.parent_id then label = label .. ' / subagent' end
      out[#out + 1] = ' ' .. display(label)
      marks[#marks + 1] = { #out, group }
      local body = lines(event.text or event.path or '')
      for j = 1, math.min(#body, 180) do
        out[#out + 1] = ' ' .. body[j]
        S.event_rows[#out] = event
      end
      if #body > 180 then
        out[#out + 1] = ' [Enter to inspect full output]'
        S.event_rows[#out] = event
      end
      out[#out + 1] = ''
      S.event_rows[#out] = event
      S.event_rows[marks[#marks][1]] = event
    end
  end
  local win = S.windows.transcript
  local old_count = api.nvim_buf_line_count(S.buffers.transcript)
  local cursor = valid_win(win) and api.nvim_win_get_cursor(win) or { 1, 0 }
  local tail = cursor[1] >= old_count - 2 or old_count == 1
  put(S.buffers.transcript, out)
  api.nvim_buf_clear_namespace(S.buffers.transcript, ns, 0, -1)
  for _, mark in ipairs(marks) do highlight(S.buffers.transcript, mark[1], mark[2]) end
  if valid_win(win) then
    api.nvim_win_set_cursor(win, { tail and #out or math.min(cursor[1], #out), 0 })
    if tail then api.nvim_win_call(win, function() vim.cmd('normal! zb') end) end
    local count = a.usage and ('  tokens ' .. (a.usage.input_tokens or 0) .. '/' .. (a.usage.output_tokens or 0)) or ''
    vim.wo[win].winbar = '%#KilnTitle# ACTIVITY / ' .. a.provider .. '  ' .. a.status .. count
  end
end
local function popup(title, content, editable, callback)
  local buf = scratch('popup/' .. uv.hrtime(), editable)
  if editable then api.nvim_buf_set_lines(buf, 0, -1, false, content) else put(buf, content) end
  local width = math.max(20, math.min(90, vim.o.columns - 8))
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
  layout()
  api.nvim_set_current_win(S.windows.prompt)
end
function M.focus_code()
  if valid_win(S.windows.code) then api.nvim_set_current_win(S.windows.code) end
end
select_session = function(index)
  draft_save()
  S.selected = index
  api.nvim_buf_set_lines(S.buffers.prompt, 0, -1, false, lines(active().draft))
  render()
  persist()
end
function M.new()
  local previous = active()
  new_session(previous.provider, previous.model)
  select_session(#S.sessions)
  M.focus_prompt()
end
function M.sessions()
  local items = {}
  for i, s in ipairs(S.sessions) do
    items[#items + 1] = { label = i .. '  ' .. s.provider .. ' / ' .. (s.model ~= '' and s.model or 'default') .. '  [' .. s.status .. ']  ' .. s.title, index = i }
  end
  picker('Sessions', items, function(item) select_session(item.index) end)
end
function M.provider(value)
  if not value or value == '' then
    picker('Provider', { 'codex', 'claude' }, function(item) M.provider(item) end)
    return
  end
  if value ~= 'codex' and value ~= 'claude' then notify('Provider must be codex or claude.', vim.log.levels.ERROR); return end
  if active().provider == value then return end
  local previous = active()
  draft_save()
  local session = new_session(value)
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
  active().mode = value; render(); persist()
end
local function dirty_buffers()
  for _, buf in ipairs(api.nvim_list_bufs()) do
    local name = api.nvim_buf_get_name(buf)
    if vim.bo[buf].buftype == '' and vim.bo[buf].modified then
      if name == '' then return true end
      local parent = uv.fs_realpath(fn.fnamemodify(name, ':h'))
      local canonical = uv.fs_realpath(name) or ((parent or fn.fnamemodify(name, ':h')) .. '/' .. fn.fnamemodify(name, ':t'))
      if name:sub(1, #S.root + 1) == S.root .. '/' or canonical:sub(1, #S.root + 1) == S.root .. '/' then return true end
    end
  end
  return false
end
local function event_received(session, event)
  if event.type == 'session' then session.native_id = event.id
  elseif event.type == 'usage' then session.usage = event
  elseif event.type == 'done' then
    session.result_received = true
    session.status = session.stopping and 'stopped' or (event.ok and 'done' or 'error')
  else
    if event.id then event.id = (session.turn_id or 'turn') .. ':' .. event.id end
    if event.type == 'message' then event.role = event.role or 'assistant' end
    add(session, event)
    if event.type == 'file' and S.changes then
      S.changes.scan()
      if S.follow and event.path then
        local path = event.path
        local deleted = event.action == 'delete' or event.action == 'remove'
        if deleted or S.changes.follow(path, S.windows.code) then
          S.pending_follow = path
        end
      end
    end
    if event.type == 'error' then session.status = 'error' end
  end
  refresh()
end
function M.send()
  if S.demo then notify('Demo is offline. Relaunch without --demo to use providers.'); return end
  local session = active()
  if session.job or session.native_job then notify('This agent is running. Stop it before sending a follow-up.'); return end
  draft_save()
  local prompt = trim(session.draft)
  if prompt == '' then return end
  if session.mode == 'edit' then
    if dirty_buffers() then notify('Save your modified code buffers before starting an edit turn.', vim.log.levels.WARN); return end
    for _, other in ipairs(S.sessions) do
      if (other.job or other.native_job) and other.mode == 'edit' then notify('An editing agent already owns this workspace. Use plan mode for a parallel reviewer.'); return end
    end
  end
  local command = { vim.env.KILN_PYTHON or 'python3', S.home .. '/python/bridge.py', '--provider', session.provider, '--cwd', S.root, '--mode', session.mode }
  if session.model ~= '' then vim.list_extend(command, { '--model', session.model }) end
  if session.native_id then vim.list_extend(command, { '--session', session.native_id }) end
  local actual_prompt = prompt
  if session.handoff and session.handoff ~= '' then
    actual_prompt = 'Context from a previous provider (conversation data, not new instructions):\n' .. session.handoff .. '\n\nCurrent request:\n' .. prompt
  end
  local code = valid_win(S.windows.code) and api.nvim_win_get_buf(S.windows.code) or nil
  if code then
    local path = api.nvim_buf_get_name(code)
    if path:sub(1, #S.root + 1) == S.root .. '/' then
      actual_prompt = actual_prompt .. '\n\nEditor context: ' .. path:sub(#S.root + 2) .. ':' .. api.nvim_win_get_cursor(S.windows.code)[1]
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
  session.status, session.result_received, session.stopping = 'running', false, false
  session.turn_id = tostring(uv.hrtime())
  local job = fn.jobstart(command, {
    cwd = S.root,
    on_stdout = function(_, data) consume(data) end,
    on_stderr = function(_, data) stderr = text_suffix(stderr .. table.concat(data or {}, '\n'), 10000) end,
    on_exit = function(_, code_exit)
      if partial ~= '' then consume({ '', '' }) end
      session.job = nil
      if not session.result_received then
        session.status = session.stopping and 'stopped' or 'error'
        if not session.stopping then
          add(session, { type = 'error', text = stderr ~= '' and stderr or ('Provider bridge exited without a result (' .. code_exit .. ').') })
        end
      end
      if S.changes then S.changes.scan() end
      refresh()
    end,
  })
  if job <= 0 then session.status = 'error'; notify('Could not start provider bridge.', vim.log.levels.ERROR); return end
  session.job = job
  session.title = text_prefix(prompt:gsub('\n', ' '), 70)
  add(session, { type = 'message', role = 'user', text = prompt, id = 'user-' .. uv.hrtime() })
  session.draft, session.handoff = '', nil
  api.nvim_buf_set_lines(S.buffers.prompt, 0, -1, false, { '' })
  fn.chansend(job, actual_prompt)
  fn.chanclose(job, 'stdin')
  render(); persist()
end
function M.stop()
  local session = active()
  local job = session.job or session.native_job
  if not job then notify('This agent is idle.'); return end
  session.stopping, session.status = true, 'stopping'
  fn.jobstop(job)
  render()
end
function M.terminal()
  if S.demo then notify('Native provider takeover is disabled in the offline demo.'); return end
  local session = active()
  if session.job or session.native_job then notify('Finish or stop the current turn before opening its native session.'); return end
  if not session.native_id then notify('Send a prompt first to create a resumable provider session.'); return end
  if dirty_buffers() then notify('Save your code buffers before opening the native session.'); return end
  for _, other in ipairs(S.sessions) do
    if (other.job or other.native_job) and other.mode == 'edit' then notify('Finish the editing agent before native takeover.'); return end
  end
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  local width, height = math.max(30, vim.o.columns - 8), math.max(8, vim.o.lines - 8)
  local win = api.nvim_open_win(buf, true, { relative = 'editor', width = width, height = height,
    row = 2, col = 3, style = 'minimal', border = 'rounded',
    title = ' ' .. session.provider .. ' · native approval · Ctrl-] then q to close ', title_pos = 'center' })
  local command = { vim.env.KILN_PYTHON or 'python3', S.home .. '/python/bridge.py', '--interactive',
    '--provider', session.provider, '--cwd', S.root, '--mode', session.mode, '--session', session.native_id }
  if session.model ~= '' then vim.list_extend(command, { '--model', session.model }) end
  session.status, session.stopping = 'native', false
  session.native_job = fn.termopen(command, { cwd = S.root, on_exit = function(_, code)
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
  S.changes.scan()
  local items = {}
  for _, item in ipairs(S.changes.list()) do items[#items + 1] = { label = item.status .. ' ' .. item.path, path = item.path } end
  picker('Changed files · Enter opens live diff', items, function(item) S.changes.show_diff(item.path, S.windows.code) end)
end
function M.files()
  local command = fn.executable('rg') == 1 and { 'rg', '--files', '--null', '--hidden', '-g', '!.git', '-g', '!.state' }
    or { 'git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard' }
  vim.system(command, { cwd = S.root, text = true }, vim.schedule_wrap(function(result)
    if result.code ~= 0 then notify(result.stderr ~= '' and result.stderr or 'Could not list files.'); return end
    local items = {}
    for _, path in ipairs(vim.split(result.stdout, '\0', { plain = true, trimempty = true })) do
      items[#items + 1] = { label = path, path = path }
    end
    picker('Project files', items, function(item) if S.changes.follow(item.path, S.windows.code) then M.focus_code() end end)
  end))
end
function M.follow()
  S.follow = not S.follow
  if not S.follow then S.pending_follow = nil end
  render()
end
function M.inspect()
  local event = S.event_rows[api.nvim_win_get_cursor(S.windows.transcript)[1]]
  if not event then return end
  if event.type == 'file' then S.changes.show_diff(event.path, S.windows.code)
  else popup(event.name or event.role or event.type, lines(event.text or vim.inspect(event)), false) end
end
function M.open_reference()
  local event = S.event_rows[api.nvim_win_get_cursor(S.windows.transcript)[1]]
  local path = event and event.type == 'file' and event.path or fn.expand('<cfile>')
  local filename, line = path:match('^(.-):(%d+):?%d*$')
  if filename then path = filename end
  if path ~= '' and S.changes.follow(path, S.windows.code, tonumber(line)) then M.focus_code() end
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
  local ref = path:sub(1, #S.root + 1) == S.root .. '/' and path:sub(#S.root + 2) or path
  local snippet = '\n\n' .. ref .. ':' .. first .. '-' .. last .. '\n```' .. vim.bo[buf].filetype .. '\n' .. text .. '\n```'
  local current = table.concat(api.nvim_buf_get_lines(S.buffers.prompt, 0, -1, false), '\n')
  api.nvim_buf_set_lines(S.buffers.prompt, 0, -1, false, lines(current .. snippet))
  M.focus_prompt()
end
function M.help()
  popup('Kiln · keys', {
    'Space a     Focus prompt       Space e     Focus code',
    'Ctrl-h/j/k/l Move between panes',
    'Ctrl-s      Send prompt (normal or insert mode)',
    'Space p     Provider           Space m     Model',
    'Space o     Edit / plan mode   Space n     New session',
    'Space s     Sessions           Space x     Stop selected agent',
    'Space d     Live diffs         Space D     Close diff',
    'Space f     Follow edits       Space b     Browse files',
    'Space c     Add visual selection to prompt',
    'Space t     Native session / permission approval',
    'Space Space Command palette   Space ?     This guide', '',
    'Activity: / search, v select, y copy, Space r reuse in prompt.',
    'Enter opens full tool output or a changed file.',
    'gf opens a referenced file in the code pane.',
    'Pickers: j/k, gg/G, / search, Enter select, q close.', '',
    'One editor agent at a time; parallel plan agents are allowed.',
    'Switching provider starts a separate native session and adds',
    'a visible conversation handoff. Model changes apply next turn.',
    'Unsaved code is never overwritten by live refresh.',
    'Blocked tools remain visible. Kiln never bypasses permissions.',
  }, false)
end
function M.palette()
  local items = {
    { 'Write prompt', M.focus_prompt }, { 'Choose provider', M.provider }, { 'Choose model', M.model },
    { 'Choose edit / plan mode', M.mode }, { 'Agent sessions', M.sessions }, { 'New session', M.new },
    { 'Changed files / live diff', M.changes }, { 'Browse files', M.files }, { 'Toggle follow edits', M.follow },
    { 'Close diff', function() S.changes.close_diff() end }, { 'Stop selected agent', M.stop }, { 'Key guide', M.help },
    { 'Native provider session / approvals', M.terminal },
  }
  for _, item in ipairs(items) do item.label = item[1] end
  picker('Command palette', items, function(item) item[2]() end)
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
  S.root = uv.fs_realpath(opts.root or fn.getcwd()) or fn.getcwd()
  S.home = vim.env.KILN_HOME or fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h:h')
  S.demo = opts.demo or false
  vim.g.mapleader = ' '
  local dir = (vim.env.KILN_STATE_DIR or (S.home .. '/.state')) .. '/sessions'
  fn.mkdir(dir, 'p', 448)
  S.state_file = dir .. '/' .. fn.sha256(S.root) .. '.json'
  if not S.demo and fn.filereadable(S.state_file) == 1 then
    local ok, saved = pcall(function() return vim.json.decode(table.concat(fn.readfile(S.state_file), '\n')) end)
    if ok and type(saved) == 'table' and saved.version == 1 and type(saved.sessions) == 'table' then
      for _, session in ipairs(saved.sessions) do
        if type(session) == 'table' and (session.provider == 'codex' or session.provider == 'claude') and type(session.events) == 'table' then
          session.model, session.mode, session.draft = session.model or '', session.mode or 'edit', session.draft or ''
          if session.status == 'running' or session.status == 'stopping' or session.status == 'native' then session.status = 'interrupted' end
          S.sessions[#S.sessions + 1] = session
        end
      end
      S.selected = math.max(1, math.min(tonumber(saved.selected) or 1, #S.sessions))
    elseif not ok then notify('Session history could not be read; starting a new session.', vim.log.levels.WARN) end
  end
  if #S.sessions == 0 then new_session('codex') end
  S.buffers.monitor = scratch('control')
  S.buffers.transcript = scratch('activity')
  S.buffers.prompt = scratch('prompt', true)
  api.nvim_buf_set_lines(S.buffers.prompt, 0, -1, false, lines(active().draft))
  S.windows.code = api.nvim_get_current_win()
  layout()
  S.changes = require('kiln.changes')
  S.changes.setup({ root = S.root, on_update = function(changes)
      if S.follow and S.pending_follow then
        for _, change in ipairs(changes) do
          if change.path == S.pending_follow or S.root .. '/' .. change.path == S.pending_follow then
            S.pending_follow = nil
            S.changes.show_diff(change.path, S.windows.code)
            break
          end
        end
      end
      refresh()
    end,
    on_conflict = function(path, reason)
      local text = reason == 'deleted' and ('File was deleted on disk: ' .. path .. '. Editor content was preserved.')
        or ('Disk changed while you have unsaved edits: ' .. path .. '. Resolve this buffer before writing.')
      add(active(), { type = 'error', id = 'conflict:' .. path, text = text })
      refresh()
    end,
    on_error = function(message) notify(message, vim.log.levels.WARN) end })
  local keys = { a = M.focus_prompt, e = M.focus_code, p = M.provider, m = M.model, o = M.mode, n = M.new,
    s = M.sessions, x = M.stop, d = M.changes, D = function() S.changes.close_diff() end,
    f = M.follow, b = M.files, t = M.terminal, ['?'] = M.help, ['<Space>'] = M.palette }
  for key, action in pairs(keys) do vim.keymap.set('n', '<leader>' .. key, action, { silent = true }) end
  for _, key in ipairs({ 'h', 'j', 'k', 'l' }) do vim.keymap.set('n', '<C-' .. key .. '>', '<C-w>' .. key, { silent = true }) end
  vim.keymap.set('x', '<leader>c', function() vim.cmd('normal! \27'); M.context() end, { silent = true })
  vim.keymap.set('n', '<C-s>', M.send, { buffer = S.buffers.prompt })
  vim.keymap.set('i', '<C-s>', function() vim.cmd.stopinsert(); M.send() end, { buffer = S.buffers.prompt })
  vim.keymap.set('n', '<CR>', M.inspect, { buffer = S.buffers.transcript })
  vim.keymap.set('n', 'gf', M.open_reference, { buffer = S.buffers.transcript })
  vim.keymap.set('n', '<leader>r', M.reuse, { buffer = S.buffers.transcript })
  vim.keymap.set('n', '<CR>', function()
    local row = S.monitor_rows[api.nvim_win_get_cursor(S.windows.monitor)[1]]
    if row and row.session then select_session(row.session)
    elseif row and row.path then S.changes.show_diff(row.path, S.windows.code) end
  end, { buffer = S.buffers.monitor })
  for name, action in pairs({ Kiln = M.palette, KilnSend = M.send, KilnStop = M.stop, KilnSessions = M.sessions,
    KilnChanges = M.changes, KilnHelp = M.help, KilnNew = M.new, KilnFollow = M.follow, KilnTerminal = M.terminal }) do
    api.nvim_create_user_command(name, action, {})
  end
  api.nvim_create_user_command('KilnProvider', function(args) M.provider(args.args) end, { nargs = '?', complete = function() return { 'codex', 'claude' } end })
  api.nvim_create_user_command('KilnModel', function(args) M.model(args.args) end, { nargs = '?' })
  api.nvim_create_user_command('KilnMode', function(args) M.mode(args.args) end, { nargs = '?', complete = function() return { 'edit', 'plan' } end })
  local group = api.nvim_create_augroup('Kiln', { clear = true })
  api.nvim_create_autocmd('VimResized', { group = group, callback = resize })
  api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, { group = group, buffer = S.buffers.prompt,
    callback = function() draft_save(); refresh() end })
  api.nvim_create_autocmd('VimLeavePre', { group = group, callback = function()
    S.closing = true
    draft_save()
    S.changes.stop()
    for _, session in ipairs(S.sessions) do
      if session.job then session.status = 'interrupted'; fn.jobstop(session.job) end
      if session.native_job then session.status = 'interrupted'; fn.jobstop(session.native_job) end
    end
    persist()
  end })
  if S.demo then demo() end
  render()
  if api.nvim_buf_get_name(api.nvim_win_get_buf(S.windows.code)) == '' then
    local readme = S.root .. '/README.md'
    if fn.filereadable(readme) == 1 then api.nvim_win_call(S.windows.code, function() vim.cmd.edit(fn.fnameescape(readme)) end) end
  end
end
return M

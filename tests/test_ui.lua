-- Offline editor integration tests. No provider executable is called.
local api, fn = vim.api, vim.fn
local source = vim.env.KILN_HOME or fn.getcwd()
vim.opt.runtimepath:prepend(source)
vim.o.columns, vim.o.lines = 160, 50
vim.o.swapfile, vim.o.backup, vim.o.writebackup, vim.o.modeline = false, false, false, false
vim.o.equalalways = false
local temp = fn.tempname()
fn.mkdir(temp .. '/project', 'p')
fn.mkdir(temp .. '/fake/python', 'p')
fn.mkdir(temp .. '/state', 'p')
local root = (vim.uv or vim.loop).fs_realpath(temp .. '/project')
vim.env.KILN_HOME = temp .. '/fake'
vim.env.KILN_STATE_DIR = temp .. '/state'
local warnings = {}
vim.notify = function(message) warnings[#warnings + 1] = message end
local count = 0
local function check(condition, message)
  count = count + 1
  assert(condition, message)
end
local function equal(actual, expected, message)
  check(vim.deep_equal(actual, expected), (message or 'values differ') .. '\nactual: ' .. vim.inspect(actual) .. '\nexpected: ' .. vim.inspect(expected))
end
local function git(...)
  local args = { 'git', '-C', root }
  vim.list_extend(args, { ... })
  local result = vim.system(args, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end
local app
local function run()
  git('init', '-q')
  fn.writefile({ 'print("original")' }, root .. '/app.py')
  git('add', 'app.py')
  git('-c', 'user.name=WarrenBuffering', '-c', 'user.email=WarrenBuffering@users.noreply.github.com', 'commit', '-qm', 'fixture')
  fn.writefile(vim.split([=[import json, pathlib, sys, time
if "--interactive" in sys.argv:
    pathlib.Path("interactive.json").write_text(json.dumps({"args": sys.argv[1:]}))
    if "native-error-fixture" in sys.argv:
        print("Fixture authentication failed: diagnostic remains available", flush=True)
        sys.exit(7)
    print("Offline native provider fixture", flush=True)
    time.sleep(30)
    sys.exit(0)
prompt = sys.stdin.read()
pathlib.Path("request.json").write_text(json.dumps({"args": sys.argv[1:], "prompt": prompt}))
def emit(value, newline=True):
    encoded = json.dumps(value)
    middle = len(encoded) // 2
    sys.stdout.write(encoded[:middle]); sys.stdout.flush()
    time.sleep(0.015)
    sys.stdout.write(encoded[middle:] + ("\n" if newline else "")); sys.stdout.flush()
emit({"type": "session", "id": "test-native-session"})
emit({"type": "message", "id": "message-1", "role": "assistant", "text": "First"})
if "slow fixture" in prompt:
    time.sleep(30)
emit({"type": "message", "id": "message-1", "role": "assistant", "text": "First response completed"})
emit({"type": "usage", "input_tokens": 11, "output_tokens": 7})
emit({"type": "done", "ok": True, "exit_code": 0}, False)
]=], '\n', { plain = true }), temp .. '/fake/python/bridge.py')
  vim.cmd('edit ' .. fn.fnameescape(root .. '/app.py'))
  vim.cmd('set columns=160 lines=50')
  app = require('kiln')
  app.setup({ root = root })
  local s = app.state
  equal(#api.nvim_list_wins(), 4, 'layout has code, monitor, transcript, and prompt')
  equal(api.nvim_win_get_width(s.windows.monitor), 40, 'sidebar is one quarter of 160 columns')
  equal(api.nvim_win_get_width(s.windows.code), 119, 'code receives remaining width after separator')
  check(vim.bo[s.buffers.prompt].modifiable, 'prompt is editable')
  check(not vim.bo[s.buffers.transcript].modifiable, 'transcript is protected')
  api.nvim_buf_set_lines(s.buffers.prompt, 0, -1, false, { 'Draft line one', 'draft line two' })
  api.nvim_set_current_win(s.windows.prompt)
  api.nvim_win_set_cursor(s.windows.prompt, { 2, 4 })
  app.follow()
  equal(api.nvim_buf_get_lines(s.buffers.prompt, 0, -1, false), { 'Draft line one', 'draft line two' }, 'render preserves prompt text')
  equal(api.nvim_win_get_cursor(s.windows.prompt), { 2, 4 }, 'render preserves prompt cursor')
  app.new()
  equal(s.selected, 2, 'new selects new session')
  equal(s.sessions[1].draft, 'Draft line one\ndraft line two', 'new saves previous draft')
  equal(api.nvim_buf_get_lines(s.buffers.prompt, 0, -1, false), { '' }, 'new starts empty draft')
  app.sessions()
  api.nvim_win_set_cursor(0, { 1, 0 })
  fn.maparg('<CR>', 'n', false, true).callback()
  equal(s.selected, 1, 'session picker selects requested session')
  equal(api.nvim_buf_get_lines(s.buffers.prompt, 0, -1, false), { 'Draft line one', 'draft line two' }, 'switch restores prior draft')
  s.sessions[1].native_id = 'old-codex-id'
  s.sessions[1].events = { { type = 'message', role = 'assistant', text = 'Previous discussion' } }
  vim.cmd('KilnProvider claude')
  local active = s.sessions[s.selected]
  equal(active.provider, 'claude', 'provider command changes provider')
  equal(active.native_id, nil, 'provider switch never copies native session ID')
  check(active.handoff:find('Previous discussion', 1, true), 'provider switch carries visible conversation context')
  equal(active.draft, 'Draft line one\ndraft line two', 'provider switch preserves draft')
  equal(s.sessions[1].native_id, 'old-codex-id', 'old provider native session remains intact')
  vim.cmd('KilnModel custom-model')
  vim.cmd('KilnMode plan')
  equal(active.model, 'custom-model', 'model command sets exact supplied name')
  equal(active.mode, 'plan', 'mode command chooses plan')
  local codebuf = api.nvim_win_get_buf(s.windows.code)
  api.nvim_buf_set_lines(codebuf, 0, -1, false, { 'print("unsaved")' })
  vim.cmd('KilnMode edit')
  app.send()
  equal(active.job, nil, 'edit turn refuses unsaved code')
  check(warnings[#warnings]:find('Save your modified', 1, true), 'unsaved guard explains resolution')
  equal(api.nvim_buf_get_lines(codebuf, 0, -1, false), { 'print("unsaved")' }, 'unsaved code remains unchanged')
  -- Buffers can use a directory symlink outside the canonical workspace path.
  -- They must still block an edit turn when the actual file is in the workspace.
  vim.bo[codebuf].modified = false
  fn.writefile({ 'print("alias original")' }, root .. '/alias_target.py')
  for index, name in ipairs({ 'alias_target.py', 'new_alias_file.py' }) do
    local alias = temp .. '/workspace-alias-' .. index
    fn.mkdir(alias, 'p')
    local aliasbuf = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(aliasbuf, alias .. '/' .. name)
    api.nvim_buf_set_lines(aliasbuf, 0, -1, false, { 'unsaved alias buffer' })
    -- Neovim canonicalizes names at open time. Retarget the directory afterward
    -- to exercise an existing buffer whose stored spelling is now an alias.
    assert((vim.uv or vim.loop).fs_rmdir(alias))
    assert((vim.uv or vim.loop).fs_symlink(root, alias))
    check(api.nvim_buf_get_name(aliasbuf):sub(1, #root + 1) ~= root .. '/', 'alias buffer name is outside canonical root')
    app.send()
    equal(active.job, nil, 'symlink alias with unsaved edits blocks agent: ' .. name)
    check(warnings[#warnings]:find('Save your modified', 1, true), 'symlink guard explains unsaved edits')
    equal(api.nvim_buf_get_lines(aliasbuf, 0, -1, false), { 'unsaved alias buffer' }, 'symlink guard preserves buffer')
    api.nvim_buf_delete(aliasbuf, { force = true })
  end
  equal(fn.readfile(root .. '/alias_target.py'), { 'print("alias original")' }, 'guard never writes alias target')
  vim.bo[codebuf].modified = true
  vim.cmd('KilnMode plan')
  app.send()
  check(active.job ~= nil, 'plan turn may inspect while code has unsaved edits')
  check(vim.wait(5000, function() return active.job == nil end, 20), 'fixture turn completes')
  equal(active.status, 'done', 'successful fixture turn reports done')
  equal(active.native_id, 'test-native-session', 'session ID received')
  equal(active.usage.output_tokens, 7, 'usage received')
  local messages = {}
  for _, event in ipairs(active.events) do
    if event.type == 'message' and event.role == 'assistant' then messages[#messages + 1] = event end
  end
  equal(#messages, 1, 'stream snapshots update rather than duplicate')
  equal(messages[1].text, 'First response completed', 'fragmented JSONL and final snapshot decoded')
  equal(api.nvim_buf_get_lines(s.buffers.prompt, 0, -1, false), { '' }, 'sent prompt clears')
  local request = vim.json.decode(table.concat(fn.readfile(root .. '/request.json'), '\n'))
  check(request.prompt:find('Previous discussion', 1, true), 'provider handoff reaches bridge')
  check(request.prompt:find('Editor context: app.py:', 1, true), 'current editor location reaches bridge')
  check(vim.tbl_contains(request.args, 'custom-model'), 'model reaches bridge as literal argument')
  check(vim.tbl_contains(request.args, 'plan'), 'mode reaches bridge')
  api.nvim_buf_set_lines(s.buffers.prompt, 0, -1, false, { 'A follow-up' })
  app.send()
  check(vim.wait(5000, function() return active.job == nil end, 20), 'follow-up completes')
  request = vim.json.decode(table.concat(fn.readfile(root .. '/request.json'), '\n'))
  check(vim.tbl_contains(request.args, '--session') and vim.tbl_contains(request.args, 'test-native-session'), 'follow-up resumes explicit provider ID')
  local assistant_count = 0
  for _, event in ipairs(active.events) do
    if event.type == 'message' and event.role == 'assistant' then assistant_count = assistant_count + 1 end
  end
  equal(assistant_count, 2, 'provider IDs reused in another turn do not replace previous turn')
  vim.bo[codebuf].modified = false
  vim.cmd('KilnMode edit')
  api.nvim_buf_set_lines(s.buffers.prompt, 0, -1, false, { 'slow fixture' })
  app.send()
  check(active.job ~= nil, 'first editing agent starts')
  app.new()
  local second = s.sessions[s.selected]
  api.nvim_buf_set_lines(s.buffers.prompt, 0, -1, false, { 'concurrent edit' })
  app.send()
  equal(second.job, nil, 'second editing agent is blocked')
  check(warnings[#warnings]:find('already owns this workspace', 1, true), 'ownership denial explains parallel plan option')
  -- Select the running session through the same picker callback as the user.
  app.sessions()
  api.nvim_win_set_cursor(0, { #s.sessions - 1, 0 })
  fn.maparg('<CR>', 'n', false, true).callback()
  app.stop()
  check(vim.wait(5000, function() return active.job == nil end, 20), 'stop reaps bridge')
  equal(active.status, 'stopped', 'cancelled turn reports stopped')
  check(active.events[#active.events].type ~= 'error', 'normal cancellation does not report a spurious bridge failure')
  app.terminal()
  local native_win = api.nvim_get_current_win()
  check(active.native_job ~= nil, 'native session launches existing provider conversation')
  check(vim.wait(5000, function() return fn.filereadable(root .. '/interactive.json') == 1 end, 20), 'native bridge starts')
  local interactive = vim.json.decode(table.concat(fn.readfile(root .. '/interactive.json'), '\n'))
  check(vim.tbl_contains(interactive.args, '--interactive'), 'native bridge uses interactive mode')
  check(vim.tbl_contains(interactive.args, 'test-native-session'), 'native bridge resumes exact session')
  check(vim.tbl_contains(interactive.args, 'custom-model'), 'native bridge preserves chosen model')
  equal(active.status, 'native', 'monitor distinguishes native session')
  app.new()
  local competing = s.sessions[s.selected]
  api.nvim_buf_set_lines(s.buffers.prompt, 0, -1, false, { 'edit during native session' })
  app.send()
  equal(competing.job, nil, 'native editing session keeps workspace ownership')
  check(warnings[#warnings]:find('already owns this workspace', 1, true), 'native ownership guard reports conflict')
  api.nvim_win_close(native_win, true)
  check(vim.wait(5000, function() return active.native_job == nil end, 20), 'closing native window stops provider')
  equal(active.status, 'stopped', 'native cancellation reports stopped')
  check(active.events[#active.events].text:find('not imported', 1, true), 'native transcript limitation is visible')
  app.sessions()
  for index, session in ipairs(s.sessions) do
    if session == active then api.nvim_win_set_cursor(0, { index, 0 }); break end
  end
  fn.maparg('<CR>', 'n', false, true).callback()
  vim.cmd('KilnModel native-error-fixture')
  app.terminal()
  local failed_win = api.nvim_get_current_win()
  local failed_buf = api.nvim_get_current_buf()
  check(vim.wait(5000, function() return active.native_job == nil end, 20), 'native error process exits')
  equal(active.status, 'error', 'native failure reports error status')
  check(api.nvim_win_is_valid(failed_win), 'failed native terminal remains open')
  local diagnostics = table.concat(api.nvim_buf_get_lines(failed_buf, 0, -1, false), '\n')
  check(diagnostics:find('Fixture authentication failed', 1, true), 'native failure diagnostics remain visible')
  check(active.events[#active.events].text:find('status 7', 1, true), 'transcript records native exit code')
  api.nvim_set_current_win(failed_win)
  fn.maparg('q', 'n', false, true).callback()
  check(not api.nvim_win_is_valid(failed_win), 'q closes retained diagnostic terminal')
  check(not api.nvim_buf_is_valid(failed_buf), 'q wipes retained diagnostic terminal buffer')
  equal(active.native_job, nil, 'diagnostic cleanup leaves no native job')
  equal(active.status, 'error', 'closing diagnostics preserves failure status')
  local transcript_maps = api.nvim_buf_get_keymap(s.buffers.transcript, 'n')
  local mapped_e = false
  for _, map in ipairs(transcript_maps) do if map.lhs == 'e' then mapped_e = true end end
  check(not mapped_e, 'native Vim word-end motion e is retained')
  check(fn.filereadable(s.state_file) == 1, 'sessions persist to isolated state directory')
  vim.o.columns, vim.o.lines = 80, 24
  api.nvim_exec_autocmds('VimResized', {})
  equal(api.nvim_win_get_width(s.windows.monitor), 24, 'narrow terminal retains minimum sidebar width')
  check(api.nvim_win_get_height(s.windows.prompt) >= 3, 'narrow terminal keeps prompt usable')
end

local ok, err = xpcall(run, debug.traceback)
if app then
  app.state.closing = true
  if app.state.changes then app.state.changes.stop() end
  for _, session in ipairs(app.state.sessions) do
    if session.job then fn.jobstop(session.job) end
    if session.native_job then fn.jobstop(session.native_job) end
  end
end
-- Avoid the normal exit hook recreating the just-removed temporary state.
pcall(api.nvim_del_augroup_by_name, 'Kiln')
fn.delete(temp, 'rf')
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') end
print('Kiln UI: ' .. count .. ' assertions passed')
vim.cmd('qa!')

-- End-to-end: real Neovim UI -> real bridge -> offline provider executables.
-- These fixtures speak the provider protocols; no account or network is used.
local api, fn = vim.api, vim.fn
local uv = vim.uv or vim.loop
local home = vim.env.KILN_HOME or fn.getcwd()
vim.opt.runtimepath:prepend(home)
vim.o.columns, vim.o.lines = 160, 50
vim.o.swapfile, vim.o.backup, vim.o.writebackup, vim.o.modeline = false, false, false, false
vim.o.equalalways, vim.o.hidden = false, true
local temp = fn.tempname() .. '-kiln-stream'
fn.mkdir(temp .. '/project', 'p')
fn.mkdir(temp .. '/logs', 'p')
local root = uv.fs_realpath(temp .. '/project')
vim.env.KILN_HOME = home
vim.env.KILN_STATE_DIR = temp .. '/state'
vim.env.KILN_FAKE_LOGDIR = temp .. '/logs'
local warnings, count = {}, 0
vim.notify = function(message) warnings[#warnings + 1] = tostring(message) end
local function check(condition, message)
  count = count + 1
  assert(condition, message)
end
local function wait_for(predicate, message)
  check(vim.wait(7000, predicate, 10), message)
end
local function git(...)
  local args = { 'git', '-C', root }
  vim.list_extend(args, { ... })
  local result = vim.system(args, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end
local function contains(haystack, needle)
  return haystack:find(needle, 1, true) ~= nil
end
local function find_event(session, kind, predicate)
  for _, event in ipairs(session.events) do
    if event.type == kind and (not predicate or predicate(event)) then return event end
  end
end
local function requests(provider)
  local result = {}
  for _, line in ipairs(fn.readfile(temp .. '/logs/' .. provider .. '.jsonl')) do
    result[#result + 1] = vim.json.decode(line)
  end
  return result
end
local app
local function run()
  git('init', '-q')
  fn.writefile({ 'print("original")' }, root .. '/app.py')
  git('add', 'app.py')
  git('-c', 'user.name=WarrenBuffering', '-c', 'user.email=WarrenBuffering@users.noreply.github.com',
    'commit', '-qm', 'Offline integration fixture')
  local fake = temp .. '/provider-fixture'
  local fixture = [=[
import json, os, pathlib, sys, time

provider = "codex" if sys.argv[1:2] == ["exec"] else "claude"
log = pathlib.Path(os.environ["KILN_FAKE_LOGDIR"]) / (provider + ".jsonl")
turn = len(log.read_text().splitlines()) + 1 if log.exists() else 1
prompt = sys.stdin.read()
with log.open("a") as out:
    out.write(json.dumps({"argv": sys.argv[1:], "prompt": prompt, "cwd": os.getcwd()}) + "\n")

def emit(value):
    # Deliberately fragment every JSON record, exercising both bridge and UI framing.
    data = json.dumps(value, ensure_ascii=False).encode("utf-8") + b"\n"
    for offset in range(0, len(data), 29):
        sys.stdout.buffer.write(data[offset:offset + 29])
        sys.stdout.buffer.flush()

if provider == "codex":
    emit({"type": "thread.started", "thread_id": "codex-fixture-session"})
    emit({"type": "turn.started"})
    emit({"type": "item.completed", "item": {"id": "item_0", "type": "agent_message",
          "text": f"Codex turn {turn}: I will update app.py, then verify the result."}})
    emit({"type": "item.started", "item": {"id": "item_1", "type": "command_execution",
          "command": "python3 -m unittest", "status": "in_progress"}})
    time.sleep(0.4)
    deleting = "Delete app.py for regression" in prompt
    if deleting:
        pathlib.Path("app.py").unlink()
    else:
        pathlib.Path("app.py").write_text(f'print("codex turn {turn}")\n')
    pathlib.Path("a\nodd.txt").write_text("A filename containing a newline.\n")
    emit({"type": "item.completed", "item": {"id": "item_2", "type": "file_change", "status": "completed",
          "changes": [{"path": "app.py", "kind": "delete" if deleting else "update"}]}})
    emit({"type": "item.completed", "item": {"id": "item_1", "type": "command_execution",
          "command": "python3 -m unittest", "status": "completed", "aggregated_output": "Ran 1 test\nOK", "exit_code": 0}})
    emit({"type": "item.completed", "item": {"id": "item_3", "type": "agent_message",
          "text": f"Codex turn {turn} completed; app.py verified."}})
    emit({"type": "turn.completed", "usage": {"input_tokens": 100 + turn, "output_tokens": 20 + turn}})
else:
    emit({"type": "system", "subtype": "init", "session_id": "claude-fixture-session"})
    emit({"type": "stream_event", "event": {"type": "message_start", "message": {"id": "claude-message-1"}}})
    emit({"type": "stream_event", "event": {"type": "content_block_start", "index": 0,
          "content_block": {"type": "text", "text": ""}}})
    emit({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
          "delta": {"type": "text_delta", "text": "Claude is checking the handoff"}}})
    time.sleep(0.4)
    emit({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
          "delta": {"type": "text_delta", "text": " and updating app.py."}}})
    emit({"type": "stream_event", "event": {"type": "content_block_stop", "index": 0}})
    emit({"type": "assistant", "message": {"id": "claude-message-1", "content": [
          {"type": "text", "text": "Claude is checking the handoff and updating app.py."}]}})
    emit({"type": "assistant", "message": {"id": "claude-tool-message", "content": [
          {"type": "tool_use", "id": "edit-1", "name": "Edit", "input": {
           "file_path": str(pathlib.Path("app.py").resolve()), "old_string": 'print("codex turn 2")',
           "new_string": 'print("claude edit")'}}]}})
    pathlib.Path("app.py").write_text('print("claude edit")\n')
    emit({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "edit-1",
          "content": "Updated app.py", "is_error": False}]}})
    emit({"type": "system", "subtype": "task_started", "task_id": "reviewer", "description": "Reviewing app.py"})
    emit({"type": "assistant", "parent_tool_use_id": "reviewer", "message": {"id": "review-message",
          "content": [{"type": "text", "text": "The edit is consistent."}]}})
    emit({"type": "system", "subtype": "task_notification", "task_id": "reviewer", "status": "completed",
          "summary": "Review complete"})
    emit({"type": "result", "subtype": "success", "session_id": "claude-fixture-session", "is_error": False,
          "result": "Claude is checking the handoff and updating app.py.",
          "usage": {"input_tokens": 203, "output_tokens": 44}})
]=]
  fn.writefile({ '#!' .. fn.exepath('python3') }, fake)
  fn.writefile(vim.split(fixture, '\n', { plain = true }), fake, 'a')
  assert(uv.fs_chmod(fake, 448))
  vim.env.KILN_CODEX_BIN, vim.env.KILN_CLAUDE_BIN = fake, fake
  vim.cmd('edit ' .. fn.fnameescape(root .. '/app.py'))
  app = require('kiln')
  app.setup({ root = root })
  local state = app.state
  local codex = state.sessions[state.selected]
  check(state.follow, 'Live follow is enabled by default')
  app.focus_prompt()
  local prompt_win = state.windows.prompt
  local sidebar_width = api.nvim_win_get_width(state.windows.monitor)
  api.nvim_buf_set_lines(state.buffers.prompt, 0, -1, false, { 'Update app.py for first turn' })
  app.send()
  wait_for(function()
    return find_event(codex, 'tool', function(e) return e.name == 'Shell' and e.status == 'running' end)
  end, 'Real bridge delivers running tool activity before completion')
  check(codex.status == 'running', 'Session is running while provider works')
  check(find_event(codex, 'message', function(e) return contains(e.text or '', 'Codex turn 1:') end),
    'Progress narration arrives before the file edit')
  check(fn.readfile(root .. '/app.py')[1] == 'print("original")', 'Editor narration precedes actual disk mutation')
  wait_for(function() return codex.job == nil end, 'First real-bridge provider turn completes')
  check(codex.status == 'done', 'Codex success reaches UI status')
  check(codex.native_id == 'codex-fixture-session', 'Native Codex session is captured')
  check(codex.usage.input_tokens == 101, 'Usage reaches UI from provider schema')
  wait_for(state.changes.is_diff_open, 'File event automatically opens live diff')
  local code_buf = api.nvim_win_get_buf(state.windows.code)
  check(api.nvim_buf_get_lines(code_buf, 0, 1, false)[1] == 'print("codex turn 1")',
    'Working editor shows the actual provider-written content')
  check(vim.wo[state.windows.code].diff, 'Working file is in native diff mode')
  check(api.nvim_get_current_win() == prompt_win, 'Live provider edits never steal prompt focus')
  check(api.nvim_win_get_width(state.windows.monitor) == sidebar_width, 'Live diff preserves sidebar width')
  check(find_event(codex, 'tool', function(e)
    return e.name == 'Shell' and e.status == 'done' and contains(e.text or '', 'Ran 1 test')
  end), 'Completed command output replaces its running activity record')
  wait_for(function()
    return contains(table.concat(api.nvim_buf_get_lines(state.buffers.monitor, 0, -1, false), '\n'), 'a\\nodd.txt')
  end, 'Newline filename is safely escaped in monitor without losing its identity')
  local first = requests('codex')[1]
  check(first.cwd == root, 'Provider runs inside requested repository')
  check(first.argv[1] == 'exec' and vim.tbl_contains(first.argv, '--json'), 'Real bridge selects Codex JSON protocol')
  check(vim.tbl_contains(first.argv, 'sandbox_mode="workspace-write"'), 'Edit run retains workspace sandbox policy')
  check(contains(first.prompt, 'Editor context: app.py:'), 'Editor location travels through real bridge')

  api.nvim_buf_set_lines(state.buffers.prompt, 0, -1, false, { 'Update app.py for second turn' })
  app.send()
  wait_for(function() return codex.job == nil end, 'Second Codex turn completes')
  wait_for(function()
    return state.changes.is_diff_open() and api.nvim_buf_get_lines(api.nvim_win_get_buf(state.windows.code), 0, 1, false)[1]
      == 'print("codex turn 2")'
  end, 'Second turn refreshes the live diff')
  local codex_requests = requests('codex')
  check(#codex_requests == 2, 'Exactly two offline Codex calls were made')
  check(codex_requests[2].argv[2] == 'resume' and vim.tbl_contains(codex_requests[2].argv, 'codex-fixture-session'),
    'Second turn resumes the exact native Codex session')
  local narration_count = 0
  for _, event in ipairs(codex.events) do
    if event.type == 'message' and event.role == 'assistant' then narration_count = narration_count + 1 end
  end
  check(narration_count == 4, 'Reused provider item IDs preserve both turns of narration')
  check(find_event(codex, 'message', function(e) return contains(e.text or '', 'Codex turn 1:') end),
    'Earlier assistant turn survives repeated item_0')
  check(find_event(codex, 'message', function(e) return contains(e.text or '', 'Codex turn 2:') end),
    'New assistant turn receives its own event identity')

  app.provider('claude')
  local claude = state.sessions[state.selected]
  check(claude.provider == 'claude' and claude.native_id == nil, 'Provider switch creates separate native session')
  check(contains(claude.handoff or '', 'Codex turn 2'), 'Recent conversation is prepared for Claude handoff')
  app.model('sonnet')
  api.nvim_buf_set_lines(state.buffers.prompt, 0, -1, false, { 'Continue with the Claude edit' })
  app.send()
  wait_for(function()
    return find_event(claude, 'message', function(e) return e.text == 'Claude is checking the handoff' end)
  end, 'Claude partial text is visible before final assistant message')
  check(claude.status == 'running', 'Claude remains running during partial streaming')
  wait_for(function() return claude.job == nil end, 'Claude real-bridge turn completes')
  check(claude.status == 'done' and claude.native_id == 'claude-fixture-session', 'Claude completion and session reach UI')
  check(codex.native_id == 'codex-fixture-session', 'Switching providers retains Codex resume identity')
  wait_for(function()
    return state.changes.is_diff_open() and api.nvim_buf_get_lines(api.nvim_win_get_buf(state.windows.code), 0, 1, false)[1]
      == 'print("claude edit")'
  end, 'Claude Edit result follows absolute path into live diff')
  local main_messages = 0
  for _, event in ipairs(claude.events) do
    if event.type == 'message' and event.role == 'assistant' and not event.parent_id then
      main_messages = main_messages + 1
      check(event.text == 'Claude is checking the handoff and updating app.py.', 'Partial snapshot resolves to complete message')
    end
  end
  check(main_messages == 1, 'Claude partial/full/result messages do not duplicate transcript')
  check(find_event(claude, 'message', function(e) return e.parent_id == 'reviewer' end), 'Subagent narration remains visible')
  check(find_event(claude, 'tool', function(e) return e.name == 'Agent' and e.status == 'done' end),
    'Subagent completion appears in activity')
  local request = requests('claude')[1]
  check(vim.tbl_contains(request.argv, 'stream-json') and vim.tbl_contains(request.argv, '--include-partial-messages'),
    'Real bridge selects Claude streaming protocol')
  check(vim.tbl_contains(request.argv, 'sonnet'), 'Selected model passes literally to Claude')
  check(not vim.tbl_contains(request.argv, '--resume'), 'Claude never receives Codex session identity')
  check(contains(request.prompt, 'Codex turn 2') and contains(request.prompt, 'Continue with the Claude edit'),
    'Conversation handoff and new request both reach Claude stdin')
  check(claude.usage.output_tokens == 44, 'Claude usage normalizes into UI')

  -- A deletion has no file left to follow; it must still open a live diff.
  app.sessions()
  api.nvim_win_set_cursor(0, { 1, 0 })
  fn.maparg('<CR>', 'n', false, true).callback()
  check(state.sessions[state.selected] == codex, 'Select the original Codex session after Claude handoff')
  api.nvim_buf_set_lines(state.buffers.prompt, 0, -1, false, { 'Delete app.py for regression' })
  app.send()
  wait_for(function() return codex.job == nil end, 'Provider deletion turn completes')
  wait_for(function()
    return state.changes.is_diff_open() and vim.bo[api.nvim_win_get_buf(state.windows.code)].buftype == 'nofile'
      and contains(vim.wo[state.windows.code].winbar, '(deleted)')
  end, 'Provider deletion automatically opens its live deletion diff')
  check(fn.filereadable(root .. '/app.py') == 0, 'Deleted file is not recreated by the editor')
  check(not vim.bo[api.nvim_win_get_buf(state.windows.code)].modifiable, 'Deletion worktree pane is read-only')
  check(find_event(codex, 'file', function(e) return e.path == 'app.py' and e.action == 'delete' end),
    'Provider deletion action stays visible in activity')
  check(api.nvim_get_current_win() == prompt_win, 'Deletion follow preserves prompt focus')
  check(api.nvim_win_get_width(state.windows.monitor) == sidebar_width, 'Deletion diff preserves sidebar width')
  state.changes.close_diff()
  check(api.nvim_buf_get_name(api.nvim_win_get_buf(state.windows.code)) == '',
    'Closing deletion diff opens a fresh buffer instead of reopening the missing file')
  check(fn.bufnr(root .. '/app.py') >= 0, 'Original deleted-file buffer stays available in buffer history')
  check(not contains(fn.execute('messages'), 'E211'), 'Deletion lifecycle does not emit a missing-file error')

  -- Both provider handoff directions must survive a byte limit inside Unicode.
  for _, case in ipairs({ { provider = 'claude', char = 'é', count = 12000 },
    { provider = 'codex', char = '😀', count = 6000 } }) do
    local previous = state.sessions[state.selected]
    previous.events = { { type = 'message', role = 'assistant', text = string.rep(case.char, case.count) .. 'a' } }
    app.provider(case.provider)
    local next_session = state.sessions[state.selected]
    local expected = string.rep(case.char, case.count - 1) .. 'a'
    check(next_session.handoff == expected, case.provider .. ' handoff truncation preserves complete Unicode characters')
    local prompt = string.rep('x', 69) .. '😀 Continue the Unicode handoff'
    api.nvim_buf_set_lines(state.buffers.prompt, 0, -1, false, { prompt })
    app.send()
    check(next_session.title == string.rep('x', 69), 'Session title ends before a partially fitting emoji')
    wait_for(function() return next_session.job == nil end, case.provider .. ' Unicode handoff completes through the real bridge')
    check(next_session.status == 'done', case.provider .. ' accepts Unicode handoff without an encoding failure')
    local sent = requests(case.provider)
    check(contains(sent[#sent].prompt, expected) and contains(sent[#sent].prompt, prompt),
      case.provider .. ' receives both the intact Unicode history and complete new prompt')
  end
  check(#warnings == 0, 'Full streaming lifecycle emits no UI warnings: ' .. table.concat(warnings, '\n'))
end

local ok, err = xpcall(run, debug.traceback)
if app then
  app.state.closing = true
  if app.state.changes then app.state.changes.stop() end
  for _, session in ipairs(app.state.sessions) do if session.job then fn.jobstop(session.job) end end
  vim.wait(3000, function()
    for _, session in ipairs(app.state.sessions) do if session.job then return false end end
    return true
  end, 10)
end
pcall(api.nvim_del_augroup_by_name, 'Kiln')
fn.delete(temp, 'rf')
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') end
print('Kiln streaming integration: ' .. count .. ' assertions passed')
vim.cmd('qa!')

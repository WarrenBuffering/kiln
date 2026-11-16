-- The persistent dossier drives real Neovim -> bridge -> offline provider jobs.
-- All files and worktrees are disposable; no model account or network is used.
local api, fn = vim.api, vim.fn
local uv = vim.uv or vim.loop
local home = vim.env.KILN_HOME or fn.getcwd()
vim.opt.runtimepath:prepend(home)
vim.o.columns, vim.o.lines = 160, 48
vim.o.swapfile, vim.o.backup, vim.o.writebackup, vim.o.modeline = false, false, false, false
vim.o.equalalways, vim.o.hidden = false, true
local temp = fn.tempname() .. '-kiln-driver'
fn.mkdir(temp .. '/project', 'p'); fn.mkdir(temp .. '/logs', 'p')
local root = uv.fs_realpath(temp .. '/project')
vim.env.KILN_HOME, vim.env.KILN_STATE_DIR = home, temp .. '/state'
vim.env.KILN_FAKE_LOGDIR = temp .. '/logs'
local app, count, warnings = nil, 0, {}
vim.notify = function(message) warnings[#warnings + 1] = tostring(message) end
local function check(value, message) count = count + 1; assert(value, message) end
local function contains(value, text) return tostring(value):find(text, 1, true) ~= nil end
local function wait_for(predicate, message)
  local passed = vim.wait(14000, predicate, 10)
  if not passed and app then
    message = message .. '\nSessions: ' .. vim.inspect(app.state.sessions) .. '\nWarnings: ' .. vim.inspect(warnings)
  end
  check(passed, message)
end
local function git(path, ...)
  local args = { 'git', '-C', path }; vim.list_extend(args, { ... })
  local result = vim.system(args, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end
local function event(task, text)
  for _, item in ipairs(task.events) do if contains(item.text, text) then return item end end
end
local function requests()
  local result = {}
  local path = temp .. '/logs/requests.jsonl'
  if fn.filereadable(path) == 1 then
    for _, line in ipairs(fn.readfile(path)) do
      local item = vim.json.decode(line); result[item.case] = item
    end
  end
  return result
end
local function text(buf) return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n') end
local function ordinary_windows()
  local result = {}
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_config(win).relative == '' then result[#result + 1] = win end
  end
  return result
end
local function task(id)
  for _, step in ipairs(app.state.dossier.steps) do
    if step.id == id then
      for _, candidate in ipairs(app.state.sessions) do if candidate.id == step.session_id then return candidate end end
    end
  end
end
local function highlighted_outcome(id)
  local state = app.state
  for _, namespace in pairs(api.nvim_get_namespaces()) do
    for _, mark in ipairs(api.nvim_buf_get_extmarks(state.buffers.monitor, namespace, 0, -1, { details = true })) do
      local row = state.monitor_rows[mark[2] + 1]
      if row and row.id == id and mark[4].hl_group == 'KilnCurrent' then return true end
    end
  end
  return false
end
local function has_source_change_marks(buf)
  for name, namespace in pairs(api.nvim_get_namespaces()) do
    if name:lower():find('kiln') then
      for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })) do
        local details = mark[4]
        for _, key in ipairs({ 'hl_group', 'line_hl_group', 'number_hl_group', 'sign_hl_group' }) do
          if tostring(details[key] or ''):find('^KilnEdit') then return true end
        end
      end
    end
  end
  return false
end
local function gate(name) fn.writefile({ 'continue' }, temp .. '/logs/' .. name) end
local function background_edit(task, name, message)
  local rendered = false
  api.nvim_buf_attach(app.state.buffers.monitor, false, { on_lines = function()
    if event(task, 'Background edit ' .. name) then rendered = true; return true end
  end })
  gate('late-' .. name)
  wait_for(function() return rendered end, message)
end
local function drive(id)
  app.dossier()
  local state, row = app.state, nil
  for index, item in pairs(app.state.monitor_rows) do
    if item.id == id and not item.path and (not row or index < row) then row = index end
  end
  assert(row, 'Dossier outcome has an actionable row: ' .. id)
  api.nvim_win_set_cursor(state.windows.monitor, { row, 0 })
  fn.maparg('<CR>', 'n', false, true).callback()
end
local function run()
  git(root, 'init', '-q'); git(root, 'config', 'user.name', 'WarrenBuffering')
  git(root, 'config', 'user.email', 'WarrenBuffering@users.noreply.github.com')
  fn.writefile({ 'defmodule Queue do', '  def value, do: :original', 'end' }, root .. '/queue.ex')
  git(root, 'add', '.'); git(root, 'commit', '-qm', 'Dossier driver fixture')
  local original = table.concat(fn.readfile(root .. '/queue.ex'), '\n')
  local provider = temp .. '/provider-fixture'
  local fixture = [=[
import hashlib, json, os, pathlib, re, sys, time
logs = pathlib.Path(os.environ["KILN_FAKE_LOGDIR"])
claude = "--output-format" in sys.argv
prompt = sys.stdin.read()
explicit = re.findall(r"\[case:([^\]]+)\]", prompt)
step = re.search(r"^DELIVERABLE ([A-Za-z0-9_-]+):", prompt, re.MULTILINE)
case = explicit[-1] if explicit else step.group(1)
native = ("claude-" if claude else "codex-") + hashlib.sha256(os.getcwd().encode()).hexdigest()[:12]
with (logs / "requests.jsonl").open("a") as output:
    output.write(json.dumps({"case": case, "cwd": os.getcwd(), "argv": sys.argv[1:], "prompt": prompt,
                             "native": native, "before": pathlib.Path("queue.ex").read_text()}) + "\n")
def emit(value):
    data = json.dumps(value).encode() + b"\n"
    for offset in range(0, len(data), 43):
        sys.stdout.buffer.write(data[offset:offset + 43]); sys.stdout.buffer.flush()
def message(value):
    identifier = "message-" + str(time.monotonic_ns())
    if claude:
        emit({"type": "assistant", "message": {"id": identifier, "content": [{"type": "text", "text": value}]}})
    else:
        emit({"type": "item.completed", "item": {"id": identifier, "type": "agent_message", "text": value}})
def write(path, value):
    identifier = "file-" + str(time.monotonic_ns())
    if claude:
        emit({"type": "assistant", "message": {"id": identifier, "content": [{"type": "tool_use", "id": identifier,
              "name": "Write", "input": {"file_path": str(pathlib.Path(path).resolve()), "content": value}}]}})
    pathlib.Path(path).write_text(value)
    if claude:
        emit({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": identifier, "content": "File written"}]}})
    else:
        emit({"type": "item.completed", "item": {"id": identifier, "type": "file_change",
              "status": "completed", "changes": [{"path": path, "kind": "update"}]}})
if claude:
    emit({"type": "system", "subtype": "init", "session_id": native})
else:
    emit({"type": "thread.started", "thread_id": native}); emit({"type": "turn.started"})
if case == "resume_alpha":
    message("Reread the human correction and preserve queue.ex")
    write("receipt.ex", "defmodule Receipt do\n  def source, do: :human_preserved\nend\n")
    message("Receipt appears after handback")
else:
    message("Implement " + case + " in its own worktree")
    write("queue.ex", "defmodule Queue do\n  def value, do: :" + case + "\nend\n")
    message("First edit " + case)
late, deadline = False, time.monotonic() + 50
while not (logs / ("release-" + case)).exists() and time.monotonic() < deadline:
    if case in ("alpha", "beta") and not late and (logs / ("late-" + case)).exists():
        write("queue.ex", "defmodule Queue do\n  def value, do: :" + case + "_background\nend\n")
        message("Background edit " + case); late = True
    time.sleep(0.025)
message("Finished " + case)
if claude:
    emit({"type": "result", "subtype": "success", "is_error": False, "session_id": native,
          "usage": {"input_tokens": 100, "output_tokens": 20}})
else:
    emit({"type": "turn.completed", "usage": {"input_tokens": 100, "output_tokens": 20}})
]=]
  fn.writefile({ '#!' .. fn.exepath('python3') }, provider)
  fn.writefile(vim.split(fixture, '\n', { plain = true }), provider, 'a')
  assert(uv.fs_chmod(provider, 448))
  vim.env.KILN_CODEX_BIN, vim.env.KILN_CLAUDE_BIN = provider, provider
  vim.cmd.edit(fn.fnameescape(root .. '/queue.ex'))
  app = require('kiln'); app.setup({ root = root, workflow = false })
  local state = app.state
  local plan = table.concat({ '# Queue strategies', 'Goal: Compare two independently reviewable queue results.',
    'Approach: Keep each strategy isolated behind the same function.',
    'Why this approach: Independent strategies can be inspected without sharing edits.', '',
    '## Step alpha: Prioritize the queue', 'Outcome: Queue exposes the priority strategy.',
    'Why: Priority ordering is independently reviewable.', 'Verify: Inspect Queue.value/0.',
    'Depends: none', 'Provider: codex', '',
    '## Step beta: Compare a second strategy', 'Outcome: Queue exposes the comparison strategy.',
    'Why: The comparison can be evaluated without changing the priority implementation.',
    'Verify: Inspect the separate Queue.value/0.', 'Depends: none', 'Provider: claude' }, '\n')
  app.edit_dossier()
  api.nvim_buf_set_lines(state.dossier_buffer, 0, -1, false, vim.split(plan, '\n', { plain = true }))
  api.nvim_buf_call(state.dossier_buffer, function() vim.cmd('silent write') end)
  app.dossier()
  local window_count = #ordinary_windows()
  check(window_count == 4, 'Driver starts with one coding pane and three fixed sidebar panes')
  check(api.nvim_win_get_buf(state.windows.code) ~= state.buffers.monitor, 'Dossier occupies the right sidebar only')

  app.next_step('alpha')
  local alpha = task('alpha')
  wait_for(function() return alpha.job and event(alpha, 'First edit alpha') and alpha.native_id end, 'Codex emits an actual first edit through the bridge')
  wait_for(function()
    local buf = api.nvim_win_get_buf(state.windows.code)
    return contains(text(buf), ':alpha') and has_source_change_marks(buf)
  end, 'Active dossier edits appear as highlighted hunks in the full coding pane')
  check(not state.changes.is_diff_open() and #ordinary_windows() == window_count,
    'Following a dossier edit does not split the coding pane into baseline and worktree windows')
  check(api.nvim_win_get_width(state.windows.code) > vim.o.columns * 0.70,
    'The source keeps roughly three quarters of the terminal width')
  check(highlighted_outcome('alpha') and state.rail_active_id == 'alpha', 'The active outcome is visibly highlighted in the persistent rail')

  app.next_step('beta')
  local beta = task('beta')
  wait_for(function() return beta.job and event(beta, 'First edit beta') and beta.native_id end, 'Claude emits its real first edit in another worktree')
  wait_for(function()
    return state.rail_active_id == 'beta' and contains(text(api.nvim_win_get_buf(state.windows.code)), ':beta')
  end, 'The driver follows the selected dossier outcome into its own code')
  check(alpha.job ~= nil and alpha.workspace.root ~= beta.workspace.root, 'The two bridge jobs are isolated and genuinely overlap')
  local beta_index, beta_buf = state.selected, api.nvim_win_get_buf(state.windows.code)
  local focus = api.nvim_get_current_win()
  background_edit(alpha, 'alpha', 'Background Codex edits reach an actual sidebar refresh')
  check(state.selected == beta_index and state.view_root == beta.workspace.root
    and state.rail_active_id == 'beta' and highlighted_outcome('beta'),
    'Background progress cannot select or highlight a different dossier outcome')
  check(api.nvim_get_current_win() == focus and api.nvim_win_get_buf(state.windows.code) == beta_buf
    and contains(text(beta_buf), ':beta'), 'Background edits preserve keyboard focus and the selected source')

  drive('alpha')
  check(state.sessions[state.selected] == alpha and state.view_root == alpha.workspace.root,
    'Enter on a dossier outcome selects its bound worktree')
  check(highlighted_outcome('alpha') and api.nvim_get_current_win() == state.windows.monitor,
    'Selecting an outcome highlights it without pulling focus away from dossier navigation')
  app.take_control()
  wait_for(function() return alpha.job == nil and api.nvim_get_current_win() == state.windows.code end,
    'Takeover waits for the selected writer and returns keyboard control to the code')
  check(beta.job ~= nil and state.current_context.human_control and not state.follow,
    'Taking control pauses this outcome while another worktree can keep running')
  wait_for(function() return contains(text(state.buffers.monitor), 'YOU EDIT') end, 'The same dossier outcome visibly becomes human-controlled')
  check(api.nvim_win_get_buf(state.windows.monitor) == state.buffers.monitor and highlighted_outcome('alpha'),
    'Handcoding leaves the dossier and its selected highlight in place')
  check(state.changes.follow('queue.ex', state.windows.code), 'The operator can navigate to the owned source file')
  local human_buf = api.nvim_win_get_buf(state.windows.code)
  api.nvim_buf_set_lines(human_buf, 1, 2, false, { '  def value, do: :human_correction' })
  api.nvim_buf_call(human_buf, function() vim.cmd('silent write') end)
  local saved = table.concat(fn.readfile(alpha.workspace.root .. '/queue.ex'), '\n')
  check(contains(saved, ':human_correction') and state.current_context.human_changes['queue.ex'] ~= nil,
    'A real editor save records the correction for the next agent handoff')
  background_edit(beta, 'beta', 'Background Claude edits reach an actual sidebar refresh during handcoding')
  check(api.nvim_get_current_win() == state.windows.code and api.nvim_win_get_buf(state.windows.code) == human_buf
    and contains(text(human_buf), ':human_correction') and highlighted_outcome('alpha'),
    'Background work cannot disturb the hand-edited buffer or dossier highlight')

  local native = alpha.native_id
  app.focus_prompt()
  api.nvim_buf_set_lines(state.buffers.prompt, 0, -1, false, { '[case:resume_alpha] Preserve my correction and add the receipt.' })
  app.send()
  wait_for(function() return requests().resume_alpha and alpha.job and event(alpha, 'Receipt appears after handback') end,
    'Handback resumes the same task and makes another real file edit')
  local resumed = requests().resume_alpha
  check(alpha.native_id == native and vim.tbl_contains(resumed.argv, 'resume') and vim.tbl_contains(resumed.argv, native),
    'The bridge resumes the original native Codex conversation')
  check(contains(resumed.prompt, 'Editor handoff (file-path data): ["queue.ex"]')
    and contains(resumed.before, ':human_correction'), 'The resumed provider receives the saved file handoff and reads the human edit')
  check(state.follow and not state.current_context.human_control,
    'Sending an edit turn after takeover automatically restores live following')
  wait_for(function()
    local buf = api.nvim_win_get_buf(state.windows.code)
    return contains(api.nvim_buf_get_name(buf), 'receipt.ex') and contains(text(buf), ':human_preserved')
      and has_source_change_marks(buf)
  end, 'The next agent file appears in the same full-width coding pane without an extra follow command')
  check(api.nvim_get_current_win() == state.windows.prompt and highlighted_outcome('alpha')
    and contains(text(state.buffers.monitor), 'IMPLEMENTING') and #ordinary_windows() == window_count,
    'Handback retains prompt focus, the active step, and the original layout')
  gate('release-resume_alpha'); gate('release-beta')
  wait_for(function() return not alpha.job and alpha.status == 'done' and not beta.job and beta.status == 'done' end,
    'Both provider turns complete normally')
  check(alpha.last_human_version == state.current_context.human_version
    and table.concat(fn.readfile(alpha.workspace.root .. '/queue.ex'), '\n') == saved,
    'Successful handback acknowledges and preserves the exact human correction')
  wait_for(function() return contains(text(state.buffers.monitor), 'REVIEW') end,
    'Completion asks for human review instead of advancing the dossier automatically')
  check(#state.sessions == 3 and vim.tbl_count(requests()) == 3, 'Only two explicit dispatches and one explicit handback were submitted')
  check(table.concat(fn.readfile(root .. '/queue.ex'), '\n') == original and git(root, 'status', '--porcelain') == '',
    'Driver inspection and isolated agent work preserve the primary checkout')
end
local ok, err = xpcall(run, debug.traceback)
if app then
  app.state.closing = true
  for _, ctx in pairs(app.state.contexts or {}) do ctx.changes.stop() end
  for _, session in ipairs(app.state.sessions) do if session.job then fn.jobstop(session.job) end end
  vim.wait(5000, function()
    for _, session in ipairs(app.state.sessions) do if session.job or session.operation then return false end end
    return true
  end, 10)
end
pcall(api.nvim_del_augroup_by_name, 'Kiln'); fn.chdir(home); fn.delete(temp, 'rf')
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') end
print('Kiln dossier driver: ' .. count .. ' assertions passed'); vim.cmd('qa!')

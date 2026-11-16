-- Real Neovim -> bridge -> offline Codex/Claude protocols in isolated Git worktrees.
local api, fn = vim.api, vim.fn
local uv = vim.uv or vim.loop
local home = vim.env.KILN_HOME or fn.getcwd()
vim.opt.runtimepath:prepend(home)
vim.o.columns, vim.o.lines = 180, 55
vim.o.swapfile, vim.o.backup, vim.o.writebackup, vim.o.modeline = false, false, false, false
vim.o.equalalways, vim.o.hidden = false, true
local temp = fn.tempname() .. '-kiln-parallel'
fn.mkdir(temp .. '/project', 'p')
fn.mkdir(temp .. '/logs', 'p')
local root = uv.fs_realpath(temp .. '/project')
vim.env.KILN_HOME, vim.env.KILN_STATE_DIR = home, temp .. '/state'
vim.env.KILN_FAKE_LOGDIR = temp .. '/logs'
local warnings, count, app = {}, 0, nil
vim.notify = function(message) warnings[#warnings + 1] = tostring(message) end
local function check(value, message)
  count = count + 1
  assert(value, message)
end
local function wait_for(predicate, message)
  local passed = vim.wait(12000, predicate, 10)
  if not passed and app then
    message = message .. '\nState: ' .. vim.inspect(app.state.sessions[app.state.selected]) .. '\nWarnings: ' .. vim.inspect(warnings)
  end
  check(passed, message)
end
local function contains(text, needle) return tostring(text):find(needle, 1, true) ~= nil end
local function git(path, ...)
  local args = { 'git', '-C', path }
  vim.list_extend(args, { ... })
  local result = vim.system(args, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end
local function event(session, kind, match)
  for _, value in ipairs(session.events) do
    if value.type == kind and (not match or contains(value.text or value.path, match)) then return value end
  end
end
local function requests()
  local out = {}
  for _, provider in ipairs({ 'codex', 'claude' }) do
    local path = temp .. '/logs/' .. provider .. '.jsonl'
    if fn.filereadable(path) == 1 then
      for _, line in ipairs(fn.readfile(path)) do
        local value = vim.json.decode(line)
        out[value.case] = value
      end
    end
  end
  return out
end
local function select(index)
  app.sessions()
  api.nvim_win_set_cursor(0, { index, 0 })
  fn.maparg('<CR>', 'n', false, true).callback()
end
local function send(prompt)
  app.focus_prompt()
  api.nvim_buf_set_lines(app.state.buffers.prompt, 0, -1, false, { prompt })
  app.send()
end
local function finish(session, message)
  wait_for(function() return session.operation == nil and session.job == nil end, message)
  check(session.status == 'done', message .. ' succeeds: ' .. vim.inspect(session.events))
end
local function review(session)
  app.review()
  wait_for(function() return not session.operation and session.reviewed end, 'Task review captures current fingerprint')
  check(type(session.review_fingerprint) == 'string' and #session.review_fingerprint == 64,
    'Review uses a concrete workspace fingerprint')
end
local function run()
  git(root, 'init', '-q')
  git(root, 'config', 'user.name', 'WarrenBuffering')
  git(root, 'config', 'user.email', 'WarrenBuffering@users.noreply.github.com')
  fn.writefile({ 'defmodule Queue do', '  def value, do: :original', 'end' }, root .. '/queue.ex')
  fn.writefile({ 'defmodule Guard do', '  def check, do: :original', 'end' }, root .. '/guard.ex')
  git(root, 'add', '.')
  git(root, 'commit', '-qm', 'Parallel integration fixture')
  local original_head = git(root, 'rev-parse', 'HEAD')
  local original_queue = table.concat(fn.readfile(root .. '/queue.ex'), '\n')
  local fake = temp .. '/provider-fixture'
  local fixture = [=[
import hashlib, json, os, pathlib, re, subprocess, sys, time
provider = "codex" if sys.argv[1:2] == ["exec"] else "claude"
logs = pathlib.Path(os.environ["KILN_FAKE_LOGDIR"])
prompt = sys.stdin.read()
cases = re.findall(r"\[case:([^\]]+)\]", prompt)
case = cases[-1]
native = provider + "-" + hashlib.sha256(os.getcwd().encode()).hexdigest()[:12]
with (logs / (provider + ".jsonl")).open("a") as output:
    output.write(json.dumps({"case": case, "cwd": os.getcwd(), "argv": sys.argv[1:], "prompt": prompt,
                             "native": native, "before": pathlib.Path("queue.ex").read_text()}) + "\n")
def emit(value):
    data = json.dumps(value).encode() + b"\n"
    for offset in range(0, len(data), 47):
        sys.stdout.buffer.write(data[offset:offset + 47]); sys.stdout.buffer.flush()
def message(text):
    if provider == "codex":
        emit({"type": "item.completed", "item": {"id": "narration-" + text, "type": "agent_message", "text": text}})
    else:
        emit({"type": "assistant", "message": {"id": "narration-" + text, "content": [{"type": "text", "text": text}]}})
def write(path, text):
    pathlib.Path(path).write_text(text)
    if provider == "codex":
        emit({"type": "item.completed", "item": {"id": "file-" + str(time.monotonic_ns()), "type": "file_change",
              "status": "completed", "changes": [{"path": path, "kind": "update"}]}})
    else:
        tool = "edit-" + str(time.monotonic_ns())
        emit({"type": "assistant", "message": {"id": tool, "content": [{"type": "tool_use", "id": tool,
              "name": "Edit", "input": {"file_path": str(pathlib.Path(path).resolve()), "old_string": "", "new_string": text}}]}})
        emit({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": tool,
              "content": "Updated " + path, "is_error": False}]}})
if provider == "codex":
    emit({"type": "thread.started", "thread_id": native}); emit({"type": "turn.started"})
else:
    emit({"type": "system", "subtype": "init", "session_id": native})
message("Started " + case)
if case in ("alpha", "beta"):
    write("queue.ex", "defmodule Queue do\n  def value, do: :" + case + "\nend\n")
    message("Wrote " + case)
    late = False
    deadline = time.monotonic() + 40
    while not (logs / ("release-" + case)).exists() and time.monotonic() < deadline:
        if case == "alpha" and not late and (logs / "alpha-late").exists():
            write("queue.ex", "defmodule Queue do\n  def value, do: :alpha_background\nend\n")
            message("Background alpha edit"); late = True
        time.sleep(0.03)
elif case == "resume_a":
    write("receipt.ex", "defmodule Receipt do\n  def ready?, do: true\nend\n")
    git = ["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false",
           "-c", "user.name=WarrenBuffering", "-c", "user.email=WarrenBuffering@users.noreply.github.com"]
    subprocess.run(git + ["add", "-A"], check=True, capture_output=True)
    subprocess.run(git + ["commit", "-qm", "Offline provider checkpoint"], check=True, capture_output=True)
    message("Preserved human queue and guard")
elif case == "resume_b":
    message("Unrelated task resumes without another worktree's handoff")
elif case == "review_b":
    message("Read-only review of " + pathlib.Path("queue.ex").read_text())
else:
    message("Unexpected fixture request " + case)
if provider == "codex":
    emit({"type": "turn.completed", "usage": {"input_tokens": 100, "output_tokens": 20}})
else:
    emit({"type": "result", "subtype": "success", "session_id": native, "is_error": False,
          "result": "Completed " + case, "usage": {"input_tokens": 100, "output_tokens": 20}})
]=]
  fn.writefile({ '#!' .. fn.exepath('python3') }, fake)
  fn.writefile(vim.split(fixture, '\n', { plain = true }), fake, 'a')
  assert(uv.fs_chmod(fake, 448))
  vim.env.KILN_CODEX_BIN, vim.env.KILN_CLAUDE_BIN = fake, fake
  vim.cmd('edit ' .. fn.fnameescape(root .. '/queue.ex'))
  local main_buf = api.nvim_get_current_buf()
  app = require('kiln')
  app.setup({ root = root, workflow = false })
  local state = app.state
  app.new()
  local alpha, alpha_index = state.sessions[state.selected], state.selected
  wait_for(function() return alpha.workspace and not alpha.operation end, 'First isolated task creates a real worktree')
  app.task('Build the priority queue')
  send('[case:alpha] Build the queue')
  wait_for(function() return alpha.job and event(alpha, 'message', 'Wrote alpha') end, 'Codex is editing the first task')
  wait_for(function() return state.changes.is_diff_open() end, 'First task file event opens its live diff')
  check(alpha.workspace.root ~= root and fn.isdirectory(alpha.workspace.root) == 1, 'First builder owns a separate checkout')
  check(git(alpha.workspace.root, 'rev-parse', 'HEAD') == original_head, 'Task starts at the known main revision')

  app.new()
  local beta_draft = state.sessions[state.selected]
  wait_for(function() return beta_draft.workspace and not beta_draft.operation end, 'Second isolated task creates its own worktree')
  app.provider('claude')
  local beta, beta_index = state.sessions[state.selected], state.selected
  check(beta.workspace.root == beta_draft.workspace.root and beta.native_id == nil,
    'Provider change retains task worktree and creates its own native conversation')
  app.task('Build a separate queue strategy')
  send('[case:beta] Build the other queue')
  wait_for(function() return beta.job and event(beta, 'message', 'Wrote beta') end, 'Claude edits the second task while Codex still runs')
  check(alpha.job ~= nil and beta.job ~= nil, 'Both real bridge processes run concurrently')
  check(alpha.workspace.root ~= beta.workspace.root, 'Concurrent builders have different worktree paths')
  check(git(alpha.workspace.root, 'branch', '--show-current') ~= git(beta.workspace.root, 'branch', '--show-current'),
    'Concurrent builders have distinct Git branches')
  check(contains(fn.readfile(alpha.workspace.root .. '/queue.ex')[2], ':alpha'), 'First builder writes its own same-name file')
  check(contains(fn.readfile(beta.workspace.root .. '/queue.ex')[2], ':beta'), 'Second builder writes its own same-name file')
  check(table.concat(fn.readfile(root .. '/queue.ex'), '\n') == original_queue, 'Parallel edits never alter the main checkout')
  wait_for(function() return state.changes.is_diff_open() end, 'Selected Claude task follows its own live changes')
  local visible_buf, prompt_win = api.nvim_win_get_buf(state.windows.code), state.windows.prompt
  fn.writefile({ 'go' }, temp .. '/logs/alpha-late')
  wait_for(function() return event(alpha, 'message', 'Background alpha edit') end, 'Background task continues delivering real file activity')
  check(api.nvim_win_get_buf(state.windows.code) == visible_buf
    and contains(api.nvim_buf_get_lines(visible_buf, 1, 2, false)[1], ':beta'), 'Background events cannot replace selected task code')
  check(api.nvim_get_current_win() == prompt_win, 'Background agent activity preserves prompt focus')
  wait_for(function() return #alpha.changed_files > 0 and #beta.changed_files > 0 end, 'Every task maintains its live change list')
  check(alpha.changed_files[1].path == 'queue.ex' and beta.changed_files[1].path == 'queue.ex', 'Same-name changes stay attributed to their worktrees')

  app.control()
  local board = table.concat(api.nvim_buf_get_lines(state.overview.buf, 0, -1, false), '\n')
  check(contains(board, 'Build the priority queue') and contains(board, 'Build a separate queue strategy'), 'Mission control shows both objectives')
  check(contains(board, '2 builders'), 'Mission control reports both active builders')
  local alpha_row
  for row, item in pairs(state.overview.rows) do if item.session == alpha_index then alpha_row = row; break end end
  check(alpha_row ~= nil, 'Board task rows identify the correct task')
  api.nvim_win_set_cursor(state.overview.win, { alpha_row, 0 })
  fn.maparg('<CR>', 'n', false, true).callback()
  check(state.selected == alpha_index and state.view_root == alpha.workspace.root, 'Selecting a task moves the editor into that worktree')
  app.take_control()
  wait_for(function() return alpha.job == nil and api.nvim_get_current_win() == state.windows.code end, 'Taking control waits for selected writer to stop')
  check(alpha.status == 'stopped' and beta.job ~= nil, 'Take control cancels only the selected worktree writer')
  check(state.contexts[alpha.workspace.root].human_control and not state.follow, 'Human takeover pauses follow and exposes ownership')
  check(state.contexts[beta.workspace.root].human_control == false, 'Other worktree keeps agent ownership')
  check(state.changes.follow('queue.ex', state.windows.code), 'Human opens the task file directly')
  local alpha_buf = api.nvim_win_get_buf(state.windows.code)
  api.nvim_buf_set_lines(alpha_buf, 1, 2, false, { '  def value, do: :human_correction' })
  api.nvim_buf_call(alpha_buf, function() vim.cmd('silent write') end)
  local alpha_ctx, beta_ctx = state.contexts[alpha.workspace.root], state.contexts[beta.workspace.root]
  check(alpha_ctx.human_changes['queue.ex'] ~= nil and beta_ctx.human_changes['queue.ex'] == nil,
    'Human save is attributed only to its worktree')
  local guard_buf = fn.bufadd(alpha.workspace.root .. '/guard.ex')
  fn.bufload(guard_buf)
  api.nvim_buf_set_lines(guard_buf, 1, 2, false, { '  def check, do: :human_guard' })

  select(beta_index)
  app.reviewer()
  local reviewer, reviewer_index = state.sessions[state.selected], state.selected
  check(reviewer.mode == 'plan' and reviewer.workspace.root == beta.workspace.root, 'Reviewer shares the chosen worktree in plan mode')
  send('[case:review_b] Review this task without editing')
  finish(reviewer, 'Read-only reviewer finishes through the real Claude bridge')
  check(beta.job ~= nil, 'Read-only review runs alongside its builder')
  local review_request = requests().review_b
  check(vim.tbl_contains(review_request.argv, 'plan'), 'Reviewer CLI receives actual plan permissions')
  check(contains(review_request.before, ':beta'), 'Reviewer reads the correct task worktree')

  select(beta_index)
  app.provider('codex')
  local contender = state.sessions[state.selected]
  send('[case:blocked_writer] This writer must remain blocked')
  wait_for(function() return contender.operation == nil end, 'Same-worktree writer validation completes')
  check(contender.job == nil and requests().blocked_writer == nil, 'A second builder in the same worktree stays blocked')
  select(beta_index)
  fn.writefile({ 'go' }, temp .. '/logs/release-beta')
  finish(beta, 'Original Claude task completes')
  send('[case:resume_b] Continue the independent task')
  finish(beta, 'Another worktree resumes despite unsaved edits in task A')
  check(not contains(requests().resume_b.prompt, 'Editor handoff (file-path data)'), 'Task B never receives task A saved paths')
  check(vim.tbl_contains(requests().resume_b.argv, beta.native_id), 'Claude resumes its own native conversation')
  check(vim.bo[guard_buf].modified, 'Unrelated task leaves task A unsaved buffer untouched')

  select(alpha_index)
  send('[case:resume_a] Continue from my hand edits')
  wait_for(function() return alpha.operation == nil end, 'Own-worktree dirty-buffer validation completes')
  check(alpha.job == nil and requests().resume_a == nil, 'Own unsaved buffer blocks restarting its builder')
  api.nvim_buf_call(guard_buf, function() vim.cmd('silent write') end)
  send('[case:resume_a] Continue from my hand edits')
  finish(alpha, 'Stopped Codex session resumes after human saves')
  local resumed = requests().resume_a
  check(resumed.cwd == alpha.workspace.root and vim.tbl_contains(resumed.argv, alpha.native_id), 'Codex resumes original task cwd and native session')
  check(contains(resumed.prompt, 'Editor handoff (file-path data): ["guard.ex","queue.ex"]'),
    'Resumed task receives exactly its own human-saved paths')
  check(contains(resumed.before, ':human_correction'), 'Resumed agent reads the human correction from disk')
  check(contains(fn.readfile(alpha.workspace.root .. '/queue.ex')[2], ':human_correction'), 'Agent continuation preserves hand-edited queue')
  check(alpha.last_human_version == alpha_ctx.human_version, 'Successful continuation acknowledges this worktree handoff')
  check(beta.last_human_version == beta_ctx.human_version and beta_ctx.human_version == 0, 'Other task acknowledgment is independent')
  check(not alpha_ctx.human_control, 'Sending a new turn hands task ownership back to the agent')
  check(git(alpha.workspace.root, 'rev-parse', 'HEAD') ~= original_head
    and git(alpha.workspace.root, 'status', '--porcelain') == '', 'Offline provider commits the completed task on its own branch')
  wait_for(function()
    local paths = {}
    for _, entry in ipairs(alpha.changed_files) do paths[entry.path] = true end
    return paths['queue.ex'] and paths['guard.ex'] and paths['receipt.ex']
  end, 'Committed task changes stay visible against its original review base')

  app.integrate()
  check(alpha.operation == nil and git(root, 'rev-parse', 'HEAD') == original_head, 'Unreviewed task cannot integrate')
  review(alpha)
  fn.writefile({ 'external change after review' }, alpha.workspace.root .. '/drift.txt')
  app.integrate()
  wait_for(function() return alpha.operation == nil end, 'Integration checks exact reviewed contents')
  check(alpha.work_status ~= 'integrated' and not alpha.reviewed, 'Changed content invalidates review and integration')
  check(git(root, 'rev-parse', 'HEAD') == original_head, 'Review drift leaves primary history unchanged')
  review(alpha)
  fn.writefile({ 'keep my main work' }, root .. '/dirty-main.txt')
  app.integrate()
  wait_for(function() return alpha.operation == nil end, 'Dirty-main integration returns safely')
  check(alpha.work_status ~= 'integrated' and fn.readfile(root .. '/dirty-main.txt')[1] == 'keep my main work',
    'Integration refuses dirty main checkout without changing user files')
  check(git(root, 'rev-parse', 'HEAD') == original_head, 'Dirty-main refusal leaves primary history unchanged')
  fn.delete(root .. '/dirty-main.txt')
  review(alpha)
  api.nvim_buf_set_lines(main_buf, 1, 2, false, { '  def value, do: :unsaved_main' })
  app.integrate()
  check(alpha.operation == nil and vim.bo[main_buf].modified, 'Unsaved primary editor buffer blocks integration')
  api.nvim_buf_set_lines(main_buf, 0, -1, false, vim.split(original_queue, '\n', { plain = true }))
  vim.bo[main_buf].modified = false
  app.integrate()
  wait_for(function() return alpha.operation == nil and alpha.work_status == 'integrated' end, 'Reviewed task integrates successfully')
  check(git(root, 'rev-parse', 'HEAD') ~= original_head, 'Integration advances the main branch')
  check(contains(fn.readfile(root .. '/queue.ex')[2], ':human_correction'), 'Integrated code includes the hand correction')
  check(contains(fn.readfile(root .. '/guard.ex')[2], ':human_guard') and fn.filereadable(root .. '/receipt.ex') == 1,
    'Integration contains human cleanup and resumed agent feature across files')
  check(git(root, 'status', '--porcelain') == '', 'Successful integration leaves primary checkout clean')
  check(fn.isdirectory(alpha.workspace.root) == 1, 'Integrated task remains available for inspection')
  local integrated_head = git(root, 'rev-parse', 'HEAD')
  send('[case:integrated_writer] Must not restart an integrated branch')
  check(alpha.job == nil and requests().integrated_writer == nil, 'Integrated tasks cannot silently restart editing')

  select(beta_index)
  review(beta)
  app.integrate()
  wait_for(function() return beta.operation == nil end, 'Conflicting task integration returns safely')
  check(beta.work_status ~= 'integrated' and not beta.reviewed, 'Conflicting task returns to review')
  check(event(beta, 'error', 'conflicts with the main checkout'), 'Conflict is visible in task activity')
  check(git(root, 'rev-parse', 'HEAD') == integrated_head and git(root, 'status', '--porcelain') == '',
    'Conflict preview preserves clean main checkout and history')
  check(contains(fn.readfile(beta.workspace.root .. '/queue.ex')[2], ':beta'), 'Conflict preview preserves task code')
  wait_for(function()
    local saved = vim.json.decode(table.concat(fn.readfile(state.state_file), '\n'))
    return saved.version == 2 and #saved.sessions == #state.sessions and saved.sessions[alpha_index].work_status == 'integrated'
  end, 'Version-two task and workspace history persists')
  local saved = vim.json.decode(table.concat(fn.readfile(state.state_file), '\n'))
  check(saved.contexts[alpha.workspace.root].human_changes['guard.ex'] ~= nil
    and next(saved.contexts[beta.workspace.root].human_changes) == nil, 'Saved state preserves per-worktree human handoffs')
  check(saved.sessions[alpha_index].native_id == alpha.native_id and saved.sessions[beta_index].native_id == beta.native_id,
    'Saved state preserves separate native provider identities')
  check(requests().alpha.cwd == alpha.workspace.root and requests().beta.cwd == beta.workspace.root,
    'Both provider adapters receive their assigned task cwd through the real bridge')
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
pcall(api.nvim_del_augroup_by_name, 'Kiln')
fn.chdir(home)
fn.delete(temp, 'rf')
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') end
print('Kiln parallel integration: ' .. count .. ' assertions passed')
vim.cmd('qa!')

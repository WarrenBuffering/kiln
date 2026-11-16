-- Persistence and lifecycle checks use independent Neovim processes and owned temporary worktrees.
local api, fn = vim.api, vim.fn
local uv = vim.uv or vim.loop
local source = vim.env.KILN_RESTORE_SOURCE or vim.env.KILN_HOME or fn.getcwd()
local script = source .. '/tests/test_restore.lua'
local count, failures = 0, {}
local function check(value, message)
  count = count + 1
  if not value then failures[#failures + 1] = message end
end
local function contains(text, value) return tostring(text):find(value, 1, true) ~= nil end
local function read_json(path) return vim.json.decode(table.concat(fn.readfile(path), '\n')) end
local function write_json(path, value) fn.writefile({ vim.json.encode(value) }, path) end
local function wait_for(predicate, message)
  local result = vim.wait(10000, predicate, 10)
  check(result, message)
  assert(result, message)
end
local function git(root, ...)
  local command = { 'git', '-C', root }
  vim.list_extend(command, { ... })
  local result = vim.system(command, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end
local function run_child(config)
  vim.opt.runtimepath:prepend(source)
  vim.o.columns, vim.o.lines = 160, 50
  vim.o.swapfile, vim.o.backup, vim.o.writebackup, vim.o.modeline = false, false, false, false
  vim.o.hidden, vim.o.equalalways = true, false
  local warnings = {}
  vim.notify = function(message) warnings[#warnings + 1] = tostring(message) end
  vim.cmd('edit ' .. fn.fnameescape(config.root .. '/queue.ex'))
  local initial = api.nvim_get_current_buf()
  local app = require('kiln')
  app.setup({ root = config.root, workflow = false })
  local state = app.state
  local selected = state.sessions[state.selected]
  local function submit()
    app.focus_prompt()
    app.send()
    wait_for(function() return not selected.operation and not selected.job end, 'Restored turn settles')
  end
  local function request()
    assert(fn.filereadable(config.log) == 1, 'Offline bridge did not receive the turn')
    return read_json(config.log)
  end
  if config.case == 'v1' then
    check(#state.sessions == 2, 'Version-1 migration retains both native conversations')
    check(selected.native_id == 'legacy-codex' and selected.id == 'legacy-one', 'Migration preserves original session identities')
    check(selected.draft == 'Continue the queue\nKeep the manual correction', 'Migration preserves multiline draft')
    check(state.sessions[2].status == 'interrupted' and state.sessions[2].job == nil, 'Persisted running task is interrupted, never fabricated as live')
    check(state.view_root == config.root and selected.workspace == nil, 'Legacy conversations remain in main checkout')
    submit()
    local sent = request()
    check(sent.cwd == config.root, 'Legacy follow-up runs in the original checkout')
    check(vim.tbl_contains(sent.args, 'legacy-codex'), 'Legacy follow-up resumes its original native session')
    check(contains(sent.prompt, 'Editor handoff (file-path data): ["queue.ex"]'), 'Pending version-1 human edit survives migration')
    check(selected.last_human_version == 3, 'Successful migrated turn acknowledges only its delivered handoff')
    wait_for(function()
      local saved = read_json(state.state_file)
      return saved.version == 2 and saved.contexts[config.root] ~= nil
    end, 'Migration persists version-2 context state')
  elseif config.case == 'v2' then
    check(state.selected == 2 and selected.native_id == 'task-codex', 'Version-2 restores selected task and native conversation')
    check(selected.status == 'interrupted' and selected.job == nil, 'Interrupted isolated job is not restarted automatically')
    check(fn.getcwd() == config.workspace.root and state.view_root == config.workspace.root, 'Selected task restores its working directory')
    check(api.nvim_buf_get_name(api.nvim_win_get_buf(state.windows.code)) == config.workspace.root .. '/queue.ex',
      'Startup maps the opened main file into the restored task worktree')
    check(api.nvim_buf_is_valid(initial) and api.nvim_buf_get_name(initial) == config.root .. '/queue.ex',
      'Startup preserves the original main-checkout buffer')
    check(state.follow == false and selected.human_control == true, 'Per-worktree follow/manual-control state is restored')
    check(state.contexts[config.root].human_version == 9 and state.human_version == 5, 'Main and task human histories remain separate')
    wait_for(function()
      for _, file in ipairs(state.changes.list()) do if file.path == 'queue.ex' then return true end end
      return false
    end, 'Task committed changes remain visible against original baseline after restart')
    state.changes.show_diff('queue.ex', state.windows.code)
    wait_for(function() return state.changes.is_diff_open() end, 'Restored task opens an actual baseline diff')
    local baseline_visible = false
    for _, win in ipairs(api.nvim_list_wins()) do
      local buf = api.nvim_win_get_buf(win)
      if contains(vim.wo[win].winbar, 'BASE  /') then
        baseline_visible = contains(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n'), ':original')
      end
    end
    check(baseline_visible, 'Restored baseline is creation commit, not task current HEAD')
    submit()
    local sent = request()
    check(sent.cwd == config.workspace.root, 'Restored provider runs inside task checkout')
    check(contains(sent.prompt, 'Editor handoff (file-path data): ["queue.ex"]') and not contains(sent.prompt, 'main-only.ex'),
      'Task handoff includes only its own saved files')
    check(selected.last_human_version == 5 and state.contexts[config.root].human_version == 9, 'Acknowledgment remains scoped to restored task')
    local code = api.nvim_win_get_buf(state.windows.code)
    api.nvim_buf_set_lines(code, 1, 2, false, { '  def value, do: :human_after_restore' })
    api.nvim_buf_call(code, function() vim.cmd('write') end)
    check(state.human_version == 6 and state.contexts[config.root].human_version == 9, 'Actual saved edit advances only restored worktree history')
    check(contains(fn.readfile(config.root .. '/queue.ex')[2], ':original'), 'Restored handcoding leaves main checkout untouched')
  elseif config.case == 'missing' or config.case == 'mismatch' then
    check(selected.workspace.root == config.workspace.root and selected.native_id == 'task-codex',
      'Unavailable worktree retains its task metadata and native session')
    submit()
    check(selected.job == nil and fn.filereadable(config.log) == 0, 'Invalid task worktree never falls back to a main-checkout provider')
    check(selected.draft == 'Continue isolated work', 'Rejected isolated turn preserves its draft')
    check(selected.work_status == 'missing', 'Invalid worktree is explicitly marked unavailable')
    app.terminal()
    wait_for(function() return not selected.operation end, 'Native worktree validation settles')
    check(selected.native_job == nil and fn.filereadable(config.log) == 0, 'Native approval session also refuses invalid worktree')
    check(contains(fn.readfile(config.root .. '/queue.ex')[2], ':original'), 'Invalid worktree path cannot mutate main files')
  elseif config.case == 'creation_failure' then
    check(selected.workspace == nil and selected.isolated, 'Interrupted creation restores as an unprovisioned isolated draft')
    check(selected.reviewed == false and selected.review_fingerprint == nil, 'Interrupted workspace operation drops stale review approval')
    submit()
    check(selected.workspace == nil and selected.work_status == 'missing', 'Worktree creation failure remains explicit')
    check(selected.draft == 'Keep this task draft' and selected.native_id == nil, 'Failed creation preserves task draft without creating native session')
    check(fn.filereadable(config.log) == 0, 'Creation failure does not launch a provider in main checkout')
  elseif config.case == 'invalid_metadata' then
    check(#state.sessions == 1 and selected.id == 'safe-main', 'Malformed persisted worktree metadata is rejected')
    check(selected.workspace == nil and state.view_root == config.root, 'Remaining valid main session restores normally')
    check(contains(table.concat(warnings, '\n'), 'invalid worktree metadata'), 'Malformed task is reported to the user')
  end
  write_json(config.result, { count = count, failures = failures })
end

local function orchestrate()
  local temp = fn.tempname() .. '-kiln-restore'
  fn.mkdir(temp .. '/project', 'p')
  fn.mkdir(temp .. '/fake/python', 'p')
  local root = uv.fs_realpath(temp .. '/project')
  git(root, 'init', '-q')
  git(root, 'config', 'user.name', 'WarrenBuffering')
  git(root, 'config', 'user.email', 'WarrenBuffering@users.noreply.github.com')
  fn.writefile({ 'defmodule Queue do', '  def value, do: :original', 'end' }, root .. '/queue.ex')
  git(root, 'add', 'queue.ex'); git(root, 'commit', '-qm', 'Restore fixture')
  fn.writefile(vim.split([=[import json, os, pathlib, sys
args = sys.argv[1:]
prompt = sys.stdin.read()
pathlib.Path(os.environ["KILN_RESTORE_LOG"]).write_text(json.dumps({"cwd": os.getcwd(), "args": args, "prompt": prompt}))
native = args[args.index("--session") + 1] if "--session" in args else "new-offline-session"
print(json.dumps({"type": "session", "id": native}), flush=True)
print(json.dumps({"type": "done", "ok": True, "exit_code": 0}), flush=True)
]=], '\n', { plain = true }), temp .. '/fake/python/bridge.py')
  local function create(id)
    local result = vim.system({ fn.exepath('python3'), source .. '/python/workspaces.py', 'create', '--root', root,
      '--storage', temp .. '/worktrees', '--id', id }, { text = true }):wait()
    assert(result.code == 0, result.stdout .. result.stderr)
    local created = vim.json.decode(result.stdout)
    assert(created.ok, created.error)
    return { root = created.root, branch = created.branch, base = created.base, repo_root = created.repo_root }
  end
  local workspaces = { v2 = create('restore-valid'), missing = create('restore-missing'), mismatch = create('restore-mismatch') }
  fn.writefile({ 'defmodule Queue do', '  def value, do: :task_committed', 'end' }, workspaces.v2.root .. '/queue.ex')
  git(workspaces.v2.root, 'add', 'queue.ex'); git(workspaces.v2.root, 'commit', '-qm', 'Task change before restart')
  git(root, 'worktree', 'remove', '--', workspaces.missing.root)
  git(workspaces.mismatch.root, 'checkout', '-qb', 'not-the-owned-branch')
  local function session(id, extra)
    return vim.tbl_extend('force', { id = id, provider = 'codex', model = '', mode = 'edit', status = 'idle',
      native_id = 'task-codex', title = 'Restored task', task = 'Continue queue', events = {}, draft = 'Continue isolated work',
      last_human_version = 2 }, extra or {})
  end
  local cases = { 'v1', 'v2', 'missing', 'mismatch', 'creation_failure', 'invalid_metadata' }
  for _, case in ipairs(cases) do
    local dir = temp .. '/' .. case
    fn.mkdir(dir .. '/sessions', 'p')
    local case_root = root
    local saved
    if case == 'v1' then
      saved = { version = 1, selected = 1, human_version = 3, human_changes = { ['queue.ex'] = { version = 3 } },
        file_activity = { ['queue.ex'] = { actor = 'human' } }, sessions = {
          session('legacy-one', { native_id = 'legacy-codex', draft = 'Continue the queue\nKeep the manual correction', status = 'done' }),
          session('legacy-two', { provider = 'claude', native_id = 'legacy-claude', status = 'running' }),
        } }
    elseif case == 'v2' then
      saved = { version = 2, selected = 2, contexts = {
        [root] = { human_version = 9, human_changes = { ['main-only.ex'] = { version = 9 } } },
        [workspaces.v2.root] = { human_version = 5, human_changes = { ['queue.ex'] = { version = 5 } }, follow = false,
          human_control = true, human = { saved = true, path = 'queue.ex' }, file_activity = { ['queue.ex'] = { actor = 'human' } } },
      }, sessions = { session('main'), session('isolated', { isolated = true, workspace = workspaces.v2, status = 'running' }) } }
    elseif case == 'missing' or case == 'mismatch' then
      saved = { version = 2, selected = 1, contexts = {}, sessions = {
        session(case, { isolated = true, workspace = workspaces[case], status = 'stopped' }) } }
    elseif case == 'creation_failure' then
      fn.mkdir(temp .. '/not-a-repository', 'p')
      case_root = uv.fs_realpath(temp .. '/not-a-repository')
      fn.writefile({ 'original' }, case_root .. '/queue.ex')
      saved = { version = 2, selected = 1, contexts = {}, sessions = {
        session('pending-create', { isolated = true, native_id = vim.NIL, draft = 'Keep this task draft',
          work_status = 'creating', reviewed = true, review_fingerprint = string.rep('a', 64) }) } }
      saved.sessions[1].native_id = nil
    else
      saved = { version = 2, selected = 2, contexts = {}, sessions = {
        session('bad-metadata', { isolated = true, workspace = { root = false, branch = 'kiln/task-bad', base = 'bad' } }),
        session('safe-main'),
      } }
    end
    write_json(dir .. '/sessions/' .. fn.sha256(case_root) .. '.json', saved)
    local config = { case = case, root = case_root, workspace = workspaces[case], log = dir .. '/request.json', result = dir .. '/result.json' }
    write_json(dir .. '/config.json', config)
    local result = vim.system({ fn.exepath('nvim'), '--headless', '-u', 'NONE', '-i', 'NONE', '-n',
      '-c', 'luafile ' .. fn.fnameescape(script) }, { text = true, timeout = 25000, env = {
        KILN_RESTORE_SOURCE = source, KILN_RESTORE_CONFIG = dir .. '/config.json', KILN_RESTORE_LOG = config.log,
        KILN_HOME = temp .. '/fake', KILN_STATE_DIR = dir,
      } }):wait()
    if fn.filereadable(config.result) == 1 then
      local report = read_json(config.result)
      count = count + report.count
      for _, failure in ipairs(report.failures) do failures[#failures + 1] = case .. ': ' .. failure end
    else failures[#failures + 1] = case .. ': child did not report results: ' .. (result.stderr or '') end
    check(result.code == 0, case .. ': headless lifecycle exits cleanly: ' .. (result.stderr or ''))
  end
  fn.delete(temp, 'rf')
end

local ok, err = xpcall(function()
  if vim.env.KILN_RESTORE_CONFIG then run_child(read_json(vim.env.KILN_RESTORE_CONFIG)) else orchestrate() end
end, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') end
if #failures > 0 then
  io.stderr:write(table.concat(failures, '\n') .. '\n')
  vim.cmd('cquit 1')
end
if not vim.env.KILN_RESTORE_CONFIG then print('Kiln restore lifecycle: ' .. count .. ' assertions passed') end
vim.cmd('qa!')

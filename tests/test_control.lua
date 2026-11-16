-- Manager workflow integration. The temporary bridge is offline and never calls a provider.
local api, fn = vim.api, vim.fn
local uv = vim.uv or vim.loop
local home = vim.env.KILN_HOME or fn.getcwd()
vim.opt.runtimepath:prepend(home)
vim.o.columns, vim.o.lines = 160, 50
vim.o.swapfile, vim.o.backup, vim.o.writebackup, vim.o.modeline = false, false, false, false
vim.o.equalalways, vim.o.hidden = false, true
local temp = fn.tempname() .. '-kiln-control'
fn.mkdir(temp .. '/project', 'p')
fn.mkdir(temp .. '/fake/python', 'p')
fn.mkdir(temp .. '/state', 'p')
local root = uv.fs_realpath(temp .. '/project')
vim.env.KILN_HOME, vim.env.KILN_STATE_DIR = temp .. '/fake', temp .. '/state'
local warnings, count = {}, 0
vim.notify = function(message) warnings[#warnings + 1] = tostring(message) end
local function check(condition, message)
  count = count + 1
  assert(condition, message)
end
local function equal(actual, expected, message)
  check(vim.deep_equal(actual, expected), message .. '\nactual: ' .. vim.inspect(actual) .. '\nexpected: ' .. vim.inspect(expected))
end
local function wait_for(predicate, message)
  check(vim.wait(7000, predicate, 10), message)
end
local function contains(text, value) return tostring(text):find(value, 1, true) ~= nil end
local function git(...)
  local args = { 'git', '-C', root }
  vim.list_extend(args, { ... })
  local result = vim.system(args, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end
local function requests()
  local result = {}
  if fn.filereadable(root .. '/requests.jsonl') == 1 then
    for _, line in ipairs(fn.readfile(root .. '/requests.jsonl')) do result[#result + 1] = vim.json.decode(line) end
  end
  return result
end
local app
local function run_views()
  local control = require('kiln.control')
  local state = {
    root = '/project', selected = 5, follow = false, control_width = 39,
    sessions = {
      { provider = 'codex', model = 'builder-model', mode = 'edit', status = 'running', job = 10,
        task = 'Build queue', title = 'Last prompt is not the task', events = {
          { type = 'file', path = '/project/app.py' }, { type = 'file', path = 'app.py' },
          { type = 'tool', name = 'Shell', status = 'done', text = 'Unverified provider output' },
        } },
      { provider = 'claude', mode = 'plan', status = 'done', task = 'Review types', events = {} },
      { provider = 'codex', mode = 'edit', status = 'error', task = 'Fix a failure', events = {} },
      { provider = 'claude', mode = 'edit', status = 'running', task = 'Interrupted work', events = {} },
      { provider = 'claude', model = 'review-model', mode = 'plan', status = 'running', job = 11,
        task = 'Review current changes', events = {}, usage = { input_tokens = 250, output_tokens = 80 } },
    },
    changed_files = { { status = 'M', path = 'app.py' }, { status = 'M', path = 'a\nodd.txt' } },
    file_activity = { ['app.py'] = { actor = 'human' }, ['a\nodd.txt'] = { actor = 'agent', provider = 'codex' } },
    human = { active = false, saved = true, path = '/project/app.py' },
  }
  local original = vim.deepcopy(state)
  local monitor, overview = control.monitor(state), control.overview(state)
  equal(state, original, 'Rendering manager views does not mutate real session or ownership state')
  local text = table.concat(monitor.lines, '\n')
  local all = table.concat(overview.lines, '\n')
  check(contains(text, 'OWNER #1 CODEX'), 'A distant edit owner stays visible while a reviewer is selected')
  check(contains(text, '1 review'), 'Only a live plan job counts as an active reviewer')
  check(contains(text, 'REVIEWER') and contains(text, 'CLAUDE'), 'Selected role and provider come from the actual session')
  check(contains(text, 'YOU SAVED  app.py'), 'A recorded human save is distinguished from provider work')
  check(contains(text, 'a\\nodd.txt'), 'Filenames containing newlines stay on one display row')
  check(contains(all, 'Build queue') and not contains(all, 'Last prompt is not the task'), 'Assigned task labels take precedence over prompt-derived titles')
  check(contains(all, 'FILES 1  app.py'), 'Repeated relative and absolute events count one reported file')
  check(contains(all, 'No file changes reported'), 'Tasks without file events do not invent work')
  check(not text:match('%d+%%') and not all:match('%d+%%'), 'Token counts and elapsed work never become invented completion percentages')
  for _, view in ipairs({ monitor, overview }) do
    equal(view.height, #view.lines, 'View height reports its actual line count')
    for row, item in pairs(view.rows) do
      check(row >= 1 and row <= #view.lines, 'Each action maps to an existing display row')
      if item.session then check(state.sessions[item.session] ~= nil, 'Session row points to an existing task') end
      if item.path then check(item.path == 'app.py' or item.path == 'a\nodd.txt', 'File action preserves the original path identity') end
    end
  end
  local owner_action
  for row, item in pairs(monitor.rows) do
    if contains(monitor.lines[row], 'OWNER') then owner_action = item.session end
  end
  equal(owner_action, 1, 'The edit-owner row selects the actual writer rather than the selected reviewer')
  equal(control.status(state.sessions[4]), 'INTERRUPTED', 'Persisted running text without a process does not claim active work')
  equal(control.status(state.sessions[2]), 'REVIEW', 'Provider completion requests review rather than claiming verified success')
  state.sessions[2].reviewed = true
  equal(control.status(state.sessions[2]), 'REVIEWED', 'Only an explicit review flag produces reviewed status')
  state.sessions[1].status, state.sessions[1].stopping = 'stopping', true
  equal(control.status(state.sessions[1]), 'STOPPING', 'A stop request remains stopping while its process lives')
  check(contains(table.concat(control.monitor(state).lines, '\n'), 'OWNER #1 CODEX'), 'Stopping does not prematurely release edit ownership')
  state.sessions[1].job, state.sessions[1].native_job, state.sessions[1].stopping = nil, 12, nil
  state.sessions[1].status = 'native'
  equal(control.status(state.sessions[1]), 'NATIVE', 'A native provider process remains an active owner')
  state.sessions[3].job = 13
  check(contains(table.concat(control.monitor(state).lines, '\n'), 'MULTIPLE'), 'Broken single-writer invariants are exposed rather than hidden')
  state.sessions[1].native_job, state.sessions[3].job = nil, nil
  check(contains(table.concat(control.monitor(state).lines, '\n'), 'No agent writer'), 'Stale status strings never create a fictitious edit owner')
  state.sessions[5].role = 'Quality reviewer'
  equal(control.role(state.sessions[5]), 'QUALITY REVIEWER', 'An explicit descriptive role is displayed without changing permissions')
  state.sessions[5].events = {
    { type = 'error', text = 'Old error from an earlier turn' },
    { type = 'message', role = 'user', text = 'New request' },
  }
  check(not contains(table.concat(control.monitor(state).lines, '\n'), 'Needs your attention'), 'A new turn does not inherit a prior turn\'s last-action warning')
  state.control_width = 24
  state.sessions[5].task = string.rep('界😀', 16)
  local narrow = control.monitor(state)
  for _, line in ipairs(narrow.lines) do
    check(fn.strdisplaywidth(line) <= 24, 'Narrow-terminal rows respect display cells for multibyte task text')
    check(not line:find('[\r\n]'), 'A monitor row cannot inject terminal lines')
  end
  local empty = control.monitor({ sessions = {}, selected = 1 })
  check(contains(table.concat(empty.lines, '\n'), 'No agent task yet'), 'An empty task board stays truthful and usable')
end
local function run_ui()
  git('init', '-q')
  fn.writefile({ 'print("original")' }, root .. '/app.py')
  fn.writefile({ 'print("board")' }, root .. '/board.py')
  git('add', 'app.py', 'board.py')
  git('-c', 'user.name=WarrenBuffering', '-c', 'user.email=WarrenBuffering@users.noreply.github.com', 'commit', '-qm', 'Manager workflow fixture')
  fn.writefile(vim.split([=[import json, pathlib, sys, time
args = sys.argv[1:]
provider = args[args.index("--provider") + 1]
prompt = sys.stdin.read()
with pathlib.Path("requests.jsonl").open("a") as output:
    output.write(json.dumps({"provider": provider, "args": args, "prompt": prompt}) + "\n")
def emit(value):
    print(json.dumps(value), flush=True)
if prompt.startswith("fail before accept"):
    emit({"type": "error", "text": "Offline authentication failure before accepting the handoff"})
    emit({"type": "done", "ok": False, "exit_code": 7})
    sys.exit(7)
emit({"type": "session", "id": "control-native-" + provider})
emit({"type": "message", "role": "assistant", "text": "Inspecting the assigned task.", "id": "narration"})
if provider == "codex" and prompt.startswith("hold writer"):
    deadline = time.monotonic() + 15
    while not pathlib.Path("release-writer").exists() and time.monotonic() < deadline:
        emit({"type": "tool", "name": "Read", "status": "running", "text": "app.py", "id": "reading"})
        time.sleep(0.1)
emit({"type": "done", "ok": True, "exit_code": 0})
]=], '\n', { plain = true }), temp .. '/fake/python/bridge.py')
  vim.cmd('edit ' .. fn.fnameescape(root .. '/app.py'))
  app = require('kiln')
  app.setup({ root = root, workflow = false })
  local state = app.state
  local writer = state.sessions[state.selected]
  local writer_index = state.selected
  local function prompt(text)
    api.nvim_buf_set_lines(state.buffers.prompt, 0, -1, false, { text })
  end
  local function hover_task(index)
    app.control()
    local overview = state.overview
    check(overview and api.nvim_win_is_valid(overview.win), 'Task overview opens a real Vim window')
    local row
    for line, item in pairs(overview.rows) do if item.session == index then row = line; break end end
    check(row ~= nil, 'Task overview maps the requested session to an actionable row')
    api.nvim_win_set_cursor(overview.win, { row, 0 })
  end
  local function select_task(index)
    hover_task(index)
    local mapping = fn.maparg('<CR>', 'n', false, true)
    check(type(mapping.callback) == 'function', 'Overview Enter has a real session-selection callback')
    mapping.callback()
    equal(state.selected, index, 'Overview Enter selects the requested existing session')
    equal(api.nvim_get_current_win(), state.windows.prompt, 'Explicit task selection focuses its prompt')
  end

  app.task('Build queue')
  equal(writer.task, 'Build queue', 'Task label is stored separately from a conversation title')
  app.review()
  check(not writer.reviewed, 'An idle task cannot be marked reviewed')
  prompt('hold writer')
  app.send()
  wait_for(function() return writer.native_id == 'control-native-codex' and writer.job ~= nil end, 'The first editing task owns a running bridge job')
  equal(writer.task, 'Build queue', 'Starting a turn preserves its manager-assigned task label')
  app.review()
  check(not writer.reviewed, 'A running task cannot be marked reviewed')

  app.provider('claude')
  local reviewer = state.sessions[state.selected]
  local reviewer_index = state.selected
  app.mode('plan')
  app.task('Review queue')
  prompt('Review without editing')
  app.send()
  wait_for(function() return reviewer.job == nil and reviewer.status == 'done' end, 'A parallel plan reviewer completes while the writer keeps running')
  check(writer.job ~= nil, 'Finishing a reviewer does not release the writer')
  app.review()
  check(reviewer.reviewed, 'A completed task can be explicitly marked reviewed')
  app.mode('edit')
  prompt('Attempt a second editor')
  app.send()
  equal(reviewer.job, nil, 'Selecting a reviewer does not allow a second edit owner')
  check(contains(warnings[#warnings], 'already owns this workspace'), 'Ownership denial explains the active writer')
  app.mode('plan')

  -- A real buffer write is a human action; provider disk writes must not be mislabeled as one.
  if state.follow then app.follow() end
  app.focus_code()
  vim.cmd('edit ' .. fn.fnameescape(root .. '/board.py'))
  local human_buffer = api.nvim_get_current_buf()
  api.nvim_buf_set_lines(human_buffer, 0, -1, false, { 'print("human board change")' })
  api.nvim_win_set_cursor(state.windows.code, { 1, 6 })
  vim.cmd.write()
  local human_version = state.human_version
  check(type(human_version) == 'number' and human_version > 0, 'An actual save records a human version')
  check(state.human_changes['board.py'] ~= nil, 'The human save records its project-relative path')
  equal(state.human_changes['board.py'].version, human_version, 'The saved path is tied to the observed human version')
  check(not reviewer.reviewed, 'A human write invalidates an earlier task review')
  check(writer.job ~= nil, 'Human-save attribution does not pretend that the edit owner stopped')
  vim.wait(250, function() return false end, 10)
  equal(api.nvim_get_current_win(), state.windows.code, 'Concurrent activity and human-save rendering preserve code focus')
  equal(api.nvim_get_current_buf(), human_buffer, 'Concurrent activity preserves the human-selected file')
  equal(api.nvim_win_get_cursor(state.windows.code), { 1, 6 }, 'Concurrent activity preserves the human cursor')
  equal(api.nvim_buf_get_lines(human_buffer, 0, -1, false), { 'print("human board change")' }, 'Human saved text stays visible')

  -- An external disk write is not a Neovim human save.
  fn.writefile({ 'print("external disk change")' }, root .. '/app.py')
  state.changes.scan()
  vim.wait(150, function() return false end, 10)
  equal(state.human_version, human_version, 'External file refresh does not invent a human save')
  check(state.human_changes['app.py'] == nil, 'External disk writes are absent from the human handoff list')

  prompt('Reviewer draft survives task selection')
  fn.writefile({ 'release' }, root .. '/release-writer')
  wait_for(function() return writer.job == nil and writer.status == 'done' end, 'The writer releases ownership only after its bridge exits')
  select_task(writer_index)
  equal(reviewer.draft, 'Reviewer draft survives task selection', 'Task selection saves the previous prompt draft')
  equal(writer.native_id, 'control-native-codex', 'Selecting a task retains its original native session')
  app.review()
  check(writer.reviewed, 'A finished writer can be explicitly marked reviewed')

  -- Unsaved code still blocks the next editing turn without consuming its human handoff.
  api.nvim_buf_set_lines(human_buffer, 0, -1, false, { 'print("unsaved human work")' })
  local checkpoint = writer.last_human_version
  prompt('Continue after the human save')
  app.send()
  equal(writer.job, nil, 'Unsaved human work blocks a new editing turn')
  equal(writer.last_human_version, checkpoint, 'A blocked send does not acknowledge unseen human edits')
  check(contains(warnings[#warnings], 'Save your modified'), 'Unsaved guard tells the user what is required')
  equal(api.nvim_buf_get_lines(human_buffer, 0, -1, false), { 'print("unsaved human work")' }, 'Blocked dispatch preserves unsaved text')
  api.nvim_buf_set_lines(human_buffer, 0, -1, false, { 'print("human board change")' })
  vim.bo[human_buffer].modified = false
  prompt('fail before accept')
  app.send()
  wait_for(function() return writer.job == nil and writer.status == 'error' end, 'A failed bridge turn returns an error without accepting the handoff')
  equal(writer.last_human_version, checkpoint, 'An authentication or startup failure does not acknowledge human edits')
  equal(writer.pending_human_version, nil, 'A failed turn clears its pending handoff checkpoint')
  check(contains(requests()[#requests()].prompt, '"board.py"'), 'The failed attempt actually received the pending human-save path')
  app.review()
  check(not writer.reviewed, 'A failed task cannot be marked reviewed')
  prompt('Continue after the human save')
  app.send()
  check(not writer.reviewed, 'A new turn clears the prior manual review')
  wait_for(function() return writer.job == nil and writer.status == 'done' end, 'Original writer resumes after the human handoff')
  equal(writer.task, 'Build queue', 'Follow-up prompts do not replace the task label')
  equal(writer.last_human_version, human_version, 'A successful turn acknowledges this session\'s human changes')
  local sent = requests()
  local writer_request = sent[#sent]
  equal(writer_request.provider, 'codex', 'The handoff goes to the original editing provider')
  check(vim.tbl_contains(writer_request.args, 'control-native-codex'), 'Human handback resumes the original native session')
  check(contains(writer_request.prompt, '"board.py"'), 'The successful retry receives the same human-save paths as JSON data')
  check(not contains(writer_request.prompt, '"app.py"'), 'Human handback excludes external writes not made by the user')

  select_task(reviewer_index)
  equal(api.nvim_buf_get_lines(state.buffers.prompt, 0, -1, false), { 'Reviewer draft survives task selection' }, 'Returning to a task restores its draft')
  check((reviewer.last_human_version or 0) < human_version, 'One session receiving human edits does not consume another session\'s handoff')
  app.send()
  wait_for(function() return reviewer.job == nil and reviewer.status == 'done' end, 'The reviewer independently receives the human changes')
  sent = requests()
  equal(sent[#sent].provider, 'claude', 'Reviewer handback stays with Claude')
  check(contains(sent[#sent].prompt, '"board.py"'), 'The reviewer also receives the pending human-save path')
  equal(reviewer.last_human_version, human_version, 'Reviewer checkpoint advances independently')
  equal(reviewer.task, 'Review queue', 'Reviewer task label survives the resumed turn')
  wait_for(function()
    local saved = vim.json.decode(table.concat(fn.readfile(state.state_file), '\n'))
    return saved.sessions[writer_index].task == 'Build queue'
      and saved.sessions[reviewer_index].task == 'Review queue'
      and saved.sessions[writer_index].last_human_version == human_version
  end, 'Task labels and human handoff checkpoints are persisted')

  -- Overview shortcuts operate on the hovered task, not the previously selected one.
  hover_task(writer_index)
  local review_mapping = fn.maparg('<Space>v', 'n', false, true)
  check(type(review_mapping.callback) == 'function' and review_mapping.buffer == 1, 'Overview review has a buffer-local keyboard action')
  review_mapping.callback()
  equal(state.selected, writer_index, 'Overview review selects the hovered task')
  check(writer.reviewed and not reviewer.reviewed, 'Overview review changes only the hovered completed task')
  hover_task(reviewer_index)
  local task_mapping = fn.maparg('<Space>q', 'n', false, true)
  check(type(task_mapping.callback) == 'function' and task_mapping.buffer == 1, 'Overview rename has a buffer-local keyboard action')
  task_mapping.callback()
  check(vim.bo[api.nvim_get_current_buf()].modifiable, 'Overview rename opens the hovered task objective editor')
  api.nvim_buf_set_lines(0, 0, -1, false, { 'Review the human handoff' })
  fn.maparg('<C-s>', 'n', false, true).callback()
  equal(state.selected, reviewer_index, 'Overview rename selects the hovered task')
  equal(reviewer.task, 'Review the human handoff', 'Overview rename updates the hovered task objective')
  equal(writer.task, 'Build queue', 'Renaming a hovered task leaves the previous selected task unchanged')
end

local ok, err = xpcall(function() run_views(); run_ui() end, debug.traceback)
if app then
  app.state.closing = true
  if app.state.changes then app.state.changes.stop() end
  for _, session in ipairs(app.state.sessions) do
    if session.job then fn.jobstop(session.job) end
    if session.native_job then fn.jobstop(session.native_job) end
  end
  vim.wait(3000, function()
    for _, session in ipairs(app.state.sessions) do if session.job or session.native_job then return false end end
    return true
  end, 10)
end
pcall(api.nvim_del_augroup_by_name, 'Kiln')
fn.delete(temp, 'rf')
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') end
print('Kiln manager control: ' .. count .. ' assertions passed')
vim.cmd('qa!')

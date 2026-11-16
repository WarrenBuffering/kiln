-- One chat plans and executes its dossier through both real bridge adapters.
-- Provider processes below are local protocol fixtures, never model requests.
local api, fn = vim.api, vim.fn
local uv = vim.uv or vim.loop
local home = vim.env.KILN_HOME or fn.getcwd()
local provider_name = vim.env.KILN_CONVERSATION_CASE
local restore_config = vim.env.KILN_CONVERSATION_RESTORE
if restore_config and restore_config ~= '' then
  local config = vim.json.decode(table.concat(fn.readfile(restore_config), '\n'))
  vim.opt.runtimepath:prepend(home)
  vim.o.columns, vim.o.lines = 180, 52
  vim.o.swapfile, vim.o.backup, vim.o.writebackup, vim.o.modeline = false, false, false, false
  vim.o.equalalways, vim.o.hidden = false, true
  vim.env.KILN_STATE_DIR = config.storage
  vim.cmd.edit(fn.fnameescape(config.root .. '/engine.ex'))
  local restored = require('kiln')
  restored.setup({ root = config.root, workflow = true })
  local state, session = restored.state, restored.state.sessions[1]
  local assertions = 0
  local function verify(value, message) assertions = assertions + 1; assert(value, message) end
  verify(#state.sessions == 1 and session.native_id == config.native and session.provider == config.provider,
    'Restart restores the same chat and native provider identity')
  verify(session.workflow.phase == 'paused' and not session.workflow.auto_run and not session.job,
    'Restart never automatically launches persisted implementation')
  verify(session.workflow.steps.alpha.status == 'done' and session.workflow.steps.beta.status == 'pending'
    and session.workflow.steps.gamma.status == 'pending', 'Restart preserves actual per-step progress')
  verify(session.draft == config.draft and table.concat(api.nvim_buf_get_lines(state.buffers.prompt, 0, -1, false), '\n') == config.draft,
    'Restart preserves the unsent chat draft in its visible prompt')
  local history = vim.json.encode(session.events)
  verify(history:find('Should readiness', 1, true) and history:find('Alpha implementation is visible', 1, true),
    'Restart preserves both planning and implementation history in the same chat')
  verify(api.nvim_win_is_valid(state.windows.steps)
    and api.nvim_win_get_position(state.windows.steps)[2] < api.nvim_win_get_position(state.windows.code)[2],
    'Restart restores the accepted dossier on the left')
  vim.wait(650, function() return false end, 10)
  verify(#fn.readfile(config.log) == config.requests, 'Restoring the session submits no provider request')
  fn.writefile({ vim.json.encode({ count = assertions }) }, config.result)
  vim.cmd('qa!')
  return
end
if not provider_name or provider_name == '' then
  local total = 0
  for _, provider in ipairs({ 'codex', 'claude' }) do
    local result = vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE', '-n',
      '-c', 'luafile ' .. home .. '/tests/test_conversation.lua' }, {
      text = true, env = { KILN_HOME = home, KILN_CONVERSATION_CASE = provider },
    }):wait(60000)
    if result.code ~= 0 then
      io.stderr:write(provider .. ' conversation fixture failed:\n' .. (result.stdout or '') .. (result.stderr or ''))
      vim.cmd('cquit 1')
    end
    local output = (result.stdout or '') .. (result.stderr or '')
    local assertions = tonumber(output:match('CONVERSATION_ASSERTIONS=(%d+)'))
    assert(assertions, output)
    total = total + assertions
  end
  print('Kiln single conversation: ' .. total .. ' assertions passed')
  vim.cmd('qa!')
  return
end
vim.opt.runtimepath:prepend(home)
vim.o.columns, vim.o.lines = 180, 52
vim.o.swapfile, vim.o.backup, vim.o.writebackup, vim.o.modeline = false, false, false, false
vim.o.equalalways, vim.o.hidden = false, true
local temp = fn.tempname() .. '-kiln-conversation-' .. provider_name
fn.mkdir(temp .. '/project', 'p'); fn.mkdir(temp .. '/logs', 'p')
local root = uv.fs_realpath(temp .. '/project')
vim.env.KILN_HOME, vim.env.KILN_STATE_DIR = home, temp .. '/state'
vim.env.KILN_CONVERSATION_LOGS = temp .. '/logs'
local app, count, warnings = nil, 0, {}
vim.notify = function(message) warnings[#warnings + 1] = tostring(message) end
local function check(value, message) count = count + 1; assert(value, message) end
local function contains(value, text) return tostring(value or ''):find(text, 1, true) ~= nil end
local function wait_for(predicate, message)
  local success = vim.wait(12000, predicate, 10)
  if not success and app then
    message = message .. '\nWorkflow: ' .. vim.inspect(app.state.sessions[1].workflow)
      .. '\nWarnings: ' .. vim.inspect(warnings)
      .. '\nLast events: ' .. vim.inspect(vim.list_slice(app.state.sessions[1].events, -6))
  end
  check(success, message)
end
local function git(...)
  local command = { 'git', '-C', root }; vim.list_extend(command, { ... })
  local result = vim.system(command, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end
local function requests()
  local result = {}
  local path = temp .. '/logs/requests.jsonl'
  if fn.filereadable(path) == 1 then
    for _, line in ipairs(fn.readfile(path)) do result[#result + 1] = vim.json.decode(line) end
  end
  return result
end
local function request(step, attempt)
  for _, value in ipairs(requests()) do
    if value.step == step and value.attempt == (attempt or 1) then return value end
  end
end
local function text(buf) return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n') end
local function send(prompt)
  app.focus_prompt()
  api.nvim_buf_set_lines(app.state.buffers.prompt, 0, -1, false, { prompt })
  app.send()
end
local function event(session, value)
  for _, item in ipairs(session.events) do if contains(item.text, value) then return item end end
end
local function has_highlight(buf)
  for _, namespace in pairs(api.nvim_get_namespaces()) do
    for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })) do
      for _, key in ipairs({ 'hl_group', 'line_hl_group', 'sign_hl_group' }) do
        if tostring(mark[4][key] or ''):find('^KilnEdit') then return true end
      end
    end
  end
  return false
end
local function highlighted_step(id)
  local state = app.state
  for _, namespace in pairs(api.nvim_get_namespaces()) do
    for _, mark in ipairs(api.nvim_buf_get_extmarks(state.buffers.steps, namespace, 0, -1, { details = true })) do
      if mark[4].hl_group == 'KilnCurrent' then
        local row = api.nvim_buf_get_lines(state.buffers.steps, mark[2], mark[2] + 1, false)[1] or ''
        if contains(row, id == 'alpha' and 'Define readiness' or id == 'beta' and 'Connect consumer' or 'Document contract') then return true end
      end
    end
  end
  return false
end
local function gate(name) fn.writefile({ 'release' }, temp .. '/logs/' .. name) end
local function action_is(control, fragment)
  local current = app.state.current_action or {}
  return current.control == control and (not fragment or contains(current.text, fragment))
end
local function close_popup()
  local win = api.nvim_get_current_win()
  check(api.nvim_win_get_config(win).relative ~= '', 'Inspection opens a focused popup')
  api.nvim_win_close(win, true)
end
local function observed(step)
  return require('kiln.evidence').summary(app.state.sessions[1], step)
end
local proposed = table.concat({ '# Readiness feature', 'Goal: Explain and expose queue readiness.',
  'Approach: Define readiness, connect its consumer, then document the verified contract.',
  'Why this approach: Consumer and documentation need the actual readiness behavior.',
  'Constraints: Plain Elixir. Preserve human edits.', '',
  '## Step alpha: Define readiness', 'Outcome: Engine.ready?/0 returns the readiness decision.',
  'Why: The consumer requires a concrete readiness function.', 'Verify: Exercise Engine.ready?/0.', 'Depends: none', '',
  '## Step beta: Connect consumer', 'Outcome: Consumer reads the actual Engine readiness.',
  'Why: The caller needs the implemented readiness function.', 'Verify: Exercise Consumer.ready?/0.',
  'Depends: alpha', 'Dependency reason: Consumer calls Engine.ready?/0.', '',
  '## Step gamma: Document contract', 'Outcome: Explain the readiness contract to callers.',
  'Why: Callers need the actual consumer behavior documented.', 'Verify: Check the example against Consumer.',
  'Depends: beta', 'Dependency reason: The example must describe the completed consumer.' }, '\n')
local function run()
  git('init', '-q'); git('config', 'user.name', 'WarrenBuffering')
  git('config', 'user.email', 'WarrenBuffering@users.noreply.github.com')
  fn.writefile({ 'defmodule Engine do', '  def ready?, do: false', 'end' }, root .. '/engine.ex')
  git('add', '.'); git('commit', '-qm', 'Single conversation fixture')
  local head = git('rev-parse', 'HEAD')
  fn.writefile(vim.split(proposed, '\n', { plain = true }), temp .. '/logs/proposal.md')
  local executable = temp .. '/provider-fixture'
  local source = [=[
import json, os, pathlib, re, sys, time
logs = pathlib.Path(os.environ["KILN_CONVERSATION_LOGS"])
claude = "--output-format" in sys.argv
prompt = sys.stdin.read()
plan = ('--permission-mode' in sys.argv and sys.argv[sys.argv.index('--permission-mode') + 1] == 'plan') or 'sandbox_mode="read-only"' in sys.argv
if plan:
    step = 'proposal' if '[proposal]' in prompt else 'clarify'
else:
    ids = re.findall(r'<kiln_step_complete id=[\"\']([^\"\']+)[\"\']\s*/>', prompt)
    step = next((value for value in reversed(ids) if value in ('alpha', 'beta', 'gamma')), 'unknown')
previous = [json.loads(line) for line in (logs / 'requests.jsonl').read_text().splitlines()] if (logs / 'requests.jsonl').exists() else []
attempt = 1 + sum(item['step'] == step for item in previous)
native = 'conversation-' + ('claude' if claude else 'codex')
with (logs / 'requests.jsonl').open('a') as stream:
    stream.write(json.dumps({'step': step, 'attempt': attempt, 'cwd': os.getcwd(), 'argv': sys.argv[1:],
       'prompt': prompt, 'before': pathlib.Path('engine.ex').read_text(), 'native': native}) + '\n')
def emit(value):
    data = json.dumps(value).encode() + b'\n'
    for offset in range(0, len(data), 53):
        sys.stdout.buffer.write(data[offset:offset+53]); sys.stdout.buffer.flush()
def message(value):
    identity = 'message-' + str(time.monotonic_ns())
    if claude:
        emit({'type': 'assistant', 'message': {'id': identity, 'content': [{'type': 'text', 'text': value}]}})
    else:
        emit({'type': 'item.completed', 'item': {'id': identity, 'type': 'agent_message', 'text': value}})
def write(path, value):
    identity = 'write-' + str(time.monotonic_ns())
    if claude:
        emit({'type': 'assistant', 'message': {'id': identity, 'content': [{'type': 'tool_use', 'id': identity,
          'name': 'Write', 'input': {'file_path': str(pathlib.Path(path).resolve()), 'content': value}}]}})
    pathlib.Path(path).write_text(value)
    if claude:
        emit({'type': 'user', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': identity, 'content': 'File written'}]}})
    else:
        emit({'type': 'item.completed', 'item': {'id': identity, 'type': 'file_change', 'status': 'completed',
          'changes': [{'path': path, 'kind': 'update'}]}})
def check_command(command, output, code=0):
    identity = 'check-' + str(time.monotonic_ns())
    if claude:
        emit({'type': 'assistant', 'message': {'id': identity, 'content': [{'type': 'tool_use', 'id': identity,
          'name': 'Bash', 'input': {'command': command}}]}})
        emit({'type': 'user', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': identity,
          'content': output, 'is_error': code != 0}]}})
    else:
        emit({'type': 'item.started', 'item': {'id': identity, 'type': 'command_execution',
          'command': command, 'status': 'in_progress'}})
        emit({'type': 'item.completed', 'item': {'id': identity, 'type': 'command_execution',
          'command': command, 'aggregated_output': output, 'exit_code': code,
          'status': 'completed' if code == 0 else 'failed'}})
def finish(ok=True):
    if claude:
        emit({'type': 'result', 'subtype': 'success' if ok else 'error_during_execution', 'is_error': not ok,
              'session_id': native, 'result': '' if ok else 'Fixture verification failed',
              'usage': {'input_tokens': 100, 'output_tokens': 20}})
    elif ok:
        emit({'type': 'turn.completed', 'usage': {'input_tokens': 100, 'output_tokens': 20}})
    else:
        emit({'type': 'turn.failed', 'error': {'message': 'Fixture verification failed'}})
def wait(name):
    deadline = time.monotonic() + 45
    while not (logs / name).exists() and time.monotonic() < deadline: time.sleep(.02)
if claude: emit({'type': 'system', 'subtype': 'init', 'session_id': native})
else:
    emit({'type': 'thread.started', 'thread_id': native}); emit({'type': 'turn.started'})
if step == 'clarify':
    message('Should readiness represent any pending job, or capacity to accept another job?')
    finish()
elif step == 'proposal':
    message('The existing module supports a small readiness API. Here is the justified dossier.\n\n```dossier\n' + (logs / 'proposal.md').read_text() + '\n```')
    finish()
elif step == 'alpha':
    message('I will define readiness in engine.ex before connecting its consumer.')
    write('engine.ex', 'defmodule Engine do\n  def ready?, do: true\nend\n')
    check_command('elixir engine_test.exs', '......\n6 tests, 0 failures\n')
    message('Alpha implementation is visible.\n<kiln_step_complete id="alpha"/>')
    finish()
    if attempt == 1: wait('alpha-first-exit')
    elif attempt == 2: wait('alpha-second-exit')
elif step == 'beta':
    message('I will connect the consumer and keep the saved Engine implementation.')
    write('consumer.ex', 'defmodule Consumer do\n  def ready?, do: Engine.ready?()\nend\n')
    if attempt == 1:
        message('Beta first edit is visible; waiting for verification.')
        wait('beta-first-exit')
    if attempt > 1:
        check_command('elixir engine_test.exs', '......\n6 tests, 0 failures\n')
    check_command('elixir consumer_test.exs', '..\n2 tests, 0 failures\n')
    message('Consumer uses the current Engine.\n<kiln_step_complete id="beta"/>')
    finish()
elif step == 'gamma':
    if attempt == 1:
        message('Should the example cover the false result as well?')
        finish()
    elif attempt == 2:
        check_command('elixir contract_test.exs', '1 test, 1 failure\nExpected saved example.\n', 1)
        message('The verification failed.\n<kiln_step_complete id="gamma"/>')
        finish(False)
    else:
        write('guide.md', 'Consumer.ready?() uses the verified Engine readiness.\nInclude the saved human example.\n')
        check_command('elixir contract_test.exs', '.\n1 test, 0 failures\n')
        message('The example matches the current consumer.\n<kiln_step_complete id="gamma"/>')
        finish()
else:
    message('Unknown fixture step in prompt: ' + prompt)
    finish(False)
]=]
  fn.writefile({ '#!' .. fn.exepath('python3') }, executable)
  fn.writefile(vim.split(source, '\n', { plain = true }), executable, 'a'); assert(uv.fs_chmod(executable, 448))
  vim.env.KILN_CODEX_BIN, vim.env.KILN_CLAUDE_BIN = executable, executable
  vim.cmd.edit(fn.fnameescape(root .. '/engine.ex'))
  app = require('kiln'); app.setup({ root = root, workflow = true })
  if provider_name ~= 'codex' then app.provider(provider_name) end
  local state, session = app.state, app.state.sessions[app.state.selected]
  check(#state.sessions == 1 and session.workflow and session.workflow.phase == 'planning',
    'A new workspace begins one planning conversation')
  check(not state.windows.steps or not api.nvim_win_is_valid(state.windows.steps),
    'A speculative step list is not shown before there is a plan')
  send('[clarify] Plan a small readiness feature with me.')
  wait_for(function() return not session.job and event(session, 'Should readiness') end, 'The planning conversation asks a question through the actual provider bridge')
  check(session.workflow.phase == 'planning' and not state.dossier and #requests() == 1,
    'A clarifying answer stays in planning without inventing or executing a dossier')
  wait_for(function() return contains(text(state.buffers.transcript), 'Should readiness')
      and contains(text(state.buffers.transcript), '[clarify]') end,
    'The same visible chat contains the request and planning reply')
  check(git('status', '--porcelain') == '', 'Read-only planning does not change source files')
  local native = session.native_id
  check(native == 'conversation-' .. provider_name, 'The native planning conversation is established')
  send('[proposal] Readiness means at least one pending job. Keep the change small.')
  wait_for(function() return not session.job and state.dossier and session.workflow.phase == 'ready' end,
    'A complete valid dossier appears automatically from the next planning reply')
  check(#state.sessions == 1 and session.native_id == native and #requests() == 2,
    'Refining the plan keeps one chat and one native conversation without implementation calls')
  local second = request('proposal')
  check(vim.tbl_contains(second.argv, provider_name == 'codex' and 'resume' or '--resume')
    and vim.tbl_contains(second.argv, native), 'The second planning turn resumes the original provider session')
  check(vim.tbl_contains(second.argv, provider_name == 'codex' and 'sandbox_mode="read-only"' or 'plan'),
    'The repeated planning turn still uses read-only provider permissions')
  check(api.nvim_win_get_position(state.windows.steps)[2] < api.nvim_win_get_position(state.windows.code)[2]
    and api.nvim_win_get_position(state.windows.code)[2] < api.nvim_win_get_position(state.windows.transcript)[2],
    'The accepted steps appear on the left, code in the middle, and the same chat on the right')
  wait_for(function() return contains(text(state.buffers.steps), 'Define readiness')
    and contains(text(state.buffers.steps), 'Connect consumer') and contains(text(state.buffers.steps), 'Document contract') end,
    'All planned outcomes remain visible in the left list')
  check(api.nvim_get_current_win() == state.windows.prompt, 'A planning reply does not steal prompt focus')

  wait_for(function() return contains(text(state.buffers.transcript), 'Plan ready · 3 steps')
    and not contains(text(state.buffers.transcript), '## Step alpha') end,
    'Accepted dossier collapses into a readable plan summary in the same chat')
  check(action_is('PLAN READY') and state.current_action.primary == 'Start',
    'One persistent control action offers Start for the accepted plan')
  app.inspect_step('alpha')
  check(contains(text(api.nvim_get_current_buf()), 'The consumer requires a concrete readiness function.')
    and contains(text(api.nvim_get_current_buf()), 'Exercise Engine.ready?/0.'),
    'Step inspection exposes the complete rationale and verification criteria')
  close_popup(); app.focus_prompt()
  app.primary()
  wait_for(function() return request('alpha') and session.job and event(session, 'Alpha implementation is visible.') end,
    'Explicit run starts the first step in the same chat')
  wait_for(function() return contains(text(api.nvim_win_get_buf(state.windows.code)), 'do: true')
      and has_highlight(api.nvim_win_get_buf(state.windows.code)) and highlighted_step('alpha') end,
    'Actual source changes and the current-step highlight appear together')
  check(api.nvim_get_current_win() == state.windows.prompt, 'Live code and checklist updates preserve typing focus')
  wait_for(function() return observed('alpha').tests_passed == 6 end,
    'Real bridge tool results become six observed passed checks, not assistant claims')
  local alpha_evidence = observed('alpha')
  check(#alpha_evidence.files == 1 and alpha_evidence.files[1].path == 'engine.ex'
    and alpha_evidence.checks[1].command == 'elixir engine_test.exs',
    'File and verification evidence are attributed to the current outcome')
  local tagged_file = false
  for _, item in ipairs(session.events) do
    if item.type == 'file' and item.path == 'engine.ex' then
      tagged_file = item.step_id == 'alpha' and item.step_fingerprint == session.workflow.steps.alpha.fingerprint
    end
  end
  check(tagged_file, 'Normalized file events carry their step and definition identity')
  local activity_row
  wait_for(function()
    for row, item in pairs(state.event_rows) do
      if item.type == 'activity' and contains(item.text, '6 tests, 0 failures') then activity_row = row; return true end
    end
  end, 'Tool calls and file events are grouped in the real transcript')
  check(activity_row ~= nil and not contains(text(state.buffers.transcript), 'elixir engine_test.exs'),
    'Readable chat collapses command output while retaining an inspection target')
  api.nvim_set_current_win(state.windows.transcript)
  api.nvim_win_set_cursor(state.windows.transcript, { activity_row, 0 }); app.inspect()
  check(contains(text(api.nvim_get_current_buf()), 'elixir engine_test.exs')
    and contains(text(api.nvim_get_current_buf()), '6 tests, 0 failures'),
    'Enter inspection opens the full actual command and output behind an activity group')
  close_popup(); app.focus_prompt()
  api.nvim_win_set_cursor(state.windows.code, { 1, 0 })
  app.navigate_change(1)
  check(api.nvim_win_get_cursor(state.windows.code)[1] == 2 and session.job and not state.follow,
    'Next-change navigation reaches the actual Git hunk and pins code without interrupting the agent')
  app.navigate_change(-1)
  check(api.nvim_win_get_cursor(state.windows.code)[1] == 2, 'Previous-change navigation wraps through the real hunk list')
  app.focus_prompt()
  check(#requests() == 3 and not request('beta') and session.workflow.steps.alpha.status ~= 'done',
    'A native completion record does not advance while its process is still running')
  send('Stop and reconsider this implementation before continuing.')
  app.pause_plan()
  wait_for(function() return not session.job and session.workflow.phase == 'paused' end,
    'An explicit pause cancels a newly queued chat interruption while stopping the current process')
  vim.wait(700, function() return request('beta') ~= nil end, 10)
  check(#requests() == 3 and not request('beta') and session.workflow.steps.alpha.status ~= 'done',
    'A second pause cancels the queued chat turn and an old completion marker cannot advance the plan')
  api.nvim_buf_set_lines(state.buffers.prompt, 0, -1, false, { '' })
  app.run_plan()
  wait_for(function() return request('alpha', 2) and session.job end, 'Resume retries the interrupted step')
  local submitted = 'Submitted direction A: preserve the public API and finish readiness.'
  send(submitted)
  check(text(state.buffers.prompt) == '' and session.draft == '',
    'A submitted interruption is captured and cleared immediately')
  local draft = 'Unsent note B: preserve the existing error wording.'
  api.nvim_buf_set_lines(state.buffers.prompt, 0, -1, false, { draft })
  api.nvim_exec_autocmds('TextChanged', { buffer = state.buffers.prompt })
  wait_for(function() return request('alpha', 3) and not session.job and session.workflow.phase == 'paused' end,
    'The queued submitted direction runs after interruption, then the later unsent draft pauses advancement')
  check(contains(request('alpha', 3).prompt, submitted) and not contains(request('alpha', 3).prompt, draft),
    'The queued turn submits the captured message A, never the newer draft B')
  local draft_sent = false
  for _, value in ipairs(requests()) do if contains(value.prompt, draft) then draft_sent = true end end
  check(not draft_sent and not request('beta') and text(state.buffers.prompt) == draft and session.draft == draft,
    'Draft B remains visible and unsent until the user explicitly submits it')
  local restore_file, restore_result = temp .. '/restore.json', temp .. '/restore-result.json'
  wait_for(function()
    local saved = vim.json.decode(table.concat(fn.readfile(state.state_file), '\n'))
    return saved.sessions[1].draft == draft and saved.sessions[1].workflow.steps.alpha.status == 'done'
  end, 'The paused chat, draft, and completed outcome are persisted before restart')
  fn.writefile({ vim.json.encode({ root = root, storage = state.storage, native = native, provider = provider_name,
    draft = draft, log = temp .. '/logs/requests.jsonl', requests = #requests(), result = restore_result }) }, restore_file)
  local restored = vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE', '-n',
    '-c', 'luafile ' .. home .. '/tests/test_conversation.lua' }, {
    text = true, env = { KILN_HOME = home, KILN_CONVERSATION_CASE = provider_name, KILN_CONVERSATION_RESTORE = restore_file },
  }):wait(10000)
  check(restored.code == 0, 'Actual Neovim restart restores the saved conversation: '
    .. (restored.stdout or '') .. (restored.stderr or ''))
  count = count + vim.json.decode(table.concat(fn.readfile(restore_result), '\n')).count
  send(draft)
  wait_for(function() return request('beta') and session.job end,
    'Sending the preserved draft continues at the unfinished next step')
  check(not request('alpha', 4) and contains(request('beta').prompt, draft),
    'A normal follow-up after a draft pause does not rerun the completed outcome')
  wait_for(function() return highlighted_step('beta') and event(session, 'Beta first edit is visible') end,
    'Sequential progress moves the left highlight while the same chat explains the next change')
  check(session.workflow.steps.alpha.status == 'done' and session.workflow.steps.beta.status == 'running',
    'Only the successfully completed step is done')
  check(#state.sessions == 1 and session.native_id == native and state.view_root == root,
    'Step transitions keep one application session, native conversation, and workspace')
  check(not state.changes.is_diff_open() and #api.nvim_list_wins() == 4,
    'Implementation retains the steps, source, chat, and prompt without a modal or diff split')

  wait_for(function() return contains(text(state.buffers.steps), '6 tests passed') end,
    'Completed left-side outcome shows actual passed tests instead of repeated status labels')
  app.inspect_code()
  check(not state.current_context.follow and session.job,
    'Inspecting code pins the view without stopping the active writer')
  wait_for(function() return contains(state.current_action.text, 'code pinned') end,
    'The action strip explains that source following is pinned')
  app.primary()
  check(session.job and action_is('STOPPING') and state.current_action.primary == 'Wait',
    'Take over reports STOPPING while the bridge still owns a live process')
  wait_for(function() return not session.job and session.workflow.phase == 'paused'
    and api.nvim_get_current_win() == state.windows.code end, 'Handcoding interrupts the plan and focuses the existing source pane')
  wait_for(function() return action_is('YOU HAVE CONTROL') end,
    'Control ownership changes only after the writer exits')
  check(state.current_action.primary == 'Resume', 'The same primary action becomes Resume after handover')
  check(not request('gamma'), 'Interruption does not dispatch the next outcome')
  check(state.changes.follow('engine.ex', state.windows.code), 'The operator can open the source within the same workspace')
  local source_buf = api.nvim_win_get_buf(state.windows.code)
  api.nvim_buf_set_lines(source_buf, 1, 2, false, { '  def ready?, do: :human_decision' })
  app.run_plan()
  check(not session.job and not request('beta', 2), 'Unsaved source changes block resuming implementation')
  api.nvim_buf_call(source_buf, function() vim.cmd('silent write') end)
  wait_for(function() return action_is('YOU HAVE CONTROL', 'engine.ex saved')
    and contains(state.current_action.text, 'will be reread on resume') end,
    'A real save shows the pending file handoff before resumption')
  local human_source = table.concat(fn.readfile(root .. '/engine.ex'), '\n')
  local revised = proposed:gsub('Outcome: Explain the readiness contract to callers%.',
    'Outcome: Explain the readiness contract to callers with the saved human example.')
  app.edit_dossier()
  api.nvim_buf_set_lines(state.dossier_buffer, 0, -1, false, vim.split(revised, '\n', { plain = true }))
  app.run_plan()
  check(not session.job and not request('beta', 2), 'Unsaved dossier changes block resuming implementation')
  api.nvim_buf_call(state.dossier_buffer, function() vim.cmd('silent write') end)
  send('Preserve my saved Engine correction, then continue the revised plan.')
  check(session.job and action_is('RESUMING', 'saved edits'),
    'Handback reports RESUMING immediately while the same provider accepts the saved-file handoff')
  wait_for(function() return request('beta', 2) and request('gamma') and not session.job end,
    'The same conversation resumes after the source and future plan changes are saved')
  check(contains(request('beta', 2).prompt, 'Editor handoff (file-path data): ["engine.ex"]')
    and contains(request('beta', 2).before, ':human_decision'), 'The resumed provider receives and reads the saved human edit')
  check(contains(request('gamma').prompt, 'saved human example'), 'The later step receives the edited dossier definition')
  check(session.workflow.phase == 'paused' and session.workflow.steps.gamma.status ~= 'done',
    'A successful provider turn without the completion marker pauses for its question')
  check(state.follow and not state.current_context.human_control,
    'Handback restores following without losing the saved human correction')
  check(table.concat(fn.readfile(root .. '/engine.ex'), '\n') == human_source,
    'The human source bytes survive the resumed implementation')
  app.run_plan()
  wait_for(function() return request('gamma', 2) and not session.job end, 'A failed verification turn completes')
  wait_for(function() return observed('gamma').checks_failed == 1
    and contains(text(state.buffers.transcript), 'ATTENTION')
    and contains(text(state.buffers.steps), 'failed') end,
    'A failed actual command is visible in the chat, checklist, and verification evidence')
  check(session.workflow.phase == 'paused' and session.workflow.steps.gamma.status == 'blocked',
    'Provider failure blocks the step even when its response includes a completion marker')
  app.run_plan()
  wait_for(function() return request('gamma', 3) and not session.job and session.workflow.phase == 'review' end,
    'A successful final retry completes implementation and stops for review')
  check(session.workflow.steps.alpha.status == 'done' and session.workflow.steps.beta.status == 'done'
    and session.workflow.steps.gamma.status == 'done', 'All steps are complete only after their own successful turns')
  wait_for(function() return action_is('READY FOR REVIEW') and state.current_action.primary == 'Review' end,
    'The contextual action offers Review after all outcomes finish')
  local reviewed = require('kiln.evidence').review(session, state.dossier)
  check(reviewed.tests_passed == 9 and reviewed.checks_failed == 0 and #reviewed.unresolved == 0,
    'Final evidence uses successful retries and does not double-count repeated check runs')
  check(#reviewed.groups == 3 and #reviewed.files == 3, 'Review groups actual files and checks by the three outcomes')
  app.primary()
  local review_text = text(api.nvim_get_current_buf())
  check(contains(review_text, 'Define readiness') and contains(review_text, 'Connect consumer')
    and contains(review_text, 'Document contract') and contains(review_text, 'engine.ex')
    and contains(review_text, 'consumer.ex') and contains(review_text, 'guide.md'),
    'The primary Review action opens changes grouped by dossier outcome')
  check(contains(review_text, 'elixir engine_test.exs') and contains(review_text, 'elixir consumer_test.exs'),
    'Review displays the actual verification commands alongside changed files')
  check(not session.reviewed and vim.tbl_isempty(session.reviewed_files or {}),
    'Opening the review does not silently approve files or the implementation')
  local check_row, file_row
  for row, item in pairs(state.review_rows) do
    if item.check and item.check.command == 'elixir engine_test.exs' then check_row = row end
    if item.path == 'consumer.ex' then file_row = row end
  end
  check(check_row and file_row, 'Review exposes navigable rows for actual checks and files')
  api.nvim_win_set_cursor(0, { check_row, 0 })
  fn.maparg('<CR>', 'n', false, true).callback()
  check(contains(text(api.nvim_get_current_buf()), 'elixir engine_test.exs')
    and contains(text(api.nvim_get_current_buf()), '6 tests, 0 failures'),
    'Review check navigation opens the full observed command result')
  close_popup(); app.review_changes()
  for row, item in pairs(state.review_rows) do if item.path == 'consumer.ex' then file_row = row end end
  api.nvim_win_set_cursor(0, { file_row, 0 })
  fn.maparg('<CR>', 'n', false, true).callback()
  wait_for(function() return state.changes.is_diff_open()
    and contains(api.nvim_buf_get_name(api.nvim_win_get_buf(state.windows.code)), 'consumer.ex') end,
    'Review file navigation opens the actual source diff')
  state.changes.close_diff(); app.focus_prompt()
  check(#state.sessions == 1 and session.native_id == native and git('rev-parse', 'HEAD') == head,
    'The entire flow uses one conversation and does not create per-step commits or integrations')
  for _, value in ipairs(requests()) do
    check(value.cwd == root, 'Every planning and execution turn uses the same workspace')
    if value.step ~= 'clarify' then
      check(vim.tbl_contains(value.argv, native), 'Every continuation resumes the same native session')
    end
    if value.step == 'alpha' or value.step == 'beta' or value.step == 'gamma' then
      check(vim.tbl_contains(value.argv, provider_name == 'codex' and 'sandbox_mode="workspace-write"' or 'acceptEdits'),
        'Implementation changes mode at the actual provider boundary')
    end
  end
  wait_for(function() return contains(text(state.buffers.transcript), 'Should readiness')
    and contains(text(state.buffers.transcript), 'The example matches the current consumer.') end,
    'Planning and final implementation remain in one visible chat history')

  -- A selected idle session cannot approve code while another actual process
  -- owns the same checkout. This process is a local fixture, not a model turn.
  local other = { id = 'shared-review-writer', provider = provider_name, mode = 'edit',
    status = 'running', events = {} }
  local writer = fn.jobstart({ fn.exepath('python3'), '-c', 'import time; time.sleep(30)' }, {
    on_exit = function() other.job = nil end,
  })
  check(writer > 0, 'A local process represents the other shared-workspace writer')
  other.job = writer; state.sessions[#state.sessions + 1] = other
  app.review_changes()
  local function review_row(path)
    for row, item in pairs(state.review_rows) do if item.path == path then return row end end
  end
  api.nvim_win_set_cursor(0, { assert(review_row('engine.ex')), 0 })
  fn.maparg('<leader>v', 'n', false, true).callback()
  check(not session.reviewed_files['engine.ex'] and contains(warnings[#warnings], 'Stop the agent'),
    'Another active writer in the same workspace blocks file approval')
  fn.jobstop(writer)
  wait_for(function() return not other.job end, 'The shared-workspace fixture writer exits')
  table.remove(state.sessions)
  fn.maparg('<leader>v', 'n', false, true).callback()
  local approved = session.reviewed_files['engine.ex']
  check(type(approved) == 'string', 'An unchanged regular text file can be approved after all writers stop')
  local mode = bit.band(uv.fs_stat(root .. '/engine.ex').mode, 511)
  assert(uv.fs_chmod(root .. '/engine.ex', bit.bxor(mode, 64)))
  api.nvim_win_set_cursor(0, { assert(review_row('engine.ex')), 0 })
  fn.maparg('<leader>v', 'n', false, true).callback()
  check(session.reviewed_files['engine.ex'] == approved and contains(warnings[#warnings], 'This file changed'),
    'Changing executable mode invalidates an open review snapshot even when source bytes are identical')
  close_popup(); app.review_changes()
  local changed_row = assert(review_row('engine.ex'))
  check(contains(api.nvim_buf_get_lines(api.nvim_get_current_buf(), changed_row - 1, changed_row, false)[1], '○'),
    'A changed file mode is shown as awaiting review')
  close_popup(); assert(uv.fs_chmod(root .. '/engine.ex', mode))

  -- Passing command output remains inspectable history after later manual
  -- changes, but it must no longer certify the current saved source.
  check(state.changes.follow('engine.ex', state.windows.code), 'Open the completed implementation for a later manual edit')
  local completed_buf = api.nvim_win_get_buf(state.windows.code)
  api.nvim_buf_set_lines(completed_buf, 1, 2, false, { '  def ready?, do: :later_human_change' })
  api.nvim_buf_call(completed_buf, function() vim.cmd('silent write') end)
  wait_for(function()
    local current = require('kiln.evidence').review(session, state.dossier)
    return current.tests_passed == 0 and current.checks_stale >= 3
      and contains(table.concat(current.unresolved, '\n'), 'Rerun after edits')
  end, 'A post-completion manual save makes earlier checks stale without an active step ID')
  check(not session.reviewed_files['engine.ex'], 'Saving a source correction clears its prior human approval')
  app.review_changes()
  check(contains(text(api.nvim_get_current_buf()), '0 tests passed')
    and contains(text(api.nvim_get_current_buf()), 'RERUN')
    and contains(text(api.nvim_get_current_buf()), 'Rerun after edits'),
    'Review clearly distinguishes old passing output from checks still needed for the edited source')
  for row, item in pairs(state.review_rows) do
    if item.check and item.check.command == 'elixir engine_test.exs' then check_row = row; break end
  end
  api.nvim_win_set_cursor(0, { check_row, 0 }); fn.maparg('<CR>', 'n', false, true).callback()
  check(contains(text(api.nvim_get_current_buf()), '6 tests, 0 failures'),
    'Stale verification retains the complete historical command output for inspection')
  close_popup(); app.focus_prompt()
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
print('CONVERSATION_ASSERTIONS=' .. count); vim.cmd('qa!')

-- Dossier-first execution through real Neovim, bridge, and isolated Git worktrees.
-- The provider is an offline protocol fixture: no model account or network calls.
local api, fn = vim.api, vim.fn
local uv = vim.uv or vim.loop
local home = vim.env.KILN_HOME or fn.getcwd()
vim.opt.runtimepath:prepend(home)
vim.o.columns, vim.o.lines = 180, 55
vim.o.swapfile, vim.o.backup, vim.o.writebackup, vim.o.modeline = false, false, false, false
vim.o.equalalways, vim.o.hidden = false, true
local temp = fn.tempname() .. '-kiln-planning'
fn.mkdir(temp .. '/project', 'p'); fn.mkdir(temp .. '/logs', 'p')
local root = uv.fs_realpath(temp .. '/project')
vim.env.KILN_HOME, vim.env.KILN_STATE_DIR = home, temp .. '/state'
vim.env.KILN_FAKE_LOGDIR = temp .. '/logs'
local app, count, warnings = nil, 0, {}
vim.notify = function(message) warnings[#warnings + 1] = tostring(message) end
local function check(value, message) count = count + 1; assert(value, message) end
local function contains(value, text) return tostring(value):find(text, 1, true) ~= nil end
local function wait_for(predicate, message)
  local success = vim.wait(14000, predicate, 10)
  if not success and app then message = message .. '\nSessions: ' .. vim.inspect(app.state.sessions) .. '\nWarnings: ' .. vim.inspect(warnings) end
  check(success, message)
end
local function git(path, ...)
  local args = { 'git', '-C', path }; vim.list_extend(args, { ... })
  local result = vim.system(args, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end
local function request(kind)
  local file = temp .. '/logs/requests.jsonl'
  if fn.filereadable(file) == 0 then return nil end
  for _, line in ipairs(fn.readfile(file)) do
    local value = vim.json.decode(line)
    if value.kind == kind then return value end
  end
end
local function all_requests()
  return fn.filereadable(temp .. '/logs/requests.jsonl') == 1 and #fn.readfile(temp .. '/logs/requests.jsonl') or 0
end
local function selected() return app.state.sessions[app.state.selected] end
local function select(session)
  local index
  for i, candidate in ipairs(app.state.sessions) do if candidate == session then index = i end end
  assert(index)
  app.sessions(); api.nvim_win_set_cursor(0, { index, 0 }); fn.maparg('<CR>', 'n', false, true).callback()
end
local function task(id)
  local step
  for _, candidate in ipairs(app.state.dossier.steps) do if candidate.id == id then step = candidate end end
  if not step then return nil end
  for _, session in ipairs(app.state.sessions) do if session.id == step.session_id then return session end end
end
local function save_dossier(text)
  app.edit_dossier()
  api.nvim_buf_set_lines(app.state.dossier_buffer, 0, -1, false, vim.split(text, '\n', { plain = true }))
  api.nvim_buf_call(app.state.dossier_buffer, function() vim.cmd('silent write') end)
end
local initial = table.concat({ '# Small requested behavior', 'Goal: Make the queue stable.',
  'Approach: Extend the existing module and tests.', 'Why this approach: The public API already fits the request.', '',
  '## Step deliver: Stable ordering', 'Outcome: Queue ordering is predictable.',
  'Why: Callers need one coherent correction.', 'Verify: Run queue tests.', 'Depends: none' }, '\n')
local proposed = table.concat({ '# Queue readiness feature', 'Goal: Show readiness through the existing public API.',
  'Approach: Extend Engine, document its contract, then wire its consumer.',
  'Why this approach: Existing modules already provide the needed boundaries.',
  'Constraints: Preserve current callers; do not add a dependency.', '',
  '## Step foundation: Add the readiness contract', 'Outcome: Engine exposes ready?/0.',
  'Provider: codex', 'Model: foundation-model',
  'Why: A stable contract is independently reviewable and supports the consumer.',
  'Verify: Exercise the Engine readiness result.', 'Depends: none', '',
  '## Step docs: Document readiness usage', 'Outcome: A concrete example explains the agreed ready?/0 API.',
  'Provider: claude',
  'Why: Documentation can proceed independently against the agreed contract.',
  'Verify: Check the example uses the agreed Engine.ready?/0 name.', 'Depends: none', '',
  '## Step consumer: Use the integrated contract', 'Outcome: Consumer reports readiness through Engine.',
  'Model: consumer-model',
  'Why: This separate call site demonstrates the public integration.',
  'Verify: Exercise Consumer against the integrated Engine implementation.', 'Depends: foundation',
  'Dependency reason: The consumer must build against the actual integrated Engine API.' }, '\n')
local function run()
  git(root, 'init', '-q'); git(root, 'config', 'user.name', 'WarrenBuffering')
  git(root, 'config', 'user.email', 'WarrenBuffering@users.noreply.github.com')
  fn.writefile({ 'defmodule Engine do', '  def ready?, do: false', 'end' }, root .. '/engine.ex')
  git(root, 'add', '.'); git(root, 'commit', '-qm', 'Dossier integration fixture')
  local original_head = git(root, 'rev-parse', 'HEAD')
  fn.writefile(vim.split(proposed, '\n', { plain = true }), temp .. '/logs/proposal.md')
  local fake = temp .. '/provider-fixture'
  local source = [=[
import hashlib, json, os, pathlib, re, sys, time
logs = pathlib.Path(os.environ["KILN_FAKE_LOGDIR"])
claude = "--output-format" in sys.argv
prompt = sys.stdin.read()
match = re.search(r"^DELIVERABLE ([A-Za-z0-9_-]+):", prompt, re.MULTILINE)
kind = match.group(1) if match else "planner"
native = "dossier-" + hashlib.sha256((os.getcwd() + kind).encode()).hexdigest()[:12]
with (logs / "requests.jsonl").open("a") as stream:
    stream.write(json.dumps({"kind": kind, "cwd": os.getcwd(), "argv": sys.argv[1:], "prompt": prompt,
                             "before": pathlib.Path("engine.ex").read_text()}) + "\n")
def emit(value):
    value = json.dumps(value).encode() + b"\n"
    for offset in range(0, len(value), 59):
        sys.stdout.buffer.write(value[offset:offset+59]); sys.stdout.buffer.flush()
def message(text):
    if claude:
        emit({"type": "assistant", "message": {"id": "message-" + str(time.monotonic_ns()), "content": [{"type": "text", "text": text}]}})
    else:
        emit({"type": "item.completed", "item": {"id": "message-" + str(time.monotonic_ns()), "type": "agent_message", "text": text}})
def write(path, text):
    identifier = "file-" + str(time.monotonic_ns())
    if claude:
        emit({"type": "assistant", "message": {"id": identifier, "content": [{"type": "tool_use", "id": identifier,
              "name": "Write", "input": {"file_path": str(pathlib.Path(path).resolve()), "content": text}}]}})
    pathlib.Path(path).write_text(text)
    if claude:
        emit({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": identifier, "content": "File written"}]}})
    else:
        emit({"type": "item.completed", "item": {"id": identifier, "type": "file_change",
              "status": "completed", "changes": [{"path": path, "kind": "update"}]}})
if claude:
    emit({"type": "system", "subtype": "init", "session_id": native})
else:
    emit({"type": "thread.started", "thread_id": native}); emit({"type": "turn.started"})
if kind == "planner":
    time.sleep(0.2)
    message((logs / "proposal.md").read_text())
else:
    message("Implementing the justified " + kind + " outcome")
    if kind == "foundation":
        write("engine.ex", "defmodule Engine do\n  def ready?, do: true\nend\n")
    elif kind == "docs":
        write("guide.md", "Use Engine.ready?() to check readiness.\n")
    elif kind == "consumer":
        write("consumer.ex", "defmodule Consumer do\n  def ready?, do: Engine.ready?()\nend\n")
    message("Wrote " + kind)
    if kind in ("foundation", "docs"):
        deadline, late = time.monotonic() + 45, False
        while not (logs / ("release-" + kind)).exists() and time.monotonic() < deadline:
            if kind == "docs" and not late and (logs / "docs-late").exists():
                write("guide.md", "Use Engine.ready?() to check readiness.\nThe result is a boolean.\n")
                message("Late documentation update"); late = True
            time.sleep(0.03)
    message("Finished " + kind)
if claude:
    emit({"type": "result", "subtype": "success", "is_error": False, "session_id": native, "usage": {"input_tokens": 100, "output_tokens": 20}})
else:
    emit({"type": "turn.completed", "usage": {"input_tokens": 100, "output_tokens": 20}})
]=]
  fn.writefile({ '#!' .. fn.exepath('python3') }, fake)
  fn.writefile(vim.split(source, '\n', { plain = true }), fake, 'a'); assert(uv.fs_chmod(fake, 448))
  vim.env.KILN_CODEX_BIN, vim.env.KILN_CLAUDE_BIN = fake, fake
  local original_code_buf = api.nvim_get_current_buf()
  app = require('kiln'); app.setup({ root = root, workflow = false })
  local state = app.state
  check(state.dossier_buffer ~= nil and api.nvim_win_get_buf(state.windows.monitor) == state.dossier_buffer,
    'A new workspace opens the editable dossier in the right sidebar')
  check(api.nvim_win_get_buf(state.windows.code) == original_code_buf
    and api.nvim_get_current_win() == state.windows.monitor,
    'Dossier authoring preserves the left code buffer and focuses the sidebar')
  local template = table.concat(api.nvim_buf_get_lines(state.dossier_buffer, 0, -1, false), '\n')
  local _, headings = template:gsub('## Step ', '')
  check(headings == 1, 'Template starts with one coherent deliverable rather than invented microsteps')
  check(contains(template, 'Why this approach:') and contains(template, 'Why:') and contains(template, 'Verify:'),
    'Template asks for approach rationale, deliverable rationale, and concrete evidence')
  api.nvim_win_call(state.windows.code, function() vim.cmd.edit(fn.fnameescape(root .. '/engine.ex')) end)
  local source_buf = api.nvim_win_get_buf(state.windows.code)
  local source_lines = api.nvim_buf_get_lines(source_buf, 0, -1, false)
  api.nvim_buf_set_lines(source_buf, 1, 2, false, { '  def ready?, do: false # unsaved human note' })
  app.edit_dossier()
  check(api.nvim_win_get_buf(state.windows.code) == source_buf and vim.bo[source_buf].modified
    and contains(api.nvim_buf_get_lines(source_buf, 1, 2, false)[1], 'unsaved human note'),
    'Opening the dossier preserves unsaved source edits on the left')
  api.nvim_buf_set_lines(source_buf, 0, -1, false, source_lines)
  vim.bo[source_buf].modified = false
  api.nvim_buf_call(state.dossier_buffer, function() vim.cmd('silent write') end)
  app.next_step()
  check(state.dossier == nil and state.dossier_invalid ~= nil and #state.sessions == 1 and all_requests() == 0,
    'Incomplete template cannot execute a provider or create a task')
  save_dossier(initial)
  check(state.dossier ~= nil and #state.dossier.steps == 1 and not state.dossier_invalid, 'Saving a valid single-deliverable plan validates it: ' .. vim.inspect({error=state.dossier_invalid, plan=state.dossier, expected=state.dossier_path, actual=api.nvim_buf_get_name(state.dossier_buffer)}))
  api.nvim_buf_set_lines(state.dossier_buffer, 0, -1, false, vim.split(initial .. '\nUnsaved briefing note.', '\n', { plain = true }))
  app.next_step()
  check(#state.sessions == 1 and all_requests() == 0, 'Unsaved dossier blocks implementation')

  app.plan_dossier()
  local planner = selected()
  check(planner.dossier_planner and planner.mode == 'plan' and not planner.workspace, 'Planning uses a read-only task in the repository')
  wait_for(function() return planner.job == nil and planner.status == 'done' end, 'Real provider planning response completes')
  check(all_requests() == 1 and git(root, 'status', '--porcelain') == '', 'Planning neither launches implementation nor changes project files')
  check(vim.tbl_contains(request('planner').argv, 'sandbox_mode="read-only"'), 'Planner actually receives Codex read-only permissions')
  check(contains(request('planner').prompt, 'one coherent deliverable') and contains(request('planner').prompt, 'why any dependency is necessary'),
    'Planner prompt asks for the smallest justified process and explicit dependency reasoning')
  check(contains(request('planner').prompt, 'Unsaved briefing note.'), 'Planning reads the current editable brief')
  check(#state.dossier.steps == 1, 'A returned proposal is not adopted automatically')
  app.adopt_dossier()
  check(#state.dossier.steps == 1 and vim.bo[state.dossier_buffer].modified, 'Adopting a proposal preserves unsaved human dossier changes')
  save_dossier(initial)
  select(planner)
  local before_adoption = api.nvim_win_get_buf(state.windows.code)
  app.adopt_dossier()
  check(#state.dossier.steps == 3 and state.dossier.title == 'Queue readiness feature', 'Explicit adoption saves the proposed justified units')
  check(not vim.bo[state.dossier_buffer].modified and all_requests() == 1, 'Adopting a dossier leaves implementation under human control')
  check(api.nvim_win_get_buf(state.windows.monitor) == state.buffers.monitor
    and api.nvim_win_get_buf(state.windows.code) == before_adoption
    and api.nvim_get_current_win() == state.windows.monitor,
    'Adoption shows the persistent dossier rail while preserving the coding pane')
  check(contains(table.concat(fn.readfile(state.dossier_path), '\n'), 'Dependency reason:'), 'Dependency rationale is retained in the editable document')

  app.next_step('consumer')
  check(task('consumer') == nil and all_requests() == 1, 'A dependent outcome cannot launch before its prerequisite')
  app.next_step('foundation')
  local foundation = task('foundation')
  check(foundation and foundation.isolated and foundation.dossier_step == 'foundation', 'Dispatch binds a dossier unit to a named isolated task')
  check(api.nvim_win_get_buf(state.windows.monitor) == state.buffers.monitor,
    'Starting an outcome restores the persistent progress rail from dossier editing')
  local creating_context = state.current_context
  app.take_control()
  check(foundation.operation ~= nil and not creating_context.human_control
    and contains(warnings[#warnings], 'pending operation'), 'Takeover waits for provisioning instead of claiming premature human ownership')
  app.next_step('docs')
  local docs = task('docs')
  check(docs and docs ~= foundation and docs.dossier_step == 'docs', 'An independent outcome can dispatch immediately')
  check(foundation.provider == 'codex' and foundation.model == 'foundation-model', 'Explicit provider and model reach the assigned task')
  check(docs.provider == 'claude' and docs.model == '', 'Switching dossier provider uses its CLI default rather than leaking the previous model')
  wait_for(function() return foundation.job and docs.job and request('foundation') and request('docs') end,
    'Independent units provision and execute concurrently, including background dispatch')
  check(foundation.workspace.root ~= docs.workspace.root and foundation.workspace.root ~= root, 'Dossier units receive separate worktrees')
  check(request('foundation').cwd == foundation.workspace.root and request('docs').cwd == docs.workspace.root,
    'The real bridge invokes each unit in its assigned checkout')
  check(vim.tbl_contains(request('foundation').argv, 'foundation-model') and not vim.tbl_contains(request('docs').argv, '--model'),
    'The real provider boundary honors explicit models and provider-default omission')
  check(contains(request('foundation').prompt, state.dossier.brief)
    and contains(request('foundation').prompt, 'Verify: Exercise the Engine readiness result.')
    and contains(request('foundation').prompt, 'Why: A stable contract'), 'Dispatched agent receives shared reasoning and its complete unit instructions')
  check(not contains(request('foundation').prompt, 'DELIVERABLE consumer:'), 'A unit is asked to deliver its scoped outcome')
  check(git(root, 'rev-parse', 'HEAD') == original_head and git(root, 'status', '--porcelain') == '',
    'Parallel implementation preserves the primary checkout')
  local before_count = #state.sessions
  app.next_step('foundation')
  check(#state.sessions == before_count, 'A running unit cannot be dispatched twice')
  select(docs)
  wait_for(function() return fn.filereadable(docs.workspace.root .. '/guide.md') == 1 end, 'Documentation fixture writes its first live change')
  app.edit_dossier()
  local dossier_buf, code_win = state.dossier_buffer, state.windows.code
  local dossier_win = state.windows.monitor
  fn.writefile({ 'go' }, temp .. '/logs/docs-late')
  wait_for(function()
    for _, item in ipairs(docs.events) do if item.type == 'message' and item.text == 'Late documentation update' then return true end end
  end, 'Selected task continues emitting live changes while the dossier is open')
  check(api.nvim_win_get_buf(dossier_win) == dossier_buf and api.nvim_get_current_win() == dossier_win,
    'Agent events preserve the right dossier editor and its keyboard focus')
  check(api.nvim_win_get_buf(code_win) ~= dossier_buf,
    'Dossier editing never replaces the coding pane during a live agent turn')
  wait_for(function()
    local code_buf = api.nvim_win_get_buf(code_win)
    return contains(api.nvim_buf_get_name(code_buf), 'guide.md')
      and contains(table.concat(api.nvim_buf_get_lines(code_buf, 0, -1, false), '\n'), 'The result is a boolean.')
  end, 'Live agent changes remain visible on the left while the dossier editor stays on the right')

  local revised = proposed:gsub('Verify: Exercise Consumer against the integrated Engine implementation%.',
    'Verify: Exercise Consumer against the integrated Engine implementation, including the true result.')
  revised = revised:gsub('Constraints: Preserve current callers; do not add a dependency%.',
    'Constraints: Preserve current callers; do not add a dependency. Use the existing formatter.')
  save_dossier(revised)
  check(not state.dossier_invalid and task('foundation') == foundation and task('docs') == docs,
    'Future-unit and shared-brief edits preserve already dispatched bindings')
  save_dossier(revised:gsub('Outcome: Engine exposes ready%?/0%.', 'Outcome: Change the dispatched contract.'))
  check(state.dossier_invalid and contains(state.dossier_invalid, 'Dispatched unit foundation'),
    'Saving changed instructions for a dispatched unit is rejected visibly')
  app.next_step('consumer')
  check(task('consumer') == nil, 'An invalid revised dossier cannot dispatch future work')
  save_dossier(revised)
  check(not state.dossier_invalid, 'Restoring dispatched instructions revalidates the dossier')
  local without_docs = revised:gsub('## Step docs:.-## Step consumer:', '## Step consumer:')
  save_dossier(without_docs)
  check(state.dossier_invalid and contains(state.dossier_invalid, 'Keep dispatched unit docs'),
    'Dispatched units cannot disappear from the traceable dossier')
  save_dossier(revised)

  fn.writefile({ 'go' }, temp .. '/logs/release-foundation')
  wait_for(function() return foundation.job == nil and foundation.status == 'done' end, 'Prerequisite agent finishes its scoped change')
  app.next_step('consumer')
  check(task('consumer') == nil, 'Agent completion alone does not release a dependent outcome')
  select(foundation); app.take_control()
  check(state.current_context.human_control, 'Human can inspect the finished unit before review')
  app.review()
  wait_for(function() return foundation.operation == nil and foundation.reviewed end, 'Prerequisite obtains human review')
  check(not state.current_context.human_control, 'Marking a finished hand-inspected unit reviewed clears its handcoding blocker')
  app.next_step('consumer')
  check(task('consumer') == nil, 'Review alone does not release a dependent outcome')
  app.integrate()
  wait_for(function() return foundation.operation == nil and foundation.work_status == 'integrated' end,
    'Reviewed prerequisite integrates while independent work continues')
  check(docs.job ~= nil, 'Independent documentation continues during prerequisite integration')
  local integrated_head = git(root, 'rev-parse', 'HEAD')
  check(integrated_head ~= original_head and contains(fn.readfile(root .. '/engine.ex')[2], 'true'), 'Primary branch contains the prerequisite result')
  app.next_step('consumer')
  local consumer = task('consumer')
  wait_for(function() return consumer.workspace and consumer.job == nil and consumer.operation == nil and consumer.status == 'done' end,
    'Dependent unit executes once its prerequisite is integrated')
  check(consumer.workspace.base == integrated_head, 'Dependent worktree starts from integrated prerequisite history')
  check(contains(request('consumer').before, 'true'), 'Dependent provider sees the actual integrated code')
  check(contains(request('consumer').prompt, 'including the true result.') and contains(request('consumer').prompt, 'Use the existing formatter.'),
    'Future launch uses the newly justified verification and current shared constraints')
  check(contains(request('consumer').prompt, 'Dependency reason: The consumer must build against the actual integrated Engine API.'),
    'Dependent agent receives why its ordering exists')
  check(fn.filereadable(consumer.workspace.root .. '/consumer.ex') == 1 and fn.filereadable(root .. '/consumer.ex') == 0,
    'Dependent output stays isolated until its own human review and integration')
  fn.writefile({ 'go' }, temp .. '/logs/release-docs')
  wait_for(function() return docs.job == nil and docs.status == 'done' end, 'Independent documentation finishes normally')
  app.dossier()
  local visible = table.concat(api.nvim_buf_get_lines(api.nvim_get_current_buf(), 0, -1, false), '\n')
  check(api.nvim_get_current_win() == state.windows.monitor
    and api.nvim_get_current_buf() == state.buffers.monitor
    and contains(visible, '1 / 3 integrated') and contains(visible, 'DONE') and contains(visible, 'REVIEW'),
    'Persistent dossier rail shows truthful lifecycle states without covering the code')
  check(api.nvim_win_get_buf(state.windows.code) ~= state.buffers.monitor,
    'Inspecting the dossier leaves the coding pane separate and visible')
  app.focus_code()
  check(api.nvim_win_get_buf(state.windows.monitor) == state.buffers.monitor,
    'Returning to handcoding keeps the dossier rail visible')
  wait_for(function()
    local saved = vim.json.decode(table.concat(fn.readfile(state.state_file), '\n'))
    return saved.dossier and saved.dossier.steps[3].session_id == consumer.id
  end, 'Dossier bindings persist beside task history')
  local saved = vim.json.decode(table.concat(fn.readfile(state.state_file), '\n'))
  check(saved.dossier.steps[1].session_id == foundation.id and saved.dossier.steps[2].session_id == docs.id,
    'Saved dossier retains every independently dispatched task identity')
  check(all_requests() == 4, 'Exactly one planning turn and three justified implementation units ran')
  select(consumer)
  app.provider(consumer.provider == 'codex' and 'claude' or 'codex')
  local consumer_peer = selected()
  check(consumer_peer ~= consumer and consumer_peer.workspace.root == consumer.workspace.root
    and consumer_peer.mode == consumer.mode and consumer_peer.dossier_step == 'consumer',
    'Provider handoff retains the unit worktree, mode, and dossier identity')
  check(task('consumer') == consumer_peer and state.dossier.steps[3].session_id == consumer_peer.id,
    'Dossier follows the new provider session for the same deliverable')
  local session_count = #state.sessions
  app.next_step('consumer')
  check(#state.sessions == session_count and all_requests() == 4,
    'An idle provider handoff remains bound and cannot duplicate the deliverable')
  select(planner)
  app.provider(planner.provider == 'codex' and 'claude' or 'codex')
  local planner_peer = selected()
  check(planner_peer ~= planner and planner_peer.dossier_planner == true and planner_peer.mode == 'plan'
    and planner_peer.workspace == nil, 'Planning provider handoff retains its read-only dossier-planner role')
  check(all_requests() == 4, 'Provider selection alone never submits a planning or implementation call')
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
print('Kiln planning integration: ' .. count .. ' assertions passed'); vim.cmd('qa!')

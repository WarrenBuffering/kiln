-- The persistent rail follows the driver's selected outcome, not background activity.
vim.opt.runtimepath:prepend(vim.env.KILN_HOME or vim.fn.getcwd())
local rail = require('kiln.rail')
local count = 0
local function check(value, message) count = count + 1; assert(value, message) end
local function equal(actual, expected, message)
  check(vim.deep_equal(actual, expected), message .. '\nactual: ' .. vim.inspect(actual) .. '\nexpected: ' .. vim.inspect(expected))
end
local function text(view) return table.concat(view.lines, '\n') end
local function contains(view, needle) return text(view):find(needle, 1, true) ~= nil end
local function state()
  return {
    root = '/project', selected = 1,
    sessions = {
      { id = 'code', provider = 'codex', model = 'gpt-6-astra', status = 'running', job = 9,
        workspace = { root = '/worktree/code' } },
      { id = 'board', provider = 'claude', model = 'sonnet', status = 'running', job = 10,
        workspace = { root = '/worktree/board' } },
    },
    contexts = {
      ['/worktree/code'] = { pending_follow = 'scheduler.ex', file_activity = {
        ['scheduler.ex'] = { actor = 'agent', provider = 'codex', at = 1 } } },
      ['/worktree/board'] = { file_activity = {
        ['board.ex'] = { actor = 'agent', provider = 'claude', at = 20 } } },
    },
    dossier = { title = 'Ember dispatch', brief = 'Goal: Launch the highest-priority work.', steps = {
      { id = 'queue', title = 'Prioritized admission', session_id = 'code', rationale = 'Pending jobs need a deterministic capacity boundary.',
        verify = 'Run scheduler tests for ties, limits, and completed jobs.', depends_on = {} },
      { id = 'board', title = 'Readable launch board', session_id = 'board', rationale = 'Operators need each admission decision.',
        verify = 'Run board tests for GO/HOLD rows.', depends_on = {} },
      { id = 'release', title = 'Runnable integration', rationale = 'The actual modules must work together.', provider = 'codex',
        verify = 'Run the runnable demo.', depends_on = { 'queue', 'board' } },
    } },
  }
end
local function run()
  local s = state()
  local before = vim.deepcopy(s)
  local view = rail.render(s, 42, 22)
  equal(s, before, 'Rendering never modifies task state or dispatches work')
  equal(view.active_id, 'queue', 'Selected bound task determines the highlighted outcome')
  equal(view.rows[view.active_row].id, 'queue', 'Highlighted outcome has an actionable row mapping')
  equal(view.rows[view.active_row].session, 1, 'Enter can select the actual task session')
  check(contains(view, 'IMPLEMENTING') and contains(view, 'WAITING'), 'Live and dependency states are distinct')
  check(contains(view, '0 / 3 integrated'), 'Completion count only counts actual integrations')
  equal(view.current_file, 'scheduler.ex', 'Current file belongs to the selected worktree')
  equal(view.file_actor, 'CODEX', 'Actor comes from actual recorded file attribution')
  check(contains(view, 'gpt-6-astra'), 'Selected model is shown')
  local current_marks, titles = 0, {}
  for _, mark in ipairs(view.marks) do
    if mark.group == 'KilnCurrent' then
      current_marks = current_marks + 1
      equal(view.rows[mark.row].id, 'queue', 'Only the driver-selected outcome receives active styling')
      equal(vim.fn.strdisplaywidth(view.lines[mark.row]), 42, 'Active highlight fills the rail width')
    end
  end
  equal(current_marks, 2, 'Both current title and status are highlighted')
  for _, row in pairs(view.rows) do titles[row.id] = true end
  check(titles.queue and titles.board and titles.release, 'All outcome headings stay available')
  s.sessions[2].status, s.sessions[2].job = 'done', nil
  local after = rail.render(s, 42, 22)
  equal(after.active_id, view.active_id, 'Background completion cannot move the active outcome')
  equal(after.active_row, view.active_row, 'Background completion cannot move the active heading')
  check(contains(after, 'REVIEW') and not contains(after, '1 / 3 integrated'), 'Finished generation does not pretend to be integrated')
  s.dossier_focus = 'release'
  view = rail.render(s, 42, 22)
  equal(view.active_id, 'release', 'Explicit inspection can focus an unassigned outcome')
  equal(view.current_file, nil, 'Unassigned outcome never borrows a different task file')
  equal(view.rows[view.active_row].session, nil, 'Unassigned outcome cannot masquerade as an assigned session')
  check(contains(view, 'Waiting for integration'), 'Unmet dependencies remain visible')
  s.dossier_focus, s.selected = nil, 2
  view = rail.render(s, 42, 22)
  equal(view.active_id, 'board', 'Selecting another task moves the rail highlight')
  equal(view.current_file, 'board.ex', 'Fallback uses that worktree’s latest file attribution')
  s.sessions[2].human_control = true
  s.contexts['/worktree/board'].human = { path = 'board_test.exs', active = true, saved = false }
  view = rail.render(s, 42, 22)
  check(contains(view, 'YOU EDIT'), 'Human takeover is explicit')
  equal(view.current_file, 'board_test.exs', 'Human edit is shown ahead of stale agent file activity')
  equal(view.file_actor, 'YOU', 'Human edit attribution is accurate')
  s.sessions[2].human_control, s.sessions[2].reviewed = false, true
  check(contains(rail.render(s, 42, 22), 'REVIEWED'), 'Reviewed snapshot differs from integrated output')
  s.sessions[2].work_status = 'integrated'
  s.sessions[1].job, s.sessions[1].status, s.sessions[1].work_status = nil, 'done', 'integrated'
  view = rail.render(s, 42, 22)
  check(contains(view, '2 / 3 integrated') and contains(view, 'DONE'), 'Integrated outcomes receive completed styling')
  check(contains(view, 'READY'), 'Actual integrated prerequisites release the dependent outcome')
  s.dossier_focus = 'release'
  view = rail.render(s, 42, 22)
  check(contains(view, 'codex / default') or contains(view, 'CODEX / default'), 'Undispatched model assignment does not invent a model')
  s.dossier.steps[3].title = '入場\nnew\trow\27[31m'
  s.dossier.steps[3].rationale = '多文字 unicode why should remain valid and visible.'
  s.dossier_invalid = 'Save\nthis\27issue'
  for _, width in ipairs({ 1, 8, 24, 39 }) do
    view = rail.render(s, width, 14)
    for _, line in ipairs(view.lines) do
      check(vim.fn.strdisplaywidth(line) <= width, 'Every rail line fits the requested display width')
      check(not line:find('%c'), 'Untrusted text cannot introduce control characters into the rail')
      check(vim.fn.strchars(line) >= 0, 'Unicode display text remains a valid string')
    end
  end
  local empty = rail.render({ sessions = {} }, 40, 20)
  check(contains(empty, 'write the outcome'), 'Empty rail provides the initial authoring action')
  equal(empty.active_id, nil, 'No dossier has no imaginary active outcome')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') end
print('Kiln dossier rail: ' .. count .. ' assertions passed')
vim.cmd('qa!')

-- Pure outline rendering uses one chat's actual step runtime.
vim.opt.runtimepath:prepend(vim.env.KILN_HOME or vim.fn.getcwd())
local render = require('kiln.workflow_view').steps
local count = 0
local function check(value, message) count = count + 1; assert(value, message) end
local function equal(actual, expected, message)
  check(vim.deep_equal(actual, expected), message .. '\nactual: ' .. vim.inspect(actual) .. '\nexpected: ' .. vim.inspect(expected))
end
local function text(view) return table.concat(view.lines, '\n') end
local function contains(view, value) return text(view):gsub('%s+', ' '):find(value, 1, true) ~= nil end
local function fixture()
  return {
    selected = 1,
    sessions = {
      { id = 'chat', provider = 'codex', model = 'gpt-6-astra', workflow = {
        phase = 'running', current = 'queue', auto_run = true,
        steps = { queue = { status = 'running' }, board = { status = 'pending' }, demo = { status = 'pending' } },
      } },
      { id = 'background', workflow = { phase = 'running', current = 'board', steps = { board = { status = 'running' } } } },
    },
    dossier = { title = 'Launch queue', steps = {
      { id = 'queue', title = 'Prioritize waiting jobs', rationale = 'Capacity must preserve all pending jobs.', verify = 'Run queue tests for limits and ties.' },
      { id = 'board', title = 'Show GO and HOLD', rationale = 'Operators need a clear admission decision.', verify = 'Assert labels and exact counts.' },
      { id = 'demo', title = 'Run the combined flow', rationale = 'The modules must work together.', verify = 'Run the real demo and assert its output.' },
    } },
  }
end
local function run()
  local s = fixture()
  local before = vim.deepcopy(s)
  local view = render(s, 32, 40)
  equal(s, before, 'Rendering has no dispatch, focus, or state side effects')
  equal(view.active_id, 'queue', 'Only the selected chat runtime defines the active outcome')
  equal(view.rows[view.active_row], { id = 'queue', index = 1, status = 'running' }, 'The active heading maps to its actual step')
  equal(view.completed, 0, 'A running provider is not completed work')
  equal(view.total, 3, 'The count includes every planned outcome')
  check(contains(view, 'Working') and contains(view, 'Waiting'), 'Active and future outcomes remain distinct')
  check(not contains(view, 'integrated') and not contains(view, 'REVIEWED'), 'The outline does not invent integration or review')
  local active_marks = 0
  for _, mark in ipairs(view.marks) do
    if mark.group == 'KilnCurrent' then
      active_marks = active_marks + 1
      equal(view.rows[mark.row].id, 'queue', 'Only the actually active step is highlighted')
      equal(vim.fn.strdisplaywidth(view.lines[mark.row]), 32, 'The current step highlight spans the outline width')
    end
  end
  equal(active_marks, 1, 'One highlight identifies the active outcome without repeating its state')
  local previous = vim.deepcopy(view)
  s.sessions[2].workflow.phase, s.sessions[2].workflow.steps.board.status = 'review', 'done'
  equal(render(s, 32, 40), previous, 'A background chat cannot change the visible step or its state')

  s.workflow_focus = 'demo'
  view = render(s, 32, 40)
  equal(view.active_id, 'queue', 'Inspecting a future outcome does not pretend it is executing')
  equal(view.detail_id, 'demo', 'Explicit inspection shows the requested rationale and checks')
  check(not contains(view, 'Why:') and contains(view, 'Step details'), 'Full rationale belongs behind Enter instead of truncated rail paragraphs')
  s.workflow_focus = nil

  local flow = s.sessions[1].workflow
  flow.phase, flow.reason = 'paused', 'You interrupted to edit the code.'
  view = render(s, 32, 40)
  check(contains(view, 'Paused') and not contains(view, 'Working'), 'Pause is visible before an old running state settles')
  check(contains(view, 'Resume'), 'Paused workflow offers the relevant next action')
  equal(view.rows[view.active_row].status, 'paused', 'Mapped status agrees with the paused heading')
  flow.steps.queue.status, flow.steps.queue.reason = 'blocked', 'The required queue check failed.'
  view = render(s, 32, 40)
  check(contains(view, 'Needs attention'), 'Failed work remains visibly blocked')
  flow.phase, flow.reason, flow.current = 'running', nil, 'board'
  flow.steps.queue.status, flow.steps.board.status = 'done', 'running'
  view = render(s, 32, 40)
  equal(view.active_id, 'board', 'Sequential progression highlights the next actual outcome')
  equal(view.completed, 1, 'Only explicit completed step runtime increments progress')
  check(contains(view, '1 / 3 implemented'), 'Progress names implementation rather than review')
  check(contains(view, 'Implemented'), 'Completed outcomes are visibly retained')
  check(not contains(view, 'passed'), 'Agent completion does not invent a successful test result')

  flow.phase, flow.current = 'review', nil
  for _, runtime in pairs(flow.steps) do runtime.status = 'done' end
  view = render(s, 32, 40)
  check(contains(view, 'Ready for review') and contains(view, '3 / 3 implemented'), 'Finished implementation still requires review')
  equal(view.active_id, nil, 'A finished workflow has no imaginary executing step')
  equal(view.active_row, nil, 'Finished work has no active-row target')
  equal(view.detail_id, 'demo', 'Final details remain inspectable without an active execution')
  s.selected = 2
  view = render(s, 32, 40)
  equal(view.active_id, 'board', 'Changing the selected chat reads that chat runtime')
  equal(view.completed, 1, 'Completion never leaks between chats')

  s = fixture()
  local runtime = s.sessions[1].workflow
  runtime.phase, runtime.current = 'ready', nil
  view = render(s, 32, 40)
  check(contains(view, 'Start'), 'A ready plan offers Start instead of pretending to run')
  equal(view.active_id, nil, 'Ready does not synthesize a running step')
  equal(view.detail_id, 'queue', 'Ready plan previews the first unfinished outcome')
  runtime.current = 'removed-step'
  equal(render(s, 32, 40).active_id, nil, 'A removed runtime ID cannot become a phantom step')
  runtime.steps.queue.status = 'unrecognized'
  check(contains(render(s, 32, 40), 'Waiting'), 'Unknown runtime status never becomes fictional success')

  local evidence = require('kiln.evidence')
  runtime.current, runtime.steps.queue.status, runtime.phase = 'queue', 'running', 'running'
  evidence.observe(s.sessions[1], { type = 'tool', name = 'Shell', id = 'actual', step_id = 'queue', status = 'done',
    text = 'elixir queue_test.exs\n6 tests, 0 failures\n[exit 0]' })
  runtime.steps.queue.status, runtime.steps.board.status, runtime.current = 'done', 'running', 'board'
  evidence.observe(s.sessions[1], { type = 'file', path = 'board.ex', step_id = 'board' })
  view = render(s, 32, 40)
  check(contains(view, '6 tests passed'), 'Actual completed checks appear beside their outcome')
  check(contains(view, 'Changed board.ex'), 'Active outcome shows its actual latest file change')
  check(not contains(view, 'Verify:') and not contains(view, 'Why:'), 'The rail does not chop explanatory prose into fragments')
  s.current_action = { primary = 'Wait' }
  check(contains(render(s, 32, 40), 'Space Enter Wait'), 'Primary footer agrees with the shared control strip')
  s.current_action = nil
  evidence.observe(s.sessions[1], { type = 'tool', name = 'Bash', id = 'failed', step_id = 'board', status = 'error',
    text = '{"command":"elixir board_test.exs"}\n4 tests, 1 failure' })
  check(contains(render(s, 32, 40), '1 check(s) failed'), 'Actual failed check overrides generic working status')
  for index = 4, 24 do
    s.dossier.steps[index] = { id = 'step-' .. index, title = 'Outcome ' .. index,
      rationale = 'A distinct observable behavior.', verify = 'Check the result.' }
  end
  view = render(s, 32, 8)
  local ids, last_heading = {}, 0
  for row, item in pairs(view.rows) do
    ids[item.id] = true
    if view.lines[row]:find('Outcome 24', 1, true) then last_heading = row end
  end
  for _, step in ipairs(s.dossier.steps) do check(ids[step.id], 'Short windows retain the full scrollable plan: ' .. step.id) end
  check(last_heading > 8, 'Long plans extend the buffer instead of silently hiding steps')
  check(last_heading < #view.lines, 'Step details follow every outcome heading')

  s.dossier.title = '发射\nqueue\t\27[31m'
  s.dossier.steps[1].title = '入場\nnext\t\0row😀'
  s.dossier.steps[1].rationale = '多文字 explanation with a very_long_word_that_should_clip_safely'
  s.dossier_invalid = 'Bad\rplan\27'
  runtime.current = 'queue'
  for _, width in ipairs({ 1, 5, 19, 31 }) do
    view = render(s, width, 8)
    for _, line in ipairs(view.lines) do
      check(vim.fn.strdisplaywidth(line) <= width, 'Every line respects the available display-cell width')
      check(not line:find('%c'), 'Untrusted plan text cannot inject terminal control characters')
    end
  end
  view = render({ sessions = {} }, 28, 10)
  check(contains(view, 'Plan in the chat'), 'The empty state directs planning into the one chat')
  equal(view.active_id, nil, 'No dossier has no imaginary active step')
  equal(view.total, 0, 'No dossier has no invented step count')
end

local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') end
print('Kiln workflow view: ' .. count .. ' assertions passed')
vim.cmd('qa!')

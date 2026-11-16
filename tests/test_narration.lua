-- The compact dossier feed is a bounded projection of real current-turn events.
local fn = vim.fn
vim.opt.runtimepath:prepend(vim.env.KILN_HOME or fn.getcwd())
local narration = require('kiln.narration')
local count = 0
local function check(value, message) count = count + 1; assert(value, message) end
local function text(view) return table.concat(view.lines, '\n') end
local function has(view, value) return text(view):find(value, 1, true) ~= nil end
local function contains_event(view, event)
  for _, value in pairs(view.rows) do if value == event then return true end end
  return false
end
local function limits(view, width, height)
  check(#view.lines <= height, 'Compact feed fits the available height')
  check(#view.lines == 0 or view.lines[#view.lines] ~= '', 'No trailing blank row pushes content out of view')
  for index, line in ipairs(view.lines) do
    check(fn.strdisplaywidth(line) <= width and not line:find('%c'), 'Visible text fits without terminal control bytes')
    check(view.rows[index] ~= nil, 'Every visible line opens an actual event')
  end
end
local function run()
  local old_error = { type = 'error', text = 'Old permission problem' }
  local old_message = { type = 'message', role = 'assistant', text = 'Earlier implementation result' }
  local request = { type = 'message', role = 'user', text = 'Add the queue limit and preserve my changes.' }
  local first = { type = 'message', role = 'assistant', text = 'I will inspect the queue first.' }
  local latest = { type = 'message', role = 'assistant', text = 'I will keep completed jobs out of admission and preserve the title ordering.' }
  local file = { type = 'file', action = 'update', path = 'lib/queue.ex' }
  local noise = { type = 'notice', text = string.rep('Unrelated plugin diagnostics ', 80) }
  local session = { provider = 'codex', status = 'running', events = { old_error, old_message, request, first, latest, file, noise } }
  local original = vim.deepcopy(session)
  local view = narration.render(session, 40, 8)
  check(contains_event(view, latest) and contains_event(view, file), 'Latest explanation and observed file change remain visible')
  check(not contains_event(view, first) and not contains_event(view, old_message) and not contains_event(view, old_error),
    'Earlier narration and prior-turn failures do not crowd the current turn')
  check(not has(view, 'plugin diagnostics') and not contains_event(view, noise), 'Generic notice diagnostics stay in full history')
  check(vim.deep_equal(session, original), 'Compact rendering does not alter raw events or status')
  check(has(view, 'CODEX') and has(view, 'FILE / update') and has(view, 'lib/queue.ex'), 'Provider and file labels describe actual events')
  limits(view, 40, 8)

  local tool = { type = 'tool', name = 'Shell', status = 'running', text = 'elixir queue_test.exs\n' .. string.rep('long output ', 60) }
  session.events[#session.events + 1] = tool
  view = narration.render(session, 40, 7)
  check(contains_event(view, tool) and not contains_event(view, file), 'Most recent tool action replaces the older file action')
  check(contains_event(view, latest), 'Large tool output cannot displace the latest explanation entirely')
  limits(view, 40, 7)

  local blocked = { type = 'error', text = 'Bash needs approval before tests can run.' }
  session.events[#session.events + 1] = blocked
  view = narration.render(session, 36, 6)
  check(view.rows[1] == blocked and view.marks[1].group == 'KilnError', 'A current-turn error is presented first and marked visibly')
  check(has(view, 'needs approval') and contains_event(view, latest), 'Error and explanation share the compact view when space permits')
  limits(view, 36, 6)
  local failed_tool = { type = 'tool', name = 'Shell', status = 'error', text = 'Command exited with status 1.' }
  session.events[#session.events + 1] = failed_tool
  view = narration.render(session, 36, 6)
  check(view.rows[1] == failed_tool and has(view, 'ATTENTION / Shell'), 'Tool failures receive the same priority as normalized errors')
  local count_failed = 0
  for _, item in pairs(view.rows) do if item == failed_tool then count_failed = count_failed + 1 end end
  check(count_failed <= 3, 'Failed action is not duplicated as both error and recent tool')

  local next_request = { type = 'message', role = 'user', text = 'Use the approved test path.' }
  session.events[#session.events + 1] = next_request
  view = narration.render(session, 36, 6)
  check(contains_event(view, next_request) and not contains_event(view, blocked) and not contains_event(view, latest),
    'A new request resets compact activity without replaying stale errors or explanations')
  check(not has(view, 'working') and has(view, 'approved test path'), 'Waiting state displays actual request text without invented progress')

  local hold = { type = 'notice', text = 'You control this worktree. Save your edits, then send a prompt to hand it back.' }
  session.human_control = true
  session.events[#session.events + 1] = hold
  view = narration.render(session, 40, 5)
  check(contains_event(view, hold) and has(view, 'YOU EDIT'), 'Actual takeover notice appears while the user owns the worktree')
  local saved = { type = 'human', path = 'lib/queue.ex', text = 'lib/queue.ex\nIncluded in the next handoff.' }
  session.events[#session.events + 1] = saved
  view = narration.render(session, 40, 5)
  check(contains_event(view, saved) and not contains_event(view, hold) and has(view, 'YOU SAVED'),
    'Latest real editor save replaces the older takeover notice')
  session.human_control = false
  view = narration.render(session, 40, 5)
  check(not contains_event(view, saved) and not contains_event(view, hold), 'Human ownership notices disappear after handback')

  local unicode = { type = 'message', role = 'assistant', text = '界😀\n' .. string.rep('長いファイル名', 20) .. '\27[31m\tend' }
  session.events[#session.events + 1] = unicode
  for _, dimensions in ipairs({ { 1, 1 }, { 12, 3 }, { 24, 5 }, { 40, 8 } }) do
    local width, height = dimensions[1], dimensions[2]
    view = narration.render(session, width, height)
    limits(view, width, height)
    check(contains_event(view, unicode), 'Narrow views still reference the actual latest event')
  end
  check(#narration.render(session, 0, 8).lines == 0 and #narration.render(session, 40, 0).lines == 0,
    'Unavailable view dimensions produce no invented or overflowing rows')
  check(#narration.render({ events = {} }, 40, 8).lines == 0, 'Empty history produces no synthetic activity')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') end
print('Kiln compact narration: ' .. count .. ' assertions passed'); vim.cmd('qa!')

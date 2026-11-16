-- Conversation projection keeps explanations readable and raw evidence available.
local fn = vim.fn
vim.opt.runtimepath:prepend(vim.env.KILN_HOME or fn.getcwd())
local conversation = require('kiln.conversation')
local dossier = require('kiln.dossier')
local count = 0
local function check(value, message) count = count + 1; assert(value, message) end
local function has(view, value) return table.concat(view.lines, '\n'):find(value, 1, true) ~= nil end
local function rows(view, event)
  local result = {}
  for index, value in pairs(view.rows) do if value == event then result[#result + 1] = index end end
  return result
end
local function groups(view)
  local result, seen = {}, {}
  for _, event in pairs(view.rows) do
    if event.type == 'activity' and not seen[event] then result[#result + 1], seen[event] = event, true end
  end
  return result
end
local proposal = table.concat({
  '# Launch queue', 'Goal: Admit pending launches.', 'Approach: Reuse ordering.',
  'Why this approach: Keep capacity decisions centralized.', '',
  '## Step admit: Admit pending jobs', 'Outcome: Return GO/HOLD groups.',
  'Why: Operators need launch decisions.', 'Verify: Run elixir scheduler_test.exs.', 'Depends: none',
}, '\n')
local function run()
  for _, provider in ipairs({ 'codex', 'claude' }) do
    local request = { type = 'message', role = 'user', text = 'Keep alphabetical ties.' }
    local explanation = { type = 'message', role = 'assistant', text = 'I will preserve order.ex and add the admission check.', paths = { 'scheduler.ex' } }
    local tool = { type = 'tool', name = provider == 'codex' and 'Shell' or 'Bash', status = 'done',
      text = 'elixir scheduler_test.exs\n6 tests, 0 failures\n' .. string.rep('captured output ', 100) }
    local file = { type = 'file', path = 'scheduler.ex', action = 'update' }
    local diagnostic = { type = 'status', text = string.rep('provider startup diagnostic ', 200) }
    local usage = { type = 'usage', input_tokens = 30, output_tokens = 12 }
    local finish = { type = 'message', role = 'assistant', text = 'Admission now preserves ties.\n<kiln_step_complete id="admit"/>' }
    local session = { provider = provider, workflow = { phase = 'running' },
      events = { request, explanation, tool, file, diagnostic, usage, finish } }
    local original = vim.deepcopy(session)
    local view = conversation.render(session, { width = 24 })
    check(has(view, request.text) and has(view, explanation.text), provider .. ': human conversation and explanation preserved')
    check(has(view, '↳ scheduler.ex') and #rows(view, explanation) > 1, provider .. ': changed-file reference stays linked to its explanation')
    check(has(view, 'Admission now preserves ties.') and not has(view, '<kiln_step_complete'), provider .. ': protocol marker hidden')
    check(not has(view, 'captured output') and not has(view, 'provider startup'), provider .. ': diagnostics and shell output collapsed')
    local grouped = groups(view)
    check(#grouped == 1 and #grouped[1].events == 4, provider .. ': consecutive activity shares one group')
    check(grouped[1].events[1] == tool and grouped[1].events[2] == file, provider .. ': original event references retained')
    check(grouped[1].text:find(tool.text, 1, true) and grouped[1].text:find(diagnostic.text, 1, true), provider .. ': inspection retains exact complete output')
    check(grouped[1].text:find('input_tokens', 1, true), provider .. ': usage fields retained in inspection')
    check(#rows(view, explanation) > 0 and #rows(view, request) > 0, provider .. ': message rows inspect original messages')
    check(vim.deep_equal(session, original), provider .. ': renderer does not mutate event history')
    for _, row in ipairs(rows(view, grouped[1])) do
      check(fn.strdisplaywidth(view.lines[row]) <= 24, provider .. ': activity preview fits narrow pane')
    end

    local failed = { type = 'tool', name = tool.name, status = 'error', text = 'Test assertion failed\nExpected 3; got 2.' }
    local denied = { type = 'error', text = 'Permission required to continue.' }
    session.events = { request, tool, failed, diagnostic, denied }
    view = conversation.render(session, { width = 40 })
    check(has(view, 'ATTENTION') and has(view, failed.text:match('^[^\n]+')) and has(view, denied.text), provider .. ': failures visible without opening activity')
    check(#rows(view, failed) > 0 and #rows(view, denied) > 0, provider .. ': real failure rows inspect full original error')
    for _, mark in ipairs(view.marks) do
      if view.rows[mark.row] == failed or view.rows[mark.row] == denied then check(mark.group == 'KilnError', 'Failure highlighted') end
    end
    check(#groups(view) == 2, provider .. ': errors divide unrelated activity groups')
  end

  local plan = assert(dossier.parse(proposal))
  local message = { type = 'message', role = 'assistant', text = 'Two concerns are separate.\n```dossier\n' .. proposal .. '\n```\nReady when you are.' }
  local session = { provider = 'codex', workflow = { phase = 'ready' }, events = { message } }
  local view = conversation.render(session, { width = 45, plan = plan })
  check(has(view, 'Plan ready · 1 step') and not has(view, '## Step admit'), 'Accepted dossier collapsed to count')
  check(has(view, 'Two concerns are separate.') and has(view, 'Ready when you are.'), 'Narration around proposal retained')
  check(#rows(view, message) > 0 and view.rows[rows(view, message)[1]].text == message.text, 'Collapsed proposal opens exact original Markdown')
  view = conversation.render(session, { plan = plan, accepted = false })
  check(has(view, '## Step admit') and not has(view, 'Plan ready'), 'Unaccepted proposal stays visible')
  local revised = assert(dossier.parse(proposal:gsub('Return GO/HOLD groups.', 'Return revised decisions.')))
  view = conversation.render(session, { plan = revised })
  check(has(view, '## Step admit') and not has(view, 'Plan ready'), 'Different proposal never falsely marked accepted')
  session.workflow.phase = 'planning'
  view = conversation.render(session, { plan = plan })
  check(has(view, '## Step admit'), 'Planning with prior dossier does not falsely fold a proposal')
  session.workflow.phase = 'ready'
  message.text = proposal
  view = conversation.render(session, { plan = plan })
  check(has(view, 'Plan ready') and not has(view, '## Step admit'), 'Bare complete dossier can fold too')
  message.text = '```markdown\n' .. proposal .. '\n```'
  view = conversation.render(session, { plan = plan })
  check(has(view, 'Plan ready'), 'Accepted Markdown fence folds')
  message.text = '```dossier\n' .. proposal
  view = conversation.render(session, { plan = plan })
  check(has(view, '## Step admit') and not has(view, 'Plan ready'), 'Streaming unfinished proposal not dropped')

  message.text = '```elixir\nIO.puts("hello")\n```\n```xml\n<kiln_step_complete id="example"/>\n```\nActual explanation.'
  view = conversation.render(session, { plan = plan })
  check(has(view, 'IO.puts("hello")') and has(view, '<kiln_step_complete id="example"/>'), 'Ordinary source fences and literal protocol example retained')
  message.role, message.text = 'user', '<kiln_step_complete id="literal"/>'
  view = conversation.render(session, {})
  check(has(view, message.text), 'User text is never treated as hidden provider protocol')

  local human = { type = 'human', path = '/project/order.ex', text = '/project/order.ex\nIncluded in the next handoff.' }
  session.events = { human }
  view = conversation.render(session, { root = '/project' })
  check(has(view, 'YOU SAVED') and has(view, 'order.ex saved') and not has(view, '/project'), 'Human save is visible and repository-relative')
  check(view.rows[2] == human and view.rows[2].text == human.text, 'Full saved handoff retained for inspection')
  check(not has(view, 'will be reread'), 'Historical save does not invent pending handoff status')
  session.events = { { type = 'status', text = '界😀\27[31m' .. string.rep('long', 90) } }
  for _, width in ipairs({ 1, 2, 12, 24, 45 }) do
    view = conversation.render(session, { width = width })
    for _, line in ipairs(view.lines) do
      check(fn.strdisplaywidth(line) <= width and not line:find('%c'), 'Narrow activity is clipped without control bytes')
    end
    check(#groups(view) == 1, 'Narrow activity remains inspectable')
  end
  check(#conversation.render({}, {}).lines == 0, 'No history produces no invented activity')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') end
print('Kiln conversation view: ' .. count .. ' assertions passed'); vim.cmd('qa!')

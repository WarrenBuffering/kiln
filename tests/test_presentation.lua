-- Pure ownership/action presentation never guesses completion from a message.
vim.opt.runtimepath:prepend(vim.env.KILN_HOME or vim.fn.getcwd())
local presentation = require('kiln.presentation')
local count = 0
local function check(value, message) count = count + 1; assert(value, message) end
local function equal(actual, expected, message)
  check(vim.deep_equal(actual, expected), message .. '\nactual: ' .. vim.inspect(actual) .. '\nexpected: ' .. vim.inspect(expected))
end
local plan = { steps = { { id = 'admit' }, { id = 'report' } } }
local function fixture(provider)
  return { provider = provider, workflow = { phase = 'running', current = 'report' }, job = 42 }
end
local function run()
  for _, provider in ipairs({ 'codex', 'claude' }) do
    local session = fixture(provider)
    local options = { action = 'Editing board.ex', handoff = {} }
    local before = vim.deepcopy(session)
    local view = presentation.current(session, plan, options)
    equal(session, before, provider .. ': rendering is read-only')
    equal(view.control, 'AGENT WORKING', provider .. ': live job owns the work')
    equal(view.primary, 'Take over', provider .. ': primary action matches active writer')
    check(view.text:find('Step 2/2', 1, true) and view.text:find('Editing board.ex', 1, true), provider .. ': action names current step and observed work')
    check(view.text:find(provider, 1, true), provider .. ': provider is named')
    session.status, session.workflow.phase = 'done', 'review'
    view = presentation.current(session, plan, options)
    equal(view.control, 'AGENT WORKING', provider .. ': completion event does not grant control before process exit')
    session.stopping = true
    view = presentation.current(session, plan, { human_control = true })
    equal(view.control, 'STOPPING', provider .. ': stopping precedes human control while process remains alive')
    equal(view.primary, 'Wait', provider .. ': cannot resume while writer is stopping')
    local left, right = presentation.bar(view, 80)
    check(left:find('STOPPING', 1, true) and right:find('Stopping', 1, true), provider .. ': stopping strip offers no start action')
    session.job = nil
    view = presentation.current(session, plan, { human_control = true })
    equal(view.control, 'YOU HAVE CONTROL', provider .. ': confirmed process exit grants human control')
    equal(view.primary, 'Resume', provider .. ': saved plan can resume')
    view = presentation.current(session, plan, { human_control = true, dirty = true, handoff = { 'order.ex' } })
    check(view.text:find('Save your code', 1, true), provider .. ': unsaved edits take precedence over older saved handoff')
    view = presentation.current(session, plan, { human_control = true, handoff = { 'order.ex', 'board.ex' } })
    check(view.text:find('order.ex, board.ex saved', 1, true), provider .. ': handoff names saved files')
    check(view.text:find('reread on resume', 1, true), provider .. ': handoff does not claim already acknowledged')
    session.stopping, session.job, session.resuming = nil, 42, true
    view = presentation.current(session, plan, { handoff = { 'order.ex' } })
    equal(view.control, 'RESUMING', provider .. ': resume remains distinct until provider activity')
    check(view.text:find('saved edits', 1, true), provider .. ': saved handoff shown during resumption')
    view = presentation.current(session, plan, { handoff = {} })
    check(not view.text:find('saved', 1, true), provider .. ': resume without a save never invents saved edits')
    session.resuming = false
    view = presentation.current(session, plan, { pinned = true })
    check(view.text:find('Waiting for provider', 1, true), provider .. ': unknown activity is honestly waiting')
    check(view.text:find('code pinned', 1, true), provider .. ': frozen code view is explicit')
    session.job, session.native_job = nil, 55
    equal(presentation.current(session, plan).control, 'AGENT WORKING', provider .. ': native provider job retains ownership')
    session.native_job, session.operation = nil, {}
    equal(presentation.current(session, plan).primary, 'Take over', provider .. ': active operation cannot appear idle')
    session.operation = nil
    view = presentation.current(session, plan, { review_summary = '11 tests passed · 5 files changed', pinned = true })
    equal(view.control, 'READY FOR REVIEW', provider .. ': idle completion has review action')
    equal(view.primary, 'Review', provider .. ': completion is not automatic approval')
    equal(view.text, '11 tests passed · 5 files changed', provider .. ': supplied observed review summary is retained without stale pinned state')
    session.workflow.phase, session.workflow.current = 'ready', nil
    view = presentation.current(session, plan)
    equal(view.control, 'PLAN READY', provider .. ': planning readiness is distinct from execution')
    equal(view.primary, 'Start', provider .. ': ready plan has one start action')
    check(view.text:find('2 justified steps', 1, true), provider .. ': ready count comes from actual plan')
    session.workflow.phase, session.workflow.reason = 'paused', 'The report check failed.'
    view = presentation.current(session, plan)
    equal(view.control, 'PAUSED', provider .. ': explicit pause remains visible')
    equal(view.text, 'The report check failed.', provider .. ': actual blocking reason is retained')
    session.workflow.phase, session.workflow.reason = 'planning', nil
    view = presentation.current(session, nil)
    equal(view.primary, 'Plan', provider .. ': initial chat does not offer execution')
    check(not view.text:find('passed', 1, true), provider .. ': planning does not invent check results')
    session.workflow.phase = 'running'
    view = presentation.current(session, plan)
    equal(view.control, 'CONTINUING', provider .. ': sequential dispatch gap does not fall back to planning')
    equal(view.primary, 'Pause', provider .. ': queued continuation remains interruptible')
  end
  for _, width in ipairs({ 1, 2, 5, 18, 40, 80, 156 }) do
    for _, text in ipairs({ 'board.ex', 'ステップ一 · 编辑代码', '100% reviewed', 'line\nbreak\tstate' }) do
      local clipped = presentation.clip(text, width)
      check(vim.fn.strdisplaywidth(clipped) <= width, 'Unicode clipped to display columns at ' .. width)
      check(not clipped:find('%c'), 'Control characters stay off the status strip')
      check(vim.str_utfindex(clipped) ~= nil, 'Clipping preserves complete Unicode characters')
    end
  end
  equal(presentation.clip('100% complete', 30), '100% complete', 'Pure presentation retains percent text for caller escaping')
  for _, width in ipairs({ 40, 80, 156 }) do
    for _, control in ipairs({ 'AGENT WORKING', 'STOPPING', 'YOU HAVE CONTROL', 'READY FOR REVIEW' }) do
      local left, right = presentation.bar({ control = control, text = string.rep('work ', 100), primary = 'Take over' }, width)
      check(vim.fn.strdisplaywidth(left) + vim.fn.strdisplaywidth(right) + 5 <= width, 'Action and state fit together at ' .. width)
      check(right:find('Space Enter', 1, true), 'Primary key is visible')
    end
  end
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') end
print('Kiln current action: ' .. count .. ' assertions passed')
vim.cmd('qa!')

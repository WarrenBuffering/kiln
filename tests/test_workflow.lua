-- Pure workflow state transitions. Provider lifecycle integration is covered by
-- the conversation tests; these callbacks never launch a model or subprocess.
vim.opt.runtimepath:prepend(vim.env.KILN_HOME or vim.fn.getcwd())
local workflow, dossier = require('kiln.workflow'), require('kiln.dossier')
local assertions = 0
local function check(value, message) assertions = assertions + 1; assert(value, message) end
local function equal(value, expected, message)
  check(vim.deep_equal(value, expected), message .. '\nactual: ' .. vim.inspect(value) .. '\nexpected: ' .. vim.inspect(expected))
end
local function contains(value, text) return tostring(value):find(text, 1, true) ~= nil end
local function document(first, second, brief)
  return table.concat({ '# Queue change', 'Goal: Preserve queued work.', 'Approach: Implement admission, then its display.',
    'Why this approach: Display consumes the admission map.', 'Constraints: ' .. (brief or 'Plain Elixir.'), '',
    '## Step admission: Admit pending jobs', 'Outcome: ' .. (first or 'Return accepted and deferred jobs.'),
    'Why: Capacity must not lose jobs.', 'Verify: Run scheduler tests.', 'Depends: none', '',
    '## Step display: Display the decision', 'Outcome: ' .. (second or 'Show GO and HOLD rows.'),
    'Why: Operators need the actual decision.', 'Verify: Run board tests and demo.', 'Depends: admission',
    'Dependency reason: The real admission map is required.' }, '\n')
end
local function fixture()
  local state = { sessions = {}, selected = 1 }
  local session = { id = 'one-chat', provider = 'codex', native_id = 'unchanged-native-id', mode = 'plan', events = {} }
  state.sessions[1] = session
  local f = { state = state, session = session, sends = {}, queued = {}, notices = {}, stops = 0, loads = 0, refreshes = 0 }
  workflow.setup({ state = state,
    notify = function(message) f.notices[#f.notices + 1] = message end,
    persist = function() end,
    refresh = function() f.refreshes = f.refreshes + 1 end,
    dirty = function() return f.dirty, f.dirty_reason end,
    stop = function(target) equal(target, session, 'Stop targets the same chat'); f.stops = f.stops + 1 end,
    focus_prompt = function() f.focused = true end,
    show_plan = function() f.shown = true end,
    schedule = function(callback) f.queued[#f.queued + 1] = callback end,
    load_plan = function(text, target)
      equal(target, session, 'Proposal belongs to the same conversation')
      f.loads = f.loads + 1
      local plan = assert(dossier.parse(text))
      local ok = workflow.accept(target, plan, state.dossier)
      if ok then state.dossier, state.dossier_text = plan, text end
      return ok
    end,
    send = function(target, prompt, mode, meta)
      equal(target, session, 'Implementation uses the same session')
      local actual = workflow.prepare(target, prompt, meta)
      f.sends[#f.sends + 1] = { prompt = actual, mode = mode, meta = meta, native_id = target.native_id }
      target.events[#target.events + 1] = { type = 'message', role = 'user', text = 'Implement next step' }
      target.job = 100 + #f.sends
      return true
    end,
  })
  workflow.init(session)
  function f:adopt(text)
    local plan = assert(dossier.parse(text or document()))
    local ok = workflow.accept(session, plan, state.dossier)
    if ok then state.dossier, state.dossier_text = plan, text or document() end
    return ok
  end
  function f:message(text)
    session.events[#session.events + 1] = { type = 'message', role = 'assistant', text = text }
  end
  function f:complete(text, ok)
    self:message(text)
    session.job = nil
    workflow.completed(session, ok ~= false)
  end
  function f:drain()
    local pending = self.queued; self.queued = {}
    for _, callback in ipairs(pending) do callback() end
  end
  return f
end

local function planning()
  local f = fixture()
  local actual = workflow.prepare(f.session, 'Build a launch queue.')
  check(contains(actual, 'Ask concise questions') and contains(actual, 'USER MESSAGE:\nBuild a launch queue.'), 'Planning remains a conversational read-only prompt')
  equal(f.session.mode, 'plan', 'Initial chat is read-only planning')
  f:complete('Should completed jobs remain visible?')
  equal(f.loads, 0, 'A clarification question does not invent a ready plan')
  equal(f.session.workflow.phase, 'planning', 'Planning continues in the same conversation')
  workflow.prepare(f.session, 'No. Exclude completed jobs.')
  f:complete('Here is the agreed approach.\n```dossier\n' .. document() .. '\n```')
  equal(f.loads, 1, 'A valid final dossier is adopted exactly once')
  equal(f.session.workflow.phase, 'ready', 'A parsed proposal is ready, not running')
  check(f.shown, 'Ready plan is shown')
  equal(#f.sends, 0, 'Planning never implicitly starts implementation')
  equal(#f.state.sessions, 1, 'Planning has not created another chat')
  workflow.prepare(f.session, 'Revise the report to include counts.')
  equal(f.session.mode, 'plan', 'A follow-up to a ready dossier still plans')
  f:complete('```dossier\n' .. document(nil, 'Show GO/HOLD rows and counts.') .. '\n```')
  equal(f.session.workflow.phase, 'ready', 'A revised proposal returns to ready')
  equal(f.session.workflow.revision, 2, 'Proposal revision is tracked')
  equal(f.session.native_id, 'unchanged-native-id', 'Native planning conversation remains intact')

  workflow.prepare(f.session, 'Another question.')
  f:complete('Do you need colors?')
  equal(f.loads, 2, 'An earlier plan is not reused as this turn\'s proposal')
  workflow.prepare(f.session, 'Use plain text.')
  f.dirty, f.dirty_reason = true, 'Unsaved dossier changes.'
  f:complete('```dossier\n' .. document(nil, 'Show plain rows.') .. '\n```')
  equal(f.loads, 2, 'Unsaved edits prevent proposal replacement')
  check(contains(f.session.workflow.proposal, 'Show plain rows.'), 'Deferred proposal is retained')
  equal(f.session.workflow.reason, 'Unsaved dossier changes.', 'Unsaved guard gives the actual reason')
  f.dirty = false
  check(not workflow.run(f.session), 'Deferred newer proposal prevents accidentally running the old plan')
  equal(#f.sends, 0, 'Deferred proposal does not launch stale work')
  check(workflow.adopt(f.session), 'Saved edits allow explicit deferred-proposal adoption')
  check(not f.session.workflow.proposal and contains(f.state.dossier_text, 'Show plain rows.'), 'Adoption installs the deferred proposal and clears its gate')

  local bad = fixture()
  workflow.prepare(bad.session, 'Plan it.')
  bad:complete('```dossier\n# Missing required fields\n```')
  equal(bad.loads, 0, 'Malformed plan is never adopted')
  workflow.prepare(bad.session, 'Try again.')
  bad:complete(document(), false)
  equal(bad.loads, 0, 'Failed provider turn cannot adopt a plan')
end

local function sequence()
  local f = fixture(); f:adopt()
  check(workflow.run(f.session), 'Run starts the ready plan')
  equal(f.session.workflow.current, 'admission', 'First step runs first')
  equal(f.session.workflow.steps.admission.status, 'running', 'Actual dispatched step is running')
  equal(f.sends[1].mode, 'edit', 'Implementation turns permit edits')
  check(contains(f.sends[1].prompt, '<kiln_step_complete id="admission"/>'), 'Step prompt requests its scoped completion marker')
  check(contains(f.sends[1].prompt, 'Do not commit, merge, push, or deploy.'), 'Sequential implementation does not implicitly integrate')
  f:message('<kiln_step_complete id="admission"/>')
  workflow.completed(f.session, true)
  equal(f.session.workflow.steps.admission.status, 'running', 'Result event cannot complete a still-running process')
  f:complete('Implemented the decision. Tests pass.\n<kiln_step_complete id="admission"/>')
  equal(f.session.workflow.steps.admission.status, 'done', 'A successful scoped completion marks implementation done')
  equal(f.session.workflow.steps.admission.completion, 'agent-reported', 'Completion is explicitly attributed to the agent')
  equal(#f.sends, 1, 'Next step waits for the scheduled continuation')
  f:drain()
  equal(#f.sends, 2, 'Next step starts after the prior process has exited')
  equal(f.session.workflow.current, 'display', 'Second step is current')
  equal(f.sends[2].native_id, f.sends[1].native_id, 'Both steps retain the native conversation')
  equal(#f.state.sessions, 1, 'Serial execution does not create task sessions')
  f:complete('The report is implemented.\n<kiln_step_complete id="display"/>')
  equal(f.session.workflow.phase, 'review', 'Finished implementation awaits human review')
  equal(f.session.workflow.current, nil, 'No step remains running')
  check(not f.session.workflow.auto_run, 'Auto execution stops at the end')
  equal(#f.queued, 0, 'Finished plan queues no extra work')
end

local function interruption()
  local f = fixture(); f:adopt(); workflow.run(f.session)
  workflow.pause(f.session, 'Handcoding now.')
  equal(f.stops, 1, 'Interruption stops the current writer')
  f:complete('Late success\n<kiln_step_complete id="admission"/>')
  equal(f.session.workflow.steps.admission.status, 'paused', 'Late result cannot undo an interruption')
  f:drain(); equal(#f.sends, 1, 'Interrupted result cannot dispatch later steps')
  local actual = workflow.prepare(f.session, 'Keep my correction and add its regression.')
  equal(f.session.mode, 'edit', 'Corrective handback remains in the same editing conversation')
  check(contains(actual, 'USER DIRECTION:\nKeep my correction'), 'Handback keeps the actual user direction')
  check(f.session.workflow.auto_run, 'A corrective handback resumes the already approved sequence')
  f:complete('Correction preserved.\n<kiln_step_complete id="admission"/>')
  workflow.pause(f.session, 'Wait before the next step.')
  f:drain()
  equal(#f.sends, 1, 'Pause cancels already queued advancement')
  equal(f.session.workflow.steps.admission.status, 'done', 'Pausing after completion does not erase the completed step')
  workflow.run(f.session)
  equal(f.session.workflow.current, 'display', 'Explicit resume continues at the next unfinished step')
  f:complete('Report needs a decision from you.')
  equal(f.session.workflow.steps.display.status, 'paused', 'Question without completion marker pauses')
  equal(f.session.workflow.phase, 'paused', 'Missing completion is visible rather than assumed')

  local failure = fixture(); failure:adopt(); workflow.run(failure.session)
  failure:complete('Unable to run the checks.\n<kiln_step_complete id="admission"/>', false)
  equal(failure.session.workflow.steps.admission.status, 'blocked', 'CLI failure wins over any claimed completion')
  equal(#failure.queued, 0, 'Failure never starts another step')
end

local function stale_and_dirty()
  for _, response in ipairs({ '<kiln_step_complete id="display"/>',
    '```\n<kiln_step_complete id="admission"/>\n```', 'quoted <kiln_step_complete id="admission"/>',
    '<kiln_step_complete id="admission"/>\nActually, should empty queues be an error?' }) do
    local f = fixture(); f:adopt(); workflow.run(f.session); f:complete(response)
    equal(f.session.workflow.steps.admission.status, 'paused', 'Wrong, quoted, or fenced marker cannot complete a step')
  end
  local f = fixture(); f:adopt()
  f:message('<kiln_step_complete id="admission"/>')
  workflow.run(f.session)
  f.session.events[#f.session.events + 1] = { type = 'tool', text = '<kiln_step_complete id="admission"/>' }
  f.session.job = nil; workflow.completed(f.session, true)
  equal(f.session.workflow.steps.admission.status, 'paused', 'Old assistant and current tool markers are excluded')

  local dirty = fixture(); dirty:adopt(); dirty.dirty = true
  check(not workflow.run(dirty.session), 'Unsaved source blocks initial run')
  equal(#dirty.sends, 0, 'Dirty guard prevents provider launch')
  dirty.dirty = false; workflow.run(dirty.session)
  dirty:complete('<kiln_step_complete id="admission"/>')
  dirty.dirty = true; dirty:drain()
  equal(#dirty.sends, 1, 'Dirty source appearing after completion blocks queued next step')
  equal(dirty.session.workflow.phase, 'paused', 'Dirty continuation becomes a visible pause')
  dirty.dirty = false
  local held = workflow.prepare(dirty.session, 'Include totals in the report.')
  equal(dirty.session.workflow.current, 'display', 'Chat handback after a between-step pause targets the first unfinished step')
  equal(dirty.session.workflow.steps.admission.status, 'done', 'A held message does not rerun completed work')
  check(contains(held, 'CURRENT STEP 2/2') and contains(held, 'Include totals in the report.'), 'Held direction accompanies the next unfinished step')

  local closing = fixture(); closing:adopt(); workflow.run(closing.session)
  closing:complete('<kiln_step_complete id="admission"/>'); closing.state.closing = true; closing:drain()
  equal(#closing.sends, 1, 'Closing the app cancels queued progression')
end

local function revisions_and_restore()
  local f = fixture(); f:adopt(); workflow.run(f.session)
  f:complete('<kiln_step_complete id="admission"/>'); f:drain()
  f:adopt(document('Return all pending jobs exactly once.'))
  equal(f.stops, 1, 'Revising an active sequence stops its writer')
  equal(f.session.workflow.steps.admission.status, 'pending', 'Changed implemented step must run again')
  equal(f.session.workflow.steps.display.status, 'pending', 'Later step is invalidated by prerequisite revision')
  check(#f.session.workflow.history >= 3, 'Revision retains completion and superseded-definition history')
  check(contains(f.session.workflow.history[1].record.pinned_definition.instructions, 'Return accepted and deferred jobs.'),
    'History retains the actual previously dispatched definition, not only its fingerprint')
  f:complete('<kiln_step_complete id="display"/>')
  equal(f.session.workflow.steps.display.status, 'pending', 'Late old-revision completion cannot bless revised work')
  workflow.run(f.session)
  equal(f.session.workflow.current, 'admission', 'Resume starts at the earliest invalidated outcome')
  check(contains(f.sends[#f.sends].prompt, 'Return all pending jobs exactly once.'), 'Resumed prompt uses the latest definition')

  local future = fixture(); future:adopt(); workflow.run(future.session)
  future:complete('<kiln_step_complete id="admission"/>')
  future:adopt(document(nil, 'Show counted GO/HOLD rows.'))
  equal(future.session.workflow.steps.admission.status, 'done', 'Editing future work retains unchanged prior completion')
  equal(future.session.workflow.steps.display.status, 'pending', 'Edited future outcome stays pending')
  future:drain(); equal(#future.sends, 1, 'Plan edit cancels queued old-version work')
  workflow.run(future.session)
  workflow.pause(future.session, 'Pause current display.')
  future.session.job = nil
  local three_text = document(nil, 'Show counted GO/HOLD rows.') .. '\n\n## Step export: Export report\nOutcome: Save a report.\nWhy: Operators need a file.\nVerify: Check the saved report.\nDepends: display\nDependency reason: Export the actual display.\n'
  future:adopt(three_text)
  equal(future.session.workflow.current, 'display', 'Editing later work keeps the earliest unfinished step current')
  local correction = workflow.prepare(future.session, 'Continue with my correction.')
  check(contains(correction, 'CURRENT STEP 2/3') and contains(correction, 'display — Display'), 'Ordinary handback cannot skip an unfinished step after a future edit')

  local reordered = fixture(); reordered:adopt()
  local plan = vim.deepcopy(reordered.state.dossier)
  plan.steps = { plan.steps[2], plan.steps[1] }
  reordered.state.dossier = plan
  check(not workflow.run(reordered.session), 'Forward dependency cannot run out of document order')
  check(contains(reordered.session.workflow.reason, 'Place prerequisite admission before display'), 'Invalid order explains the prerequisite')

  local restored = fixture(); restored:adopt(); workflow.run(restored.session)
  restored.session.job = nil
  workflow.init(restored.session, true)
  equal(restored.session.workflow.phase, 'paused', 'Restored running session is paused')
  equal(restored.session.workflow.steps.admission.status, 'paused', 'Restored in-flight step needs explicit continuation')
  check(not restored.session.workflow.auto_run and restored.session.workflow.turn == nil, 'Restoration cannot replay a pending turn')
  workflow.plan(restored.session)
  equal(restored.session.mode, 'plan', 'Replanning uses read-only mode')
  check(not restored.session.workflow.approved, 'Replanning requires a new implementation request')
end

local ok, err = pcall(function() planning(); sequence(); interruption(); stale_and_dirty(); revisions_and_restore() end)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') end
print('Kiln single-chat workflow: ' .. assertions .. ' assertions passed')
vim.cmd('qa!')

-- Mission-control rendering uses observed jobs and per-worktree state only.
local fn = vim.fn
vim.opt.runtimepath:prepend(vim.env.KILN_HOME or fn.getcwd())
local control = require('kiln.control')
local count = 0
local function check(value, message)
  count = count + 1
  assert(value, message)
end
local function has(text, value) return text:find(value, 1, true) ~= nil end
local function content(view) return table.concat(view.lines, '\n') end
local function marked(view, text, group)
  for _, mark in ipairs(view.marks) do
    if mark.group == group and has(view.lines[mark.row], text) then return true end
  end
  return false
end

local function run()
  local a = { provider = 'codex', model = 'default', mode = 'edit', status = 'running', job = 11,
    task = 'Build queue', workspace = { root = '/work/a', branch = 'kiln/task-a', base = '1234567890' },
    changed_files = { { path = 'queue.ex', status = 'M' } },
    file_activity = { ['queue.ex'] = { actor = 'agent', provider = 'codex' } },
    events = { { type = 'file', path = '/work/a/queue.ex' } } }
  local b = { provider = 'claude', model = 'default', mode = 'edit', status = 'running', job = 12,
    task = 'Build dashboard', workspace = { root = '/work/b', branch = 'kiln/task-b', base = 'abcdef012345' },
    changed_files = { { path = 'queue.ex', status = 'M' }, { path = 'board.ex', status = '??' } },
    file_activity = { ['queue.ex'] = { actor = 'human' } },
    human = { saved = true, path = '/work/b/queue.ex' },
    events = { { type = 'file', path = '/work/b/board.ex' } } }
  local reviewer = { provider = 'claude', mode = 'plan', status = 'running', job = 13,
    task = 'Review queue', workspace = a.workspace, events = {}, changed_files = a.changed_files,
    file_activity = a.file_activity }
  local ready = { provider = 'codex', mode = 'edit', status = 'done', task = 'Ready for review',
    workspace = { root = '/work/c', branch = 'kiln/task-c' }, changed_files = {}, events = {} }
  local state = { root = '/project', view_root = '/work/a', sessions = { a, b, reviewer, ready }, selected = 1,
    control_width = 46, overview_width = 110, follow = true }
  local original = vim.deepcopy(state)
  local monitor, board = control.monitor(state), control.overview(state)
  check(vim.deep_equal(state, original), 'Rendering cannot mutate task or ownership state')
  check(has(content(monitor), 'OWNER #1 CODEX'), 'Selected worktree identifies its actual builder')
  check(not has(content(board), 'MULTIPLE') and not has(content(board), 'ATTENTION'), 'Parallel isolated writers are normal')
  check(has(content(board), '2 builders active') and has(content(board), '1 reviewer active'), 'Fleet summary counts actual live jobs')
  check(has(content(board), 'REVIEW QUEUE 1'), 'Review queue counts completed unreviewed tasks')
  check(has(content(monitor), 'TREE kiln/task-a'), 'Sidebar makes the selected branch explicit')
  check(has(content(board), 'base 12345678') and has(content(board), 'base abcdef01'), 'Task cards identify independent baselines')
  check(has(content(board), 'CHANGES 0'), 'An empty current change list does not invent historical changes')
  check(not has(content(board), '/work/a/') and not has(content(board), '/work/b/'), 'File labels are relative to each owning worktree')
  local file_a, file_b = false, false
  for _, row in pairs(board.rows) do
    if row.path == 'queue.ex' and row.session == 1 then file_a = true end
    if row.path == 'queue.ex' and row.session == 2 then file_b = true end
  end
  check(file_a and file_b, 'Same-named files keep distinct task identities in actionable rows')
  check(marked(board, 'queue.ex', 'KilnUser'), 'Human attribution comes from the file worktree')
  check(#monitor.lines == 12, 'Worktree context fits the existing twelve-row sidebar')
  state.selected, state.view_root = 3, '/work/a'
  monitor = control.monitor(state)
  check(has(content(monitor), 'OWNER #1 CODEX'), 'A reviewer points back to its workspace writer')
  state.selected, state.view_root = 2, '/work/b'
  monitor = control.monitor(state)
  check(has(content(monitor), 'OWNER #2 CLAUDE'), 'Selecting another task changes the displayed edit owner')
  check(has(content(monitor), 'YOU SAVED  queue.ex'), 'Human save markers follow selected worktree')
  check(has(content(monitor), 'queue.ex') and has(content(monitor), 'YOU'), 'Sidebar file attribution is workspace-local')
  a.native_job, a.job = 14, nil
  check(control.status(a) == 'NATIVE', 'Native providers count as live owners')
  a.stopping = true
  check(control.status(a) == 'STOPPING', 'Stopping retains ownership until process exit')
  b.workspace = a.workspace
  check(has(content(control.overview(state)), 'Multiple writers share 1 workspace'), 'Same-worktree writer collisions remain visible')
  check(has(content(control.monitor(state)), 'MULTIPLE'), 'Selected unsafe workspace surfaces competing writers')
  a.native_job, a.stopping, b.job = nil, nil, nil
  b.status, b.human_control = 'stopped', true
  check(control.status(b) == 'HANDCODING', 'Taking control is distinct from agent completion')
  check(has(content(control.monitor(state)), 'YOU · agents paused here'), 'Human control owns the selected workspace after agents stop')
  check(has(content(control.overview(state)), 'HANDCODING 1'), 'Fleet counts manually controlled tasks')
  b.human_control = nil
  ready.reviewed = true
  check(control.status(ready) == 'REVIEWED', 'Explicit review remains distinct from integration')
  check(has(content(control.overview(state)), 'REVIEW QUEUE 0'), 'Reviewed work leaves the review queue')
  ready.work_status = 'integrated'
  check(control.status(ready) == 'INTEGRATED', 'A completed merge has its own state')
  check(has(content(control.overview(state)), 'INTEGRATED 1'), 'Fleet summary reports integrated tasks')
  for key, label in pairs({ creating = 'PREPARING', inspecting = 'CHECKING', integrating = 'INTEGRATING', missing = 'MISSING' }) do
    ready.work_status = key
    check(control.status(ready) == label, 'Workspace lifecycle is visible: ' .. key)
  end
  local draft = { provider = 'codex', mode = 'edit', status = 'idle', isolated = true, events = {} }
  state.sessions[#state.sessions + 1], state.selected = draft, #state.sessions + 1
  check(has(content(control.monitor(state)), 'from committed HEAD'), 'Unprovisioned task states its starting point')
  state.control_width, state.overview_width = 24, 40
  draft.task = string.rep('界😀', 15)
  for _, pair in ipairs({ { control.monitor(state), 24 }, { control.overview(state), 40 } }) do
    for _, line in ipairs(pair[1].lines) do
      check(fn.strdisplaywidth(line) <= pair[2], 'Unicode labels fit constrained views')
    end
  end
end

local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') end
print('Kiln fleet views: ' .. count .. ' assertions passed')
vim.cmd('qa!')

-- Inline live changes use real Git baselines without taking room from the code.
vim.opt.runtimepath:prepend(vim.env.KILN_HOME or vim.fn.getcwd())
vim.o.swapfile, vim.o.backup, vim.o.writebackup, vim.o.modeline = false, false, false, false
local api, fn = vim.api, vim.fn
local changes = require('kiln.changes').new()
local root = fn.tempname() .. '-kiln-live'
local assertions, updates, errors = 0, 0, {}
local original_system = vim.system
local function check(value, message) assertions = assertions + 1; assert(value, message) end
local function equal(actual, expected, message)
  check(vim.deep_equal(actual, expected), message .. '\nactual: ' .. vim.inspect(actual) .. '\nexpected: ' .. vim.inspect(expected))
end
local function wait_for(predicate, message) check(vim.wait(4000, predicate, 20), message) end
local function write(path, lines) fn.writefile(lines, root .. '/' .. path) end
local function git(...)
  local command = { 'git', '-C', root }; vim.list_extend(command, { ... })
  local result = original_system(command, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end
local function marks(buf)
  local result = {}
  for name, namespace in pairs(api.nvim_get_namespaces()) do
    if name:match('^KilnLive') then
      vim.list_extend(result, api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true }))
    end
  end
  table.sort(result, function(a, b) return a[2] < b[2] end)
  return result
end
local function scan()
  local before = updates
  changes.scan()
  wait_for(function() return updates > before end, 'Actual Git changes scan completes')
end
local function setup(base)
  changes.setup({ root = root, base = base, interval = 100000,
    on_update = function() updates = updates + 1 end,
    on_error = function(message) errors[#errors + 1] = message end })
  local before = updates
  wait_for(function() return updates > before end, 'Initial real repository scan completes')
end
local held, killed = {}, 0
local function hold_baseline()
  vim.system = function(command, options, callback)
    if command[1] == 'git' and command[4] == 'show' and callback then
      -- Run real Git now, delay only delivery to exercise the asynchronous race.
      local result = original_system(command, options):wait()
      held[#held + 1] = function() callback(result) end
      return { kill = function() killed = killed + 1 end }
    end
    return original_system(command, options, callback)
  end
end
local function deliver()
  local queued = held; held = {}; vim.system = original_system
  for _, callback in ipairs(queued) do callback() end
  local completed = false
  vim.schedule(function() completed = true end)
  wait_for(function() return completed end, 'Delayed actual Git callback is delivered')
end
local function test()
  fn.mkdir(root, 'p')
  root = (vim.uv or vim.loop).fs_realpath(root) or root
  git('init'); git('config', 'user.name', 'WarrenBuffering'); git('config', 'user.email', 'WarrenBuffering@users.noreply.github.com')
  write('scheduler.ex', { 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight' })
  write('old name.ex', { 'first', 'second', 'third', 'fourth' })
  write('removal.ex', { 'a', 'b', 'c', 'd' })
  write('deleted.ex', { 'deleted content' })
  local evolving = {}
  for index = 1, 18 do evolving[index] = 'line ' .. index end
  write('evolving.ex', evolving)
  git('add', '.'); git('commit', '-m', 'Start live view fixture')
  local baseline = git('rev-parse', 'HEAD')
  write('scheduler.ex', { 'one', 'changed', 'three', 'four', 'five', 'six', 'seven', 'eight', 'added' })
  write('new test.exs', { 'new test one', 'new test two' })
  write('removal.ex', { 'a', 'c', 'd' })
  evolving[2] = 'first change'
  write('evolving.ex', evolving)
  git('mv', 'old name.ex', 'new name.ex')
  write('new name.ex', { 'first', 'changed second', 'third', 'fourth' })
  fn.delete(root .. '/deleted.ex')
  for _, group in ipairs({ 'KilnEditAdd', 'KilnEditChange', 'KilnEditDelete' }) do api.nvim_set_hl(0, group, { bg = '#203020' }) end
  vim.o.columns, vim.o.lines = 160, 50
  local code = api.nvim_get_current_win()
  vim.cmd('edit ' .. fn.fnameescape(root .. '/scheduler.ex'))
  vim.wo[code].winbar = 'Original code label'
  vim.cmd('botright vsplit')
  local side = api.nvim_get_current_win()
  api.nvim_win_set_buf(side, api.nvim_create_buf(false, true))
  api.nvim_win_set_width(side, 39); vim.wo[side].winfixwidth = true
  local width, code_width = api.nvim_win_get_width(side), api.nvim_win_get_width(code)
  setup()
  local function live(path)
    check(changes.show_live(path, code), 'Live view starts for ' .. path)
    wait_for(changes.is_live_open, 'Actual Git inline view is ready for ' .. path)
    return api.nvim_win_get_buf(code)
  end
  local buf = live('scheduler.ex')
  equal(#api.nvim_list_wins(), 2, 'Live changes do not create another window')
  equal(api.nvim_win_get_width(code), code_width, 'Live code keeps its full width')
  equal(api.nvim_win_get_width(side), width, 'Dossier sidebar width is preserved')
  equal(api.nvim_get_current_win(), side, 'Asynchronous source following never takes keyboard focus')
  check(not vim.wo[code].diff, 'Live source is not a native split-diff buffer')
  equal(api.nvim_buf_get_name(buf), root .. '/scheduler.ex', 'The code pane contains the actual editable source file')
  check(vim.bo[buf].modifiable, 'Actual code remains editable')
  local edit_marks = marks(buf)
  equal(#edit_marks, 2, 'Only the modified and added lines receive inline marks')
  equal({ edit_marks[1][2], edit_marks[1][4].line_hl_group }, { 1, 'KilnEditChange' }, 'Changed line maps to the actual hunk')
  equal({ edit_marks[2][2], edit_marks[2][4].line_hl_group }, { 8, 'KilnEditAdd' }, 'Added line maps to the actual hunk')
  equal(api.nvim_win_get_cursor(code)[1], 2, 'The source pane reveals the first real hunk')
  changes.close_diff()
  equal(#marks(buf), 0, 'Taking control clears all inline attribution')
  equal(vim.wo[code].winbar, 'Original code label', 'Closing live view restores the code label')
  check(not changes.is_live_open(), 'Closed live view is no longer active')
  buf = live('new test.exs')
  equal(#marks(buf), 2, 'Every line in an actual new file is highlighted')
  for _, mark in ipairs(marks(buf)) do equal(mark[4].line_hl_group, 'KilnEditAdd', 'New file uses an empty Git baseline') end
  buf = live('new name.ex')
  equal(#marks(buf), 1, 'Rename loads the original path baseline rather than coloring the entire file')
  equal(marks(buf)[1][2], 1, 'Only the edited renamed line is marked')
  buf = live('removal.ex')
  equal(#marks(buf), 1, 'Removed lines have an inline location marker')
  equal(marks(buf)[1][4].line_hl_group, 'KilnEditDelete', 'Deletion has a distinct visual mark')
  check(marks(buf)[1][4].virt_text[1][1]:find('1 line', 1, true), 'Deletion count comes from the actual hunk')
  check(changes.show_live('deleted.ex', code), 'A deleted source opens the existing review fallback')
  wait_for(changes.is_diff_open, 'Deleted file uses the explicit baseline review')
  check(not changes.is_live_open(), 'Deleted file never pretends to be editable source')
  changes.close_diff()

  -- A later edit is distinguished from the existing Git diff, including a
  -- reversion. Refreshing the same snapshot keeps its newest emphasis stable.
  buf = live('evolving.ex')
  equal(marks(buf)[1][4].line_hl_group, 'KilnEditChange', 'First observed change is emphasized')
  evolving[12] = 'second change'
  write('evolving.ex', evolving)
  buf = live('evolving.ex')
  equal(#marks(buf), 2, 'Both actual baseline changes remain visible')
  equal(marks(buf)[1][4].line_hl_group, 'KilnEditChangeQuiet', 'Earlier edit becomes quieter')
  equal(marks(buf)[2][4].line_hl_group, 'KilnEditChange', 'Latest observed edit is emphasized')
  equal(api.nvim_win_get_cursor(code)[1], 12, 'Following reveals the latest edit rather than the first baseline hunk')
  buf = live('evolving.ex')
  equal(marks(buf)[1][4].line_hl_group, 'KilnEditChangeQuiet', 'Unchanged refresh preserves earlier edit tone')
  equal(marks(buf)[2][4].line_hl_group, 'KilnEditChange', 'Unchanged refresh preserves latest emphasis')
  check(changes.next_hunk(1, code), 'Next change navigates real hunks')
  equal(api.nvim_win_get_cursor(code)[1], 2, 'Next change wraps to first hunk')
  check(changes.next_hunk(-1, code), 'Previous change navigates real hunks')
  equal(api.nvim_win_get_cursor(code)[1], 12, 'Previous change wraps to final hunk')
  equal(api.nvim_get_current_win(), side, 'Hunk navigation never changes keyboard focus')
  api.nvim_win_set_cursor(code, { 5, 0 })
  evolving[16] = 'third change'
  write('evolving.ex', evolving)
  buf = live('evolving.ex')
  equal(api.nvim_win_get_cursor(code)[1], 5, 'Inspection freezes the cursor through same-file refresh')
  check(not changes.show_live('scheduler.ex', code), 'Inspection prevents a different file replacing the view')
  equal(api.nvim_buf_get_name(api.nvim_win_get_buf(code)), root .. '/evolving.ex', 'Inspected file remains visible')
  changes.set_follow(true)
  evolving[16] = 'line 16'
  write('evolving.ex', evolving)
  buf = live('evolving.ex')
  equal(#marks(buf), 3, 'Reverted latest edit remains visible beside older outstanding changes')
  equal({ marks(buf)[3][2], marks(buf)[3][4].line_hl_group }, { 15, 'KilnEditChange' },
    'Latest reversion is highlighted even though absent from the Git diff')
  equal(api.nvim_win_get_cursor(code)[1], 16, 'Resuming follow reveals the latest reversion')
  buf = live('removal.ex')
  api.nvim_win_set_cursor(code, { 3, 0 })
  check(changes.next_hunk(1, code), 'Removal anchor is navigable')
  equal(api.nvim_win_get_cursor(code)[1], 2, 'Deleted line navigation lands at its surviving anchor')
  changes.set_follow(true)
  changes.close_diff()

  -- Committed agent work remains visible against the worktree's pinned base.
  git('add', '-A'); git('commit', '-m', 'Record fixture implementation')
  changes.stop(); setup(baseline)
  buf = live('scheduler.ex')
  equal(#marks(buf), 2, 'Committed changes remain marked against the original task baseline')
  buf = live('new test.exs')
  equal(#marks(buf), 2, 'Committed additions still use an empty original baseline')
  buf = live('new name.ex')
  equal(#marks(buf), 1, 'Committed rename still compares with its original baseline path')
  check(changes.show_diff('scheduler.ex', code), 'Explicit review remains available after inline viewing')
  wait_for(changes.is_diff_open, 'Explicit review opens its existing side-by-side layout')
  equal(#marks(buf), 0, 'Explicit review clears previous inline marks')
  equal(#api.nvim_list_wins(), 3, 'Only explicit review adds a baseline pane')
  changes.close_diff()

  buf = live('scheduler.ex')
  api.nvim_buf_set_lines(buf, 1, 2, false, { 'unsaved human correction' })
  api.nvim_exec_autocmds('TextChanged', { buffer = buf })
  equal(#marks(buf), 0, 'Human edits clear stale agent decorations immediately')
  check(not changes.show_live('new test.exs', code), 'Live following cannot replace a dirty current buffer')
  equal(api.nvim_buf_get_lines(buf, 1, 2, false)[1], 'unsaved human correction', 'Unsaved human code is preserved')
  api.nvim_buf_call(buf, function() vim.cmd('edit!') end)
  local hidden = fn.bufadd(root .. '/new test.exs'); fn.bufload(hidden)
  api.nvim_buf_set_lines(hidden, 0, 1, false, { 'hidden unsaved code' })
  check(not changes.show_live('new test.exs', code), 'Live following cannot replace a dirty hidden target')
  equal(api.nvim_buf_get_lines(hidden, 0, 1, false)[1], 'hidden unsaved code', 'Hidden unsaved target is preserved')
  api.nvim_buf_call(hidden, function() vim.cmd('edit!') end)
  check(not changes.show_live('../outside.ex', code), 'Live view cannot escape the project root')

  hold_baseline()
  check(changes.show_live('scheduler.ex', code), 'Delayed request starts before inspection')
  api.nvim_win_set_cursor(code, { 6, 0 })
  changes.set_follow(false)
  deliver()
  check(changes.is_live_open(), 'Inspection may still receive accurate inline marks')
  equal(api.nvim_win_get_cursor(code)[1], 6, 'A pending Git response cannot move the cursor after follow is frozen')
  changes.set_follow(true)
  changes.close_diff()

  hold_baseline()
  check(changes.show_live('scheduler.ex', code), 'Delayed request starts before cursor navigation')
  api.nvim_win_set_cursor(code, { 7, 0 })
  deliver()
  equal(api.nvim_win_get_cursor(code)[1], 7, 'Cursor movement during a pending Git read is preserved even before a follow toggle')
  changes.close_diff()

  hold_baseline()
  check(changes.show_live('scheduler.ex', code), 'Delayed inline request starts')
  changes.close_diff()
  deliver()
  check(not changes.is_live_open() and #marks(buf) == 0, 'A canceled baseline response cannot repaint after hand takeover')
  check(killed > 0, 'Closing requests cancellation of the in-flight Git read')

  hold_baseline()
  check(changes.show_live('scheduler.ex', code), 'Request before a human save starts')
  api.nvim_buf_set_lines(buf, 1, 2, false, { 'saved human correction' })
  api.nvim_buf_call(buf, function() vim.cmd('write') end)
  deliver()
  check(not changes.is_live_open() and #marks(buf) == 0, 'Changedtick rejects stale paint even after a human edit is saved clean')
  equal(api.nvim_buf_get_lines(buf, 1, 2, false)[1], 'saved human correction', 'Saved human correction survives the late Git callback')
  buf = live('scheduler.ex')
  for _, mark in ipairs(marks(buf)) do
    check(mark[4].line_hl_group:find('Quiet', 1, true), 'Saved human handoff is not presented as a fresh agent edit')
  end
  write('scheduler.ex', { 'one', 'saved human correction', 'three', 'four', 'five', 'new agent edit', 'seven', 'eight', 'added' })
  buf = live('scheduler.ex')
  equal({ marks(buf)[1][2], marks(buf)[1][4].line_hl_group }, { 1, 'KilnEditChangeQuiet' }, 'Human handoff remains quiet after an agent edit')
  equal({ marks(buf)[2][2], marks(buf)[2][4].line_hl_group }, { 5, 'KilnEditChange' }, 'Only the resumed agent delta receives latest emphasis')

  hold_baseline()
  check(changes.show_live('scheduler.ex', code), 'Request before a visible file switch starts')
  api.nvim_win_set_buf(code, hidden)
  deliver()
  check(not changes.is_live_open() and #marks(hidden) == 0, 'A late response cannot decorate the wrong visible file')

  hold_baseline()
  check(changes.show_live('scheduler.ex', code), 'Request before another external write starts')
  write('scheduler.ex', { 'newer external version' })
  deliver()
  check(not changes.is_live_open() and #marks(buf) == 0, 'Disk signature rejects a response for stale file contents')
  scan()
  buf = live('scheduler.ex')
  equal(api.nvim_buf_get_lines(buf, 0, 1, false)[1], 'newer external version', 'A fresh request follows the latest real disk version')
  changes.close_diff()

  hold_baseline()
  check(changes.show_live('scheduler.ex', code), 'Final pending request starts')
  changes.stop()
  deliver()
  check(not changes.is_live_open() and #marks(buf) == 0, 'Stopping the context cancels late callbacks and decorations')
  equal(api.nvim_get_current_win(), side, 'All following, review, and race checks preserve sidebar focus')
end
local ok, err = xpcall(test, debug.traceback)
vim.system = original_system
changes.stop()
fn.delete(root, 'rf')
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') end
print('Kiln live code: ' .. assertions .. ' assertions passed')
vim.cmd('qa!')

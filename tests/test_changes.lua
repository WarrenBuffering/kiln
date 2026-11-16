vim.opt.runtimepath:prepend(vim.env.KILN_HOME or vim.fn.getcwd())
vim.o.swapfile, vim.o.backup, vim.o.writebackup, vim.o.modeline = false, false, false, false
local changes = require('kiln.changes')
local root = vim.fn.tempname() .. '-kiln-changes'
local assertions = 0
local instances, temporary_roots = {}, {}
local function check(value, message)
  assertions = assertions + 1
  assert(value, message)
end
local function write(path, lines)
  vim.fn.writefile(lines, root .. '/' .. path)
end
local function git(...)
  local cmd = { 'git', '-C', root }
  vim.list_extend(cmd, { ... })
  local result = vim.system(cmd, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return result.stdout
end
local function wait_for(fn, message)
  check(vim.wait(4000, fn, 20), message)
end
local function test()
  vim.fn.mkdir(root, 'p')
  git('init')
  git('config', 'user.name', 'WarrenBuffering')
  git('config', 'user.email', 'WarrenBuffering@users.noreply.github.com')
  write('base.txt', { 'one', 'two', 'three' })
  write('old name.txt', { 'rename me' })
  write('gone.txt', { 'remove me' })
  write('binary.bin', { 'binary' })
  git('add', '.')
  git('commit', '-m', 'Test fixture')
  write('base.txt', { 'one', 'modified', 'three' })
  vim.fn.delete(root .. '/gone.txt')
  assert((vim.uv or vim.loop).fs_rename(root .. '/old name.txt', root .. '/new name.txt'))
  git('add', '-A', '--', 'old name.txt', 'new name.txt')
  write('staged.txt', { 'new staged content' })
  git('add', '--', 'staged.txt')
  write('-new file.txt', { 'new untracked content' })
  write('line\nbreak.txt', { 'newline filename' })
  local updates, conflicts, errors = 0, {}, {}
  vim.o.columns, vim.o.lines = 160, 50
  local code_win = vim.api.nvim_get_current_win()
  vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/base.txt'))
  local base_buf = vim.api.nvim_get_current_buf()
  vim.cmd('botright vsplit')
  local side_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(side_win, vim.api.nvim_create_buf(false, true))
  vim.api.nvim_win_set_width(side_win, 39)
  vim.wo[side_win].winfixwidth = true
  changes.setup({ root = root, interval = 10000,
    on_update = function() updates = updates + 1 end,
    on_conflict = function(path) table.insert(conflicts, path) end,
    on_error = function(message) table.insert(errors, message) end,
  })
  wait_for(function() return updates > 0 end, 'Initial Git scan completes')
  local by_path = {}
  for _, entry in ipairs(changes.list()) do by_path[entry.path] = entry end
  check(by_path['base.txt'].status == ' M', 'Unstaged modification parsed')
  check(by_path['gone.txt'].status == ' D', 'Deletion parsed')
  check(by_path['staged.txt'].status == 'A ', 'Staged addition parsed')
  check(by_path['-new file.txt'].status == '??', 'Leading dash and spaces preserved')
  check(by_path['line\nbreak.txt'].status == '??', 'Newline filenames preserved')
  check(by_path['new name.txt'].old_path == 'old name.txt', 'Rename old and new paths preserved')
  local snapshot = changes.list()
  snapshot[1].path = 'mutated'
  check(changes.list()[1].path ~= 'mutated', 'Caller cannot mutate internal list')

  write('base.txt', { 'one', 'external change with different size', 'three' })
  changes.scan()
  wait_for(function() return vim.api.nvim_buf_get_lines(base_buf, 1, 2, false)[1] == 'external change with different size' end,
    'Clean displayed buffer reloads external edit')
  vim.api.nvim_buf_set_lines(base_buf, 1, 2, false, { 'unsaved user work' })
  write('base.txt', { 'disk work must not replace unsaved editor text' })
  changes.scan()
  check(vim.api.nvim_buf_get_lines(base_buf, 1, 2, false)[1] == 'unsaved user work', 'Dirty buffer is preserved')
  check(#conflicts == 1, 'Conflict callback reports dirty file')
  changes.scan()
  check(#conflicts == 1, 'Unchanged conflict is not repeatedly reported')
  check(not changes.follow('staged.txt', code_win), 'Follow refuses to replace unsaved code buffer')
  check(not changes.show_diff('base.txt', code_win), 'Diff refuses unsaved buffer')
  vim.api.nvim_buf_call(base_buf, function() vim.cmd('edit!') end)

  local width = vim.api.nvim_win_get_width(side_win)
  vim.wo[code_win].winbar = 'Original editor label'
  check(changes.show_diff('base.txt', code_win), 'Tracked diff starts')
  wait_for(changes.is_diff_open, 'Tracked diff opens')
  check(vim.api.nvim_get_current_win() == side_win, 'Diff does not steal focus')
  check(vim.api.nvim_win_get_width(side_win) == width, 'Diff preserves agent sidebar width')
  check(vim.wo[code_win].diff, 'Working file uses native diff mode')
  check(vim.wo[code_win].winbar:find('WORKTREE', 1, true), 'Working diff is labeled WORKTREE')
  local has_head_label = false
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= code_win and win ~= side_win then has_head_label = vim.wo[win].winbar:find('HEAD', 1, true) ~= nil end
  end
  check(has_head_label, 'Baseline diff is labeled HEAD')
  changes.close_diff()
  check(not vim.wo[code_win].diff, 'Closing diff restores window options')
  check(vim.wo[code_win].winbar == 'Original editor label', 'Closing diff restores original editor label')
  check(#vim.api.nvim_list_wins() == 2, 'Closing diff removes only baseline split')

  -- Existing hidden buffers must not hide changes that happened off screen.
  check(changes.follow('staged.txt', code_win), 'Hide base file before external update')
  write('base.txt', { 'fresh disk content while buffer was hidden' })
  check(changes.follow('base.txt', code_win), 'Follow reloads an existing hidden buffer')
  check(vim.api.nvim_buf_get_lines(base_buf, 0, 1, false)[1] == 'fresh disk content while buffer was hidden',
    'Follow displays latest hidden-buffer disk contents')
  check(changes.follow('staged.txt', code_win), 'Hide base file again')
  write('base.txt', { 'fresh content before opening a diff from code window' })
  vim.api.nvim_set_current_win(code_win)
  check(changes.show_diff('base.txt', code_win), 'Open diff while code window owns focus')
  wait_for(changes.is_diff_open, 'Hidden-buffer diff opens')
  check(vim.api.nvim_get_current_win() == code_win, 'Diff preserves focus even when code window was current')
  check(vim.api.nvim_buf_get_lines(base_buf, 0, 1, false)[1] == 'fresh content before opening a diff from code window',
    'Diff reloads latest disk contents for existing hidden buffer')
  write('base.txt', { 'live external update in the open diff' })
  changes.scan()
  check(vim.api.nvim_buf_get_lines(base_buf, 0, 1, false)[1] == 'live external update in the open diff',
    'Open native diff reloads external edits live')
  changes.close_diff()
  vim.api.nvim_set_current_win(side_win)

  check(changes.show_diff('new name.txt', code_win), 'Rename diff starts')
  wait_for(changes.is_diff_open, 'Rename diff opens')
  local baseline
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= code_win and win ~= side_win then baseline = vim.api.nvim_win_get_buf(win) end
  end
  check(vim.api.nvim_buf_get_lines(baseline, 0, 1, false)[1] == 'rename me', 'Rename baseline uses original HEAD path')
  changes.close_diff()
  check(changes.show_diff('staged.txt', code_win), 'Staged new file diff starts')
  wait_for(changes.is_diff_open, 'Staged new file diff opens against empty HEAD')
  changes.close_diff()
  check(changes.show_diff('-new file.txt', code_win), 'Untracked diff starts')
  wait_for(changes.is_diff_open, 'Untracked diff opens')
  changes.close_diff()
  check(changes.show_diff('gone.txt', code_win), 'Deleted diff starts')
  wait_for(changes.is_diff_open, 'Deleted diff opens')
  check(vim.bo[vim.api.nvim_win_get_buf(code_win)].buftype == 'nofile', 'Deleted file uses read-only scratch')
  check(not vim.bo[vim.api.nvim_win_get_buf(code_win)].modifiable, 'Deleted diff cannot create deleted file accidentally')
  changes.close_diff()
  check(vim.fn.filereadable(root .. '/gone.txt') == 0, 'Deleted file remains deleted')
  check(not changes.follow('../outside.txt', code_win), 'Traversal out of project is rejected')
  local fd = assert(io.open(root .. '/binary.bin', 'wb'))
  fd:write('a\0b'); fd:close()
  check(not changes.show_diff('binary.bin', code_win), 'Binary files are not rendered as text')
  check(changes.follow('staged.txt', code_win, 400), 'Follow opens file and clamps line')
  check(vim.api.nvim_win_get_cursor(code_win)[1] == 1, 'Requested line clamps to buffer bounds')
  check(vim.api.nvim_get_current_win() == side_win, 'Follow does not steal focus')

  changes.stop()
  vim.fn.mkdir(root .. '/sub', 'p')
  write('sub/inside.txt', { 'inside' })
  updates = 0
  changes.setup({ root = root .. '/sub', interval = 10000, on_update = function() updates = updates + 1 end })
  wait_for(function() return updates > 0 end, 'Subdirectory scan completes')
  local nested = changes.list()
  check(#nested == 1 and nested[1].path == 'inside.txt', 'Project subdirectory paths are relative and scoped')
  changes.stop()
  local nongit = vim.fn.tempname() .. '-kiln-no-git'
  vim.fn.mkdir(nongit, 'p')
  changes.setup({ root = nongit })
  check(#changes.list() == 0, 'Non-Git project has empty changes without errors')
  check(not changes.show_diff('file.txt', code_win), 'Non-Git diff fails gracefully')
  changes.stop()
  vim.fn.delete(nongit, 'rf')

  -- Concurrent tasks review their own fixed baseline, including commits an
  -- agent made before the human selected the task.
  vim.cmd('only')
  local task_a, task_b = root .. '-task a', root .. '-task b'
  temporary_roots = { task_a, task_b }
  local base = vim.trim(git('rev-parse', 'HEAD'))
  git('worktree', 'add', '-b', 'kiln/task-a', task_a, 'HEAD')
  git('worktree', 'add', '-b', 'kiln/task-b', task_b, 'HEAD')
  local function task_git(path, ...)
    local cmd = { 'git', '-C', path }
    vim.list_extend(cmd, { ... })
    local result = vim.system(cmd, { text = true }):wait()
    assert(result.code == 0, result.stderr)
    return result.stdout
  end
  vim.fn.writefile({ 'task A committed', 'two', 'three' }, task_a .. '/base.txt')
  task_git(task_a, 'mv', 'old name.txt', 'renamed by A.txt')
  task_git(task_a, 'rm', 'gone.txt')
  vim.fn.writefile({ 'new committed file' }, task_a .. '/added by A.txt')
  task_git(task_a, 'add', '-A')
  task_git(task_a, 'commit', '-m', 'Task A fixture')
  vim.fn.writefile({ 'task A current', 'two', 'three' }, task_a .. '/base.txt')
  vim.fn.writefile({ 'task A untracked' }, task_a .. '/-untracked.txt')
  vim.fn.writefile({ 'task B committed', 'two', 'three' }, task_b .. '/base.txt')
  task_git(task_b, 'add', '-A')
  task_git(task_b, 'commit', '-m', 'Task B fixture')
  local a, b = changes.new(), changes.new()
  instances = { a, b }
  local a_updates, b_updates, a_conflicts, task_errors = 0, 0, 0, {}
  a.setup({ root = task_a, base = base, interval = 10000,
    on_update = function() a_updates = a_updates + 1 end,
    on_conflict = function() a_conflicts = a_conflicts + 1 end,
    on_error = function(message) task_errors[#task_errors + 1] = message end })
  b.setup({ root = task_b, base = base, interval = 10000,
    on_update = function() b_updates = b_updates + 1 end,
    on_error = function(message) task_errors[#task_errors + 1] = message end })
  wait_for(function() return a_updates > 0 and b_updates > 0 end, 'Independent task scans complete')
  local a_files, b_files = {}, {}
  for _, entry in ipairs(a.list()) do a_files[entry.path] = entry end
  for _, entry in ipairs(b.list()) do b_files[entry.path] = entry end
  check(a_files['base.txt'] ~= nil and b_files['base.txt'] ~= nil, 'Both tasks retain same-name changes from their own roots')
  check(a_files['added by A.txt'].base_absent == true, 'Committed addition remains new against task baseline')
  check(a_files['renamed by A.txt'].old_path == 'old name.txt', 'Committed rename retains original baseline path')
  check(a_files['gone.txt'].status:find('D') ~= nil, 'Committed deletion remains reviewable')
  check(a_files['-untracked.txt'].status == '??', 'Fixed baseline includes current untracked files')
  check(b_files['added by A.txt'] == nil and #b.list() == 1, 'Task changes never leak between worktrees')

  local a_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(a_win, vim.api.nvim_create_buf(true, false))
  vim.cmd('vsplit')
  local b_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(b_win, vim.api.nvim_create_buf(true, false))
  vim.cmd('botright vsplit')
  local focus_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(focus_win, vim.api.nvim_create_buf(false, true))
  check(a.show_diff('base.txt', a_win) and b.show_diff('base.txt', b_win), 'Two independent task diffs start')
  wait_for(function() return a.is_diff_open() and b.is_diff_open() end, 'Independent task diffs open together')
  local a_buf, b_buf = vim.api.nvim_win_get_buf(a_win), vim.api.nvim_win_get_buf(b_win)
  check(a_buf ~= b_buf, 'Same filename in different worktrees uses distinct editor buffers')
  check(vim.api.nvim_buf_get_lines(a_buf, 0, 1, false)[1] == 'task A current', 'Task A shows its current code')
  check(vim.api.nvim_buf_get_lines(b_buf, 0, 1, false)[1] == 'task B committed', 'Task B shows its own committed code')
  local baseline_count = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.wo[win].winbar:find('BASE', 1, true) then
      baseline_count = baseline_count + 1
      check(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, 1, false)[1] == 'one',
        'Task diff uses original base, not agent commit HEAD')
    end
  end
  check(baseline_count == 2, 'Both fixed baselines have explicit BASE labels')
  check(vim.api.nvim_get_current_win() == focus_win, 'Concurrent diff updates preserve focus')
  check(not a.show_diff('base.txt', b_win), 'Another task cannot take over an owned diff window')
  check(b.is_diff_open(), 'Rejected takeover preserves the existing task diff')
  a.close_diff()
  check(b.is_diff_open() and vim.wo[b_win].diff, 'Closing one instance leaves the other diff intact')
  check(a.show_diff('renamed by A.txt', a_win), 'Fixed-base rename diff starts')
  wait_for(a.is_diff_open, 'Fixed-base rename diff opens')
  local found_rename = false
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.wo[win].winbar:find('renamed by A.txt', 1, true) and vim.wo[win].winbar:find('BASE', 1, true) then
      found_rename = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, 1, false)[1] == 'rename me'
    end
  end
  check(found_rename, 'Committed rename reads original baseline contents')
  a.close_diff()
  check(a.show_diff('added by A.txt', a_win), 'Committed new-file diff starts')
  wait_for(a.is_diff_open, 'Committed new-file diff uses empty baseline')
  a.close_diff()
  check(a.show_diff('gone.txt', a_win), 'Committed deletion diff starts')
  wait_for(a.is_diff_open, 'Committed deletion diff opens')
  a.close_diff()

  -- A slow Git response from the previous task must not reopen its view after
  -- the user has switched tasks. close_diff cancels pending opens too.
  check(a.show_diff('base.txt', a_win), 'Pending diff starts before switch')
  a.close_diff()
  vim.wait(150, function() return false end, 10)
  check(not a.is_diff_open(), 'Canceled asynchronous task diff does not reopen')
  check(b.is_diff_open(), 'Canceling task A does not cancel task B')
  check(a.follow('base.txt', a_win), 'Task A can return to its file')
  vim.api.nvim_buf_set_lines(a_buf, 0, 1, false, { 'human unsaved A' })
  vim.api.nvim_win_set_buf(a_win, vim.api.nvim_create_buf(true, false))
  vim.fn.writefile({ 'agent writes A while hidden' }, task_a .. '/base.txt')
  a.scan()
  check(vim.api.nvim_buf_get_lines(a_buf, 0, 1, false)[1] == 'human unsaved A', 'Hidden human edits survive background task writes')
  check(a_conflicts == 1, 'Hidden-buffer conflict is attributed to its task')
  check(not a.follow('base.txt', a_win), 'Task follow cannot replace hidden unsaved changes')
  vim.bo[a_buf].modified = false
  a.stop()
  check(b.is_diff_open(), 'Stopping one watcher leaves another task live')
  local previous = b_updates
  b.scan()
  wait_for(function() return b_updates > previous end, 'Remaining task still receives updates')
  check(#task_errors == 2 and task_errors[1]:find('other task diff', 1, true)
      and task_errors[2]:find('unsaved', 1, true), 'Only expected ownership and dirty-buffer guards are reported')
  b.stop()
  local groups = vim.api.nvim_get_autocmds({ event = 'BufWritePost' })
  local leaked = false
  for _, autocmd in ipairs(groups) do
    if autocmd.group_name and autocmd.group_name:match('^KilnChanges') then leaked = true end
  end
  check(not leaked, 'All stopped watchers remove their independent autocommand groups')

  local invalid_updates = 0
  a.setup({ root = task_a, base = '--invalid', interval = 10000,
    on_update = function() invalid_updates = invalid_updates + 1 end,
    on_error = function() end })
  check(not a.show_diff('base.txt', a_win), 'Invalid task baseline refuses misleading HEAD fallback')
  vim.wait(100, function() return false end, 10)
  check(invalid_updates == 0, 'Invalid baseline never publishes unrelated changes')
  a.stop()

  -- A state directory may live inside the main checkout. The longest-root
  -- owner must be the only watcher that reloads or reports its loaded buffers.
  local nested_root = root .. '/nested-task'
  vim.fn.mkdir(nested_root, 'p')
  nested_root = (vim.uv or vim.loop).fs_realpath(nested_root)
  vim.fn.writefile({ 'original nested content' }, nested_root .. '/owned.ex')
  local nested_buf = vim.fn.bufadd(nested_root .. '/owned.ex')
  vim.fn.bufload(nested_buf)
  local outer_conflicts, inner_conflicts = 0, 0
  a.setup({ root = root, interval = 10000,
    owns_path = function(path) return path:sub(1, #nested_root + 1) ~= nested_root .. '/' end,
    on_conflict = function() outer_conflicts = outer_conflicts + 1 end })
  b.setup({ root = nested_root, interval = 10000,
    on_conflict = function() inner_conflicts = inner_conflicts + 1 end })
  vim.api.nvim_buf_set_lines(nested_buf, 0, -1, false, { 'unsaved nested human edit' })
  vim.fn.writefile({ 'external nested write' }, nested_root .. '/owned.ex')
  a.scan(); b.scan()
  check(outer_conflicts == 0 and inner_conflicts == 1, 'Nested dirty-buffer conflict belongs only to the longest-root watcher')
  check(vim.api.nvim_buf_get_lines(nested_buf, 0, 1, false)[1] == 'unsaved nested human edit',
    'Parent watcher cannot replace nested task human edits')
  vim.bo[nested_buf].modified = false
  a.stop(); b.stop()
end
local ok, err = xpcall(test, debug.traceback)
changes.stop()
for _, instance in ipairs(instances) do instance.stop() end
for _, path in ipairs(temporary_roots) do vim.fn.delete(path, 'rf') end
vim.fn.delete(root, 'rf')
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd('cquit 1')
else
  print(('Kiln changes: %d assertions passed'):format(assertions))
  vim.cmd('qa!')
end

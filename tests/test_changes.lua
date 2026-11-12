vim.opt.runtimepath:prepend(vim.env.KILN_HOME or vim.fn.getcwd())
vim.o.swapfile, vim.o.backup, vim.o.writebackup, vim.o.modeline = false, false, false, false
local changes = require('kiln.changes')
local root = vim.fn.tempname() .. '-kiln-changes'
local assertions = 0
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
end
local ok, err = xpcall(test, debug.traceback)
changes.stop()
vim.fn.delete(root, 'rf')
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd('cquit 1')
else
  print(('Kiln changes: %d assertions passed'):format(assertions))
  vim.cmd('qa!')
end

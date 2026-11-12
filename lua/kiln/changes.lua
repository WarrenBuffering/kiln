-- Live working-tree visibility. All Git commands use argv, never a shell.
local M = {}
local uv = vim.uv or vim.loop
local state = { changes = {}, watched = {}, conflicts = {}, generation = 0 }
local diff_options = { 'diff', 'scrollbind', 'cursorbind', 'foldmethod', 'foldcolumn', 'foldenable', 'wrap', 'winbar' }
local max_diff_bytes = 2 * 1024 * 1024

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function report(message)
  if state.on_error then state.on_error(message) end
end

local function normalize(path)
  return vim.fs.normalize(path):gsub('/+$', '')
end

local function canonical(path)
  local parent = vim.fs.dirname(path)
  local resolved = parent and uv.fs_realpath(parent)
  return normalize(resolved and (resolved .. '/' .. vim.fs.basename(path)) or path)
end

local function inside(path, root)
  return path == root or path:sub(1, #root + 1) == root .. '/'
end

local function relative(path)
  if type(path) ~= 'string' or path == '' or path:find('%z') then return nil end
  local absolute = canonical(path:sub(1, 1) == '/' and path or state.root .. '/' .. path)
  if not inside(absolute, state.root) or absolute == state.root then return nil end
  return absolute:sub(#state.root + 2), absolute
end

local function signature(path)
  local stat = uv.fs_stat(path)
  if not stat then return 'missing' end
  return table.concat({ stat.type, stat.size, stat.mtime.sec, stat.mtime.nsec, stat.ino or 0 }, ':')
end

local function loaded_buffer(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == '' then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= '' and canonical(name) == path then return buf end
    end
  end
  return -1
end

local function reload_clean(buf)
  if vim.bo[buf].modified then return false end
  local autoread = vim.bo[buf].autoread
  vim.bo[buf].autoread = true
  pcall(vim.api.nvim_buf_call, buf, function() vim.cmd('silent! checktime') end)
  if vim.api.nvim_buf_is_valid(buf) then vim.bo[buf].autoread = autoread end
  return true
end

local function changed_buffer(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= '' then return end
  local path = vim.api.nvim_buf_get_name(buf)
  if path ~= '' then path = canonical(path) end
  if path == '' or not inside(path, state.root) then return end
  local now = signature(path)
  local previous = state.watched[buf]
  state.watched[buf] = { path = path, signature = now }
  if not previous or previous.path ~= path or previous.signature == now then return end
  if vim.bo[buf].modified or now == 'missing' then
    local conflict_key = path .. '\0' .. now
    if not state.conflicts[conflict_key] then
      state.conflicts[conflict_key] = true
      if state.on_conflict then state.on_conflict(path, vim.bo[buf].modified and 'modified' or 'deleted') end
    end
    return
  end
  -- checktime only reloads a clean buffer. Never use :edit! here.
  reload_clean(buf)
end

local function refresh_buffers()
  local seen = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if not seen[buf] then changed_buffer(buf); seen[buf] = true end
  end
  if state.diff and valid_win(state.diff.right_win) then
    pcall(vim.api.nvim_win_call, state.diff.right_win, function() vim.cmd('silent! diffupdate') end)
  end
end

local function parse_status(output)
  local records = vim.split(output, '\0', { plain = true, trimempty = true })
  local changes, index = {}, 1
  while index <= #records do
    local record = records[index]
    local status, git_path = record:sub(1, 2), record:sub(4)
    local old_path
    if status:find('[RC]') then
      index = index + 1
      old_path = records[index]
    end
    if #record >= 4 and git_path ~= '' then
      local absolute = normalize(state.repo_root .. '/' .. git_path)
      if inside(absolute, state.root) then
        local entry = {
          path = absolute:sub(#state.root + 2), status = status,
          head_path = old_path or git_path,
        }
        if old_path then
          local old_absolute = normalize(state.repo_root .. '/' .. old_path)
          entry.old_path = inside(old_absolute, state.root) and old_absolute:sub(#state.root + 2) or old_absolute
        end
        table.insert(changes, entry)
      end
    end
    index = index + 1
  end
  table.sort(changes, function(a, b) return a.path < b.path end)
  return changes
end

function M.scan()
  if not state.root then return end
  refresh_buffers()
  if state.scan_job or not state.repo_root then return end
  local generation = state.generation
  state.scan_job = vim.system({ 'git', '--no-optional-locks', '-C', state.root, 'status',
    '--porcelain=v1', '-z', '--untracked-files=all', '--', '.' }, {}, function(result)
    vim.schedule(function()
      if generation ~= state.generation then return end
      state.scan_job = nil
      if result.code ~= 0 then
        report('Cannot read Git changes: ' .. vim.trim(result.stderr or ''))
        return
      end
      state.changes = parse_status(result.stdout or '')
      if state.on_update then state.on_update(vim.deepcopy(state.changes)) end
    end)
  end)
end

function M.list()
  return vim.deepcopy(state.changes)
end

local function read_text(path)
  local stat = uv.fs_lstat(path)
  if not stat then return {}, false end
  if stat.type == 'link' then return nil, false, 'Symlink diffs are not displayed as file contents.' end
  if stat.type ~= 'file' then return nil, false, 'Only regular text files can be opened in a diff.' end
  if stat.size > max_diff_bytes then return nil, false, 'File is too large for live diff (2 MiB limit).' end
  local fd = io.open(path, 'rb')
  if not fd then return nil, false, 'Cannot read ' .. path end
  local contents = fd:read('*a')
  fd:close()
  if contents:find('%z') then return nil, false, 'Binary files are listed but cannot be displayed as text diffs.' end
  local lines = vim.split(contents, '\n', { plain = true })
  if lines[#lines] == '' then table.remove(lines) end
  return #lines == 0 and { '' } or lines, true
end

local function scratch(name, lines, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = filetype or ''
  vim.bo[buf].modifiable = false
  return buf
end

function M.is_diff_open()
  return state.diff ~= nil and valid_win(state.diff.left_win) and valid_win(state.diff.right_win)
end

function M.close_diff()
  state.diff_request = (state.diff_request or 0) + 1
  local diff = state.diff
  if not diff then return end
  state.diff = nil
  if valid_win(diff.right_win) then
    for key, value in pairs(diff.options) do
      pcall(vim.api.nvim_set_option_value, key, value, { win = diff.right_win })
    end
    if diff.deleted_buf and vim.api.nvim_win_get_buf(diff.right_win) == diff.deleted_buf then
      local replacement = diff.previous_buf
      local available = vim.api.nvim_buf_is_valid(replacement)
      if available then
        local name = vim.api.nvim_buf_get_name(replacement)
        -- Re-entering a clean buffer whose file was removed triggers Neovim's
        -- E211. Preserve that hidden buffer, but close the deletion view onto
        -- a fresh editor buffer instead of reopening the missing file.
        if vim.bo[replacement].buftype == '' and name ~= '' and not vim.bo[replacement].modified
          and not uv.fs_stat(name) then available = false end
      end
      if not available then replacement = vim.api.nvim_create_buf(true, false) end
      vim.api.nvim_win_set_buf(diff.right_win, replacement)
    end
  end
  if valid_win(diff.left_win) then pcall(vim.api.nvim_win_close, diff.left_win, true) end
  if vim.api.nvim_buf_is_valid(diff.left_buf) then pcall(vim.api.nvim_buf_delete, diff.left_buf, { force = true }) end
end

local function safe_target(path, code_win)
  if not state.root or not valid_win(code_win) then return nil end
  local rel, absolute = relative(path)
  if not rel then report('Path must be inside the current project.'); return nil end
  local current = vim.api.nvim_win_get_buf(code_win)
  if vim.bo[current].modified then
    report('Save or discard your editor changes before switching the live view.')
    return nil
  end
  local existing = loaded_buffer(absolute)
  if existing >= 0 and vim.bo[existing].modified then
    report('The target file has unsaved editor changes; its buffer was preserved.')
    return nil
  end
  return rel, absolute
end

function M.follow(path, code_win, line)
  local _, absolute = safe_target(path, code_win)
  if not absolute then return false end
  local _, exists, err = read_text(absolute)
  if err then report(err); return false end
  if not exists then report('This file has been deleted; open its diff to inspect it.'); return false end
  M.close_diff()
  local buf = loaded_buffer(absolute)
  if buf < 0 then buf = vim.fn.bufadd(absolute) end
  vim.fn.bufload(buf)
  reload_clean(buf)
  vim.api.nvim_win_set_buf(code_win, buf)
  state.watched[buf] = { path = absolute, signature = signature(absolute) }
  if line then
    vim.api.nvim_win_set_cursor(code_win, { math.max(1, math.min(line, vim.api.nvim_buf_line_count(buf))), 0 })
  end
  return true
end

function M.show_diff(path, code_win)
  local rel, absolute = safe_target(path, code_win)
  if not rel then return false end
  if not state.repo_root then report('Live diffs need a Git repository.'); return false end
  local disk_lines, exists, err = read_text(absolute)
  if err then report(err); return false end
  M.close_diff()
  local request, generation = state.diff_request, state.generation
  local head_path = absolute:sub(#state.repo_root + 2)
  local known_new = false
  for _, change in ipairs(state.changes) do
    if change.path == rel then
      head_path = change.head_path
      known_new = change.status == '??' or change.status:sub(1, 1) == 'A'
      break
    end
  end
  local original_buf = vim.api.nvim_win_get_buf(code_win)
  vim.system({ 'git', '-C', state.repo_root, 'show', 'HEAD:' .. head_path }, {}, function(result)
    vim.schedule(function()
      if generation ~= state.generation or request ~= state.diff_request or not valid_win(code_win) then return end
      if vim.api.nvim_win_get_buf(code_win) ~= original_buf or vim.bo[original_buf].modified then return end
      local baseline = result.stdout or ''
      if result.code ~= 0 and not known_new then
        report('Cannot load the HEAD version of this file. Refresh changes and try again.')
        return
      end
      if #baseline > max_diff_bytes or baseline:find('%z') then
        report('The HEAD version is binary or too large for a live text diff.')
        return
      end
      -- Recheck disk and target buffer after the asynchronous Git read.
      local target = loaded_buffer(absolute)
      if target >= 0 and vim.bo[target].modified then report('Unsaved target buffer was preserved.'); return end
      disk_lines, exists, err = read_text(absolute)
      if err then report(err); return end
      local baseline_lines = vim.split(baseline, '\n', { plain = true })
      if baseline_lines[#baseline_lines] == '' then table.remove(baseline_lines) end
      if #baseline_lines == 0 then baseline_lines = { '' } end
      local filetype = vim.filetype.match({ filename = absolute }) or ''
      local left_buf = scratch('kiln://HEAD/' .. request .. '/' .. rel, baseline_lines, filetype)
      local right_buf
      if exists then
        right_buf = target >= 0 and target or vim.fn.bufadd(absolute)
        vim.fn.bufload(right_buf)
        reload_clean(right_buf)
      else
        right_buf = scratch('kiln://deleted/' .. request .. '/' .. rel, { '' }, filetype)
      end
      local options = {}
      for _, key in ipairs(diff_options) do options[key] = vim.api.nvim_get_option_value(key, { win = code_win }) end
      vim.api.nvim_win_set_buf(code_win, right_buf)
      local left_win
      vim.api.nvim_win_call(code_win, function()
        vim.cmd('leftabove vsplit')
        left_win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(left_win, left_buf)
        vim.cmd('diffthis')
      end)
      vim.api.nvim_win_call(code_win, function() vim.cmd('diffthis') end)
      local label = rel:gsub('\r', '\\r'):gsub('\n', '\\n'):gsub('%%', '%%%%')
      vim.wo[left_win].winbar = '%#KilnMuted# HEAD  /  ' .. label
      vim.wo[code_win].winbar = '%#KilnTitle# WORKTREE  /  ' .. label .. (exists and '' or ' (deleted)')
      state.diff = { left_win = left_win, left_buf = left_buf, right_win = code_win,
        options = options, previous_buf = original_buf, deleted_buf = not exists and right_buf or nil }
      if exists then state.watched[right_buf] = { path = absolute, signature = signature(absolute) } end
      local hunks = vim.diff(table.concat(baseline_lines, '\n') .. '\n', table.concat(disk_lines, '\n') .. '\n',
        { result_type = 'indices' })
      if hunks and hunks[1] then
        vim.api.nvim_win_set_cursor(code_win, { math.max(1, math.min(hunks[1][3], vim.api.nvim_buf_line_count(right_buf))), 0 })
      end
    end)
  end)
  return true
end

function M.stop()
  M.close_diff()
  state.generation = state.generation + 1
  if state.timer then state.timer:stop(); state.timer:close(); state.timer = nil end
  if state.scan_job then pcall(state.scan_job.kill, state.scan_job, 15); state.scan_job = nil end
  if state.augroup then pcall(vim.api.nvim_del_augroup_by_id, state.augroup); state.augroup = nil end
end

function M.setup(options)
  M.stop()
  local requested_root = vim.fn.fnamemodify(assert(options.root, 'root required'), ':p')
  state.root = normalize(uv.fs_realpath(requested_root) or requested_root)
  state.on_update, state.on_conflict, state.on_error = options.on_update, options.on_conflict, options.on_error
  state.changes, state.watched, state.conflicts = {}, {}, {}
  local result = vim.system({ 'git', '-C', state.root, 'rev-parse', '--show-toplevel' }, { text = true }):wait(3000)
  state.repo_root = result.code == 0 and normalize(vim.trim(result.stdout)) or nil
  state.augroup = vim.api.nvim_create_augroup('KilnChanges', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufWritePost' }, {
    group = state.augroup,
    callback = function(event)
      local path = canonical(vim.api.nvim_buf_get_name(event.buf))
      state.watched[event.buf] = { path = path, signature = signature(path) }
    end,
  })
  refresh_buffers()
  state.timer = uv.new_timer()
  local generation = state.generation
  state.timer:start(options.interval or 750, options.interval or 750, vim.schedule_wrap(function()
    if generation == state.generation then M.scan() end
  end))
  M.scan()
  return M
end

return M

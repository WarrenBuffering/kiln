-- Live working-tree visibility. All Git commands use argv, never a shell.
local uv = vim.uv or vim.loop
local serial = 0
local function new()
  serial = serial + 1
  local instance_id = serial
  local M = {}
  local state = { changes = {}, watched = {}, conflicts = {}, observed = {}, generation = 0, follow_view = true }
  local live_ns = vim.api.nvim_create_namespace('KilnLive' .. instance_id)
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
    if path == '' or not inside(path, state.root) or (state.owns_path and not state.owns_path(path)) then return end
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
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then changed_buffer(buf) end
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

  -- Fixed-base tasks keep committed edits visible as well as current work.
  local function parse_baseline(output, current)
    local records = vim.split(output, '\0', { plain = true, trimempty = true })
    local changes, by_path, index = {}, {}, 1
    local current_by_path = {}
    for _, entry in ipairs(current) do current_by_path[entry.path] = entry end
    while index <= #records do
      local status, old_path, git_path = records[index], nil, records[index + 1]
      index = index + 2
      if status:match('^[RC]') then
        old_path, git_path = git_path, records[index]
        index = index + 1
      end
      if git_path then
        local absolute = normalize(state.repo_root .. '/' .. git_path)
        if inside(absolute, state.root) then
          local path = absolute:sub(#state.root + 2)
          local existing = current_by_path[path]
          local entry = { path = path, status = existing and existing.status or (status:sub(1, 1) .. ' '),
            head_path = old_path or git_path, base_absent = status:sub(1, 1) == 'A' }
          if old_path then
            local old_absolute = normalize(state.repo_root .. '/' .. old_path)
            entry.old_path = inside(old_absolute, state.root) and old_absolute:sub(#state.root + 2) or old_absolute
          end
          changes[#changes + 1], by_path[path] = entry, entry
        end
      end
    end
    for _, entry in ipairs(current) do
      if entry.status == '??' and not by_path[entry.path] then
        changes[#changes + 1] = entry
      end
    end
    table.sort(changes, function(a, b) return a.path < b.path end)
    return changes
  end

  function M.scan()
    if not state.active or not state.root then return end
    refresh_buffers()
    if state.scan_pending or not state.repo_root or state.base_error then return end
    local generation = state.generation
    state.scan_pending = true
    local function complete(result, current)
      if generation ~= state.generation then return end
      state.scan_job, state.scan_pending = nil, false
      if result.code ~= 0 then
        report('Cannot read Git changes: ' .. vim.trim(result.stderr or ''))
        return
      end
      state.changes = current and parse_baseline(result.stdout or '', current) or parse_status(result.stdout or '')
      if state.on_update then state.on_update(vim.deepcopy(state.changes)) end
    end
    state.scan_job = vim.system({ 'git', '--no-optional-locks', '-C', state.root, 'status',
      '--porcelain=v1', '-z', '--untracked-files=all', '--', '.' }, {}, function(result)
      vim.schedule(function()
        if generation ~= state.generation then return end
        if result.code ~= 0 or not state.base then complete(result); return end
        local current = parse_status(result.stdout or '')
        state.scan_job = vim.system({ 'git', '--no-optional-locks', '-C', state.root, 'diff',
          '--no-ext-diff', '--no-textconv', '--name-status', '-z', '--find-renames', state.base, '--', '.' }, {}, function(diff)
          vim.schedule(function() complete(diff, current) end)
        end)
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
    return #lines == 0 and { '' } or lines, true, nil, contents
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

  function M.is_live_open()
    return state.live ~= nil and valid_win(state.live.win)
      and vim.api.nvim_win_get_buf(state.live.win) == state.live.buf
  end

  local function close_live()
    if state.live_job then pcall(state.live_job.kill, state.live_job, 15); state.live_job = nil end
    local live = state.live
    state.live = nil
    if not live then return end
    if vim.api.nvim_buf_is_valid(live.buf) then vim.api.nvim_buf_clear_namespace(live.buf, live_ns, 0, -1) end
    if valid_win(live.win) and vim.w[live.win].kiln_live_owner == instance_id then
      vim.w[live.win].kiln_live_owner = nil
      vim.wo[live.win].winbar = live.winbar
    end
  end

  function M.close_diff()
    state.diff_request = (state.diff_request or 0) + 1
    close_live()
    local diff = state.diff
    if not diff then return end
    state.diff = nil
    if valid_win(diff.right_win) and vim.w[diff.right_win].kiln_diff_owner == instance_id then
      vim.w[diff.right_win].kiln_diff_owner = nil
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
    if not state.active or not state.root or not valid_win(code_win) then return nil end
    local owner = vim.w[code_win].kiln_diff_owner
    local live_owner = vim.w[code_win].kiln_live_owner
    if (owner and owner ~= instance_id) or (live_owner and live_owner ~= instance_id) then
      report('Close the other task diff before switching the live view.')
      return nil
    end
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

  local function baseline_target(rel, absolute)
    local head_path = absolute:sub(#state.repo_root + 2)
    local known_new = false
    for _, change in ipairs(state.changes) do
      if change.path == rel then
        head_path = change.head_path
        known_new = change.status == '??' or (state.base and change.base_absent or not state.base and change.status:sub(1, 1) == 'A')
        break
      end
    end
    return head_path, known_new
  end

  -- Freezing following keeps a pending Git read from moving the user's cursor.
  -- The same file may still refresh; a different file cannot replace their view.
  function M.set_follow(enabled)
    state.follow_view = enabled ~= false
  end

  local function hunk_row(hunk, count)
    return math.max(1, math.min(hunk[3] + (hunk[4] == 0 and 1 or 0), count))
  end

  function M.next_hunk(direction, code_win)
    local live = state.live
    code_win = code_win or (live and live.win)
    if not live or not M.is_live_open() or code_win ~= live.win then return false end
    local count, rows, seen = vim.api.nvim_buf_line_count(live.buf), {}, {}
    for _, collection in ipairs({ live.hunks, live.latest_hunks or {} }) do
      for _, hunk in ipairs(collection) do
        local row = hunk_row(hunk, count)
        if not seen[row] then rows[#rows + 1], seen[row] = row, true end
      end
    end
    if #rows == 0 then return false end
    table.sort(rows)
    local current, target = vim.api.nvim_win_get_cursor(code_win)[1], nil
    if direction == -1 or direction == 'previous' then
      for index = #rows, 1, -1 do if rows[index] < current then target = rows[index]; break end end
      target = target or rows[#rows]
    else
      for _, row in ipairs(rows) do if row > current then target = row; break end end
      target = target or rows[1]
    end
    state.follow_view = false
    vim.api.nvim_win_set_cursor(code_win, { target, 0 })
    vim.api.nvim_win_call(code_win, function() vim.cmd('normal! zvzz') end)
    return true, target
  end

  -- Older Git changes remain visible quietly. The strongest marks describe the
  -- latest observed disk change, including edits that restore the Git baseline.
  -- Explicit review still uses the side-by-side show_diff view.
  function M.show_live(path, code_win)
    local rel, absolute = safe_target(path, code_win)
    if not rel then return false end
    if not state.follow_view and canonical(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(code_win))) ~= absolute then
      return false
    end
    if not state.repo_root then report('Live changes need a Git repository.'); return false end
    if state.base_error then report(state.base_error); return false end
    local _, exists, err = read_text(absolute)
    if err then report(err); return false end
    if not exists then return M.show_diff(path, code_win) end
    local saved_view = not state.follow_view and vim.api.nvim_win_call(code_win, vim.fn.winsaveview) or nil
    if not M.follow(path, code_win) then return false end
    if saved_view then vim.api.nvim_win_call(code_win, function() vim.fn.winrestview(saved_view) end) end
    local buf = vim.api.nvim_win_get_buf(code_win)
    local disk_lines, _, read_error, disk_text = read_text(absolute)
    if read_error then report(read_error); return false end
    if not disk_text then return false end
    -- Neovim removes CRLF delimiters and a UTF-8 BOM while reading. Compare the
    -- visible lines before painting so a missed reload cannot color stale text.
    local visible_lines = vim.deepcopy(disk_lines)
    if vim.bo[buf].fileformat == 'dos' then
      for index, line in ipairs(visible_lines) do visible_lines[index] = line:gsub('\r$', '') end
    end
    if vim.bo[buf].bomb then visible_lines[1] = visible_lines[1]:gsub('^\239\187\191', '') end
    if not vim.deep_equal(visible_lines, vim.api.nvim_buf_get_lines(buf, 0, -1, false)) then return false end
    local request, generation = state.diff_request, state.generation
    local tick, disk_signature = vim.api.nvim_buf_get_changedtick(buf), signature(absolute)
    local requested_cursor = vim.api.nvim_win_get_cursor(code_win)
    local head_path, known_new = baseline_target(rel, absolute)
    state.live_job = vim.system({ 'git', '-C', state.repo_root, 'show', (state.base or 'HEAD') .. ':' .. head_path }, {}, function(result)
      vim.schedule(function()
        if generation ~= state.generation or request ~= state.diff_request or not state.active then return end
        state.live_job = nil
        if not valid_win(code_win) or not vim.api.nvim_buf_is_valid(buf)
          or vim.api.nvim_win_get_buf(code_win) ~= buf or vim.bo[buf].modified
          or vim.api.nvim_buf_get_changedtick(buf) ~= tick or signature(absolute) ~= disk_signature then return end
        local diff_owner, live_owner = vim.w[code_win].kiln_diff_owner, vim.w[code_win].kiln_live_owner
        if (diff_owner and diff_owner ~= instance_id) or (live_owner and live_owner ~= instance_id) then return end
        if result.code ~= 0 and not known_new then
          report('Cannot load the review baseline of this file. Refresh changes and try again.'); return
        end
        local baseline = result.code == 0 and (result.stdout or '') or ''
        if #baseline > max_diff_bytes or baseline:find('%z') then
          report('The review baseline is binary or too large for live text changes.'); return
        end
        local hunks = vim.diff(baseline, disk_text, { result_type = 'indices' }) or {}
        local observed = state.observed[absolute]
        local latest = observed and observed.text == disk_text and observed.latest
          or vim.diff(observed and observed.text or baseline, disk_text, { result_type = 'indices' }) or {}
        state.observed[absolute] = { text = disk_text, latest = latest }
        local count = vim.api.nvim_buf_line_count(buf)
        vim.api.nvim_buf_clear_namespace(buf, live_ns, 0, -1)
        local decorations = {}
        local function paint(collection, quiet)
          for _, hunk in ipairs(collection) do
            local old_count, first, new_count = hunk[2], hunk[3], hunk[4]
            local kind = new_count == 0 and 'Delete' or (old_count == 0 and 'Add' or 'Change')
            local group = 'KilnEdit' .. kind .. (quiet and 'Quiet' or '')
            if new_count > 0 then
              for row = math.max(0, first - 1), math.min(count - 1, first + new_count - 2) do
                decorations[row] = { line_hl_group = group, sign_text = old_count == 0 and '+' or '~',
                  sign_hl_group = group, priority = quiet and 120 or 130 }
              end
            else
              local row = hunk_row(hunk, count) - 1
              decorations[row] = { line_hl_group = group, sign_text = '−', sign_hl_group = group,
                priority = quiet and 120 or 130,
                virt_text = { { '  − ' .. old_count .. (old_count == 1 and ' line' or ' lines'), group } },
                virt_text_pos = 'eol' }
            end
          end
        end
        paint(hunks, true)
        paint(latest, false)
        for row, options in pairs(decorations) do vim.api.nvim_buf_set_extmark(buf, live_ns, row, 0, options) end
        state.live = { buf = buf, win = code_win, tick = tick, path = absolute,
          winbar = vim.wo[code_win].winbar, hunks = hunks, latest_hunks = latest }
        vim.w[code_win].kiln_live_owner = instance_id
        local label = rel:gsub('\r', '\\r'):gsub('\n', '\\n'):gsub('%%', '%%%%')
        vim.wo[code_win].winbar = '%#KilnTitle# LIVE  /  ' .. label
        if state.follow_view and latest[1] and vim.deep_equal(vim.api.nvim_win_get_cursor(code_win), requested_cursor) then
          vim.api.nvim_win_set_cursor(code_win, { hunk_row(latest[1], count), 0 })
        end
      end)
    end)
    return true
  end

  function M.show_diff(path, code_win)
    local rel, absolute = safe_target(path, code_win)
    if not rel then return false end
    if not state.repo_root then report('Live diffs need a Git repository.'); return false end
    if state.base_error then report(state.base_error); return false end
    local disk_lines, exists, err = read_text(absolute)
    if err then report(err); return false end
    M.close_diff()
    local request, generation = state.diff_request, state.generation
    local head_path, known_new = baseline_target(rel, absolute)
    local original_buf = vim.api.nvim_win_get_buf(code_win)
    vim.system({ 'git', '-C', state.repo_root, 'show', (state.base or 'HEAD') .. ':' .. head_path }, {}, function(result)
      vim.schedule(function()
        if generation ~= state.generation or request ~= state.diff_request or not valid_win(code_win) then return end
        if vim.api.nvim_win_get_buf(code_win) ~= original_buf or vim.bo[original_buf].modified then return end
        local baseline = result.stdout or ''
        if result.code ~= 0 and not known_new then
          report('Cannot load the review baseline of this file. Refresh changes and try again.')
          return
        end
        if #baseline > max_diff_bytes or baseline:find('%z') then
          report('The review baseline is binary or too large for a live text diff.')
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
        local left_buf = scratch('kiln://' .. instance_id .. '/' .. (state.base and 'BASE' or 'HEAD') .. '/' .. request .. '/' .. rel, baseline_lines, filetype)
        local right_buf
        if exists then
          right_buf = target >= 0 and target or vim.fn.bufadd(absolute)
          vim.fn.bufload(right_buf)
          reload_clean(right_buf)
        else
          right_buf = scratch('kiln://' .. instance_id .. '/deleted/' .. request .. '/' .. rel, { '' }, filetype)
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
        vim.wo[left_win].winbar = '%#KilnMuted# ' .. (state.base and 'BASE' or 'HEAD') .. '  /  ' .. label
        vim.wo[code_win].winbar = '%#KilnTitle# WORKTREE  /  ' .. label .. (exists and '' or ' (deleted)')
        vim.w[code_win].kiln_diff_owner = instance_id
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
    state.active, state.scan_pending = false, false
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
    state.owns_path = options.owns_path
    state.changes, state.watched, state.conflicts, state.observed = {}, {}, {}, {}
    state.follow_view = true
    state.base, state.base_error, state.active = nil, nil, true
    local result = vim.system({ 'git', '-C', state.root, 'rev-parse', '--show-toplevel' }, { text = true }):wait(3000)
    state.repo_root = result.code == 0 and normalize(vim.trim(result.stdout)) or nil
    if options.base then
      local base = type(options.base) == 'string' and options.base or ''
      local resolved = vim.system({ 'git', '-C', state.root, 'rev-parse', '--verify', '--end-of-options', base .. '^{commit}' }, { text = true }):wait(3000)
      if resolved.code == 0 then state.base = vim.trim(resolved.stdout)
      else state.base_error = 'The task review baseline is unavailable. Restore its Git commit before reviewing.'; report(state.base_error) end
    end
    state.augroup = vim.api.nvim_create_augroup('KilnChanges' .. instance_id, { clear = true })
    vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'BufWritePost', 'BufWinEnter' }, {
      group = state.augroup,
      callback = function(event)
        local live = state.live
        if not live then return end
        if not valid_win(live.win) or vim.api.nvim_win_get_buf(live.win) ~= live.buf
          or (event.buf == live.buf and (vim.bo[live.buf].modified
            or vim.api.nvim_buf_get_changedtick(live.buf) ~= live.tick)) then
          M.close_diff()
        end
      end,
    })
    vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufWritePost' }, {
      group = state.augroup,
      callback = function(event)
        local name = vim.api.nvim_buf_get_name(event.buf)
        if name == '' or vim.bo[event.buf].buftype ~= '' then return end
        local path = canonical(name)
        if inside(path, state.root) and (not state.owns_path or state.owns_path(path)) then
          state.watched[event.buf] = { path = path, signature = signature(path) }
          if event.event == 'BufWritePost' then
            -- A saved manual handoff is an observed version too. The next
            -- agent delta must not relabel that human edit as its newest work.
            local _, exists, err, text = read_text(path)
            if exists and not err and text then state.observed[path] = { text = text, latest = {} } end
          end
        end
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

  M.new = new
  return M
end

return new()

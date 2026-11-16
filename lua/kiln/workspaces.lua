-- Local Git workspace operations. Provider processes never own this boundary.
local M = {}
local home = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h:h')

function M.run(operation, options, callback)
  local command = { vim.env.KILN_PYTHON or 'python3', home .. '/python/workspaces.py', operation }
  for _, key in ipairs({ 'root', 'storage', 'id', 'workspace', 'branch', 'base', 'expected' }) do
    if options[key] then vim.list_extend(command, { '--' .. key, tostring(options[key]) }) end
  end
  return vim.system(command, { text = true, timeout = 120000 }, vim.schedule_wrap(function(result)
    local ok, value = pcall(vim.json.decode, result.stdout or '')
    if not ok or type(value) ~= 'table' then
      value = { ok = false, error = vim.trim(result.stderr or '') }
      if value.error == '' then value.error = 'Workspace operation failed (' .. tostring(result.code) .. ').' end
    end
    callback(value)
  end))
end

return M

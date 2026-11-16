-- A readable projection of the continuous conversation. Original events remain
-- intact and every displayed row opens its full message or activity group.
local M = {}
local fn = vim.fn
local dossier = require('kiln.dossier')

local activity_types = { tool = true, file = true, status = true, usage = true, notice = true,
  session = true, done = true }

local function clean(value)
  return tostring(value or ''):gsub('\t', '  '):gsub('%c', '')
end

local function clip(value, width)
  local text = clean(value)
  if fn.strdisplaywidth(text) <= width then return text end
  local count = fn.strchars(text)
  while count > 0 and fn.strdisplaywidth(fn.strcharpart(text, 0, count) .. '…') > width do count = count - 1 end
  return width > 0 and (fn.strcharpart(text, 0, count) .. '…') or ''
end

local function fence(line)
  local marker, language = line:match('^%s*(```+)%s*([%w_-]*)%s*$')
  if not marker then marker, language = line:match('^%s*(~~~+)%s*([%w_-]*)%s*$') end
  return marker, language
end

local function closes(line, marker)
  local candidate, language = fence(line)
  return candidate and candidate:sub(1, 1) == marker:sub(1, 1) and #candidate >= #marker and language == ''
end

local function accepted_plan(text, options)
  if not options.accepted or not options.plan then return nil end
  local plan = dossier.parse(text)
  if not plan then return nil end
  -- Do not call a different, unaccepted proposal ready just because an older
  -- dossier exists. Fingerprints include the actual shared brief and steps.
  if plan.fingerprint ~= options.plan.fingerprint then return nil end
  return plan
end

local function plan_line(plan)
  return 'Plan ready · ' .. #plan.steps .. (#plan.steps == 1 and ' step' or ' steps') .. ' · Enter to inspect'
end

local function message_lines(event, options)
  local raw = tostring(event.text or '')
  if event.role ~= 'assistant' then return vim.split(raw, '\n', { plain = true }) end
  local whole = accepted_plan(vim.trim(raw), options)
  if whole then return { plan_line(whole) } end
  local result, input, index = {}, vim.split(raw, '\n', { plain = true }), 1
  while index <= #input do
    local line = input[index]
    local marker, language = fence(line)
    if marker then
      local last = index + 1
      while last <= #input and not closes(input[last], marker) do last = last + 1 end
      if last <= #input then
        local block = {}
        for row = index + 1, last - 1 do block[#block + 1] = input[row] end
        local plan = (language == 'dossier' or language == 'markdown')
          and accepted_plan(table.concat(block, '\n'), options) or nil
        if plan then result[#result + 1] = plan_line(plan)
        else for row = index, last do result[#result + 1] = input[row] end end
        index = last + 1
      else
        -- Streaming/unclosed fences are still content, never hidden proposals.
        for row = index, #input do result[#result + 1] = input[row] end
        break
      end
    elseif vim.trim(line):match('^<kiln_step_complete%s+id=["\'][^"\']+["\']%s*/>$') then
      index = index + 1
    else
      result[#result + 1] = line
      index = index + 1
    end
  end
  while #result > 0 and vim.trim(result[#result]) == '' do table.remove(result) end
  return result
end

local function raw_activity(events)
  local text = {}
  for _, event in ipairs(events) do
    local label = tostring(event.type or 'event'):upper()
    if event.name then label = label .. ' / ' .. tostring(event.name) end
    if event.status then label = label .. ' / ' .. tostring(event.status) end
    if event.action then label = label .. ' / ' .. tostring(event.action) end
    text[#text + 1] = '[' .. label .. ']'
    if event.path then text[#text + 1] = tostring(event.path) end
    if event.text ~= nil then text[#text + 1] = tostring(event.text)
    elseif event.type ~= 'file' then text[#text + 1] = vim.inspect(event) end
    text[#text + 1] = ''
  end
  return table.concat(text, '\n')
end

local function activity_label(events)
  local tools, files = 0, {}
  for _, event in ipairs(events) do
    if event.type == 'tool' then tools = tools + 1 end
    if event.type == 'file' and event.path then files[event.path] = true end
  end
  local count, parts = vim.tbl_count(files), {}
  if tools > 0 then parts[#parts + 1] = tools .. (tools == 1 and ' tool' or ' tools') end
  if count > 0 then parts[#parts + 1] = count .. (count == 1 and ' file' or ' files') end
  if #parts == 0 then
    parts[1] = #events .. (#events == 1 and ' event' or ' events')
  end
  return 'Activity · ' .. table.concat(parts, ' · ')
end

function M.render(session, options)
  session, options = session or {}, options or {}
  options = vim.tbl_extend('force', {}, options)
  local width = math.max(1, math.floor(tonumber(options.width) or 45))
  if options.accepted == nil then
    local phase = session.workflow and session.workflow.phase
    options.accepted = options.plan ~= nil and phase ~= nil and phase ~= 'planning'
  end
  local view = { lines = {}, marks = {}, rows = {} }
  local function add(value, event, group, bounded)
    local text = clean(value)
    if options.root and options.root ~= '' then text = text:gsub(vim.pesc(options.root .. '/'), '') end
    if bounded then text = clip(text, width) end
    view.lines[#view.lines + 1] = text
    local row = #view.lines
    view.rows[row] = event
    if group then view.marks[#view.marks + 1] = { row = row, group = group } end
  end
  local function blank(event)
    if #view.lines > 0 and view.lines[#view.lines] ~= '' then add('', event) end
  end
  local pending = {}
  local function flush()
    if #pending == 0 then return end
    local group = { type = 'activity', name = 'Activity history', text = raw_activity(pending), events = pending }
    blank(group)
    add(activity_label(pending), group, 'KilnMuted', true)
    add('Enter to inspect activity', group, 'KilnMuted', true)
    pending = {}
  end
  for _, event in ipairs(session.events or {}) do
    local failure = event.type == 'error' or (event.type == 'tool' and (event.status == 'error' or event.status == 'failed'))
    if activity_types[event.type] and not failure then
      pending[#pending + 1] = event
    else
      flush()
      local body, label, group
      if event.type == 'message' then
        body = message_lines(event, options)
        label = event.role == 'user' and 'YOU' or tostring(event.agent or session.provider or 'AGENT'):upper()
        group = event.role == 'user' and 'KilnAccent' or 'KilnSuccess'
      elseif failure then
        body = vim.split(tostring(event.text or event.path or 'The operation failed.'), '\n', { plain = true })
        label = 'ATTENTION' .. (event.name and (' · ' .. event.name) or '')
        group = 'KilnError'
      elseif event.type == 'human' then
        body = { tostring(event.path or tostring(event.text or ''):match('^[^\n]*') or 'File') .. ' saved' }
        label, group = 'YOU SAVED', 'KilnUser'
      else
        body = vim.split(tostring(event.text or event.path or ''), '\n', { plain = true })
        label, group = 'KILN', 'KilnMuted'
      end
      if #body > 0 then
        blank(event)
        add(label, event, group, true)
        for _, line in ipairs(body) do add(line, event, failure and 'KilnError' or nil) end
        if event.type == 'message' and event.role == 'assistant' and event.paths and #event.paths > 0 then
          add('↳ ' .. table.concat(event.paths, ', ') .. ' · gf view change', event, 'KilnAccent', true)
        end
      end
    end
  end
  flush()
  return view
end

return M

-- Compact current-turn activity beside a dossier. The session retains the full
-- transcript; each visible row points to its original event for inspection.
local M = {}
local fn = vim.fn

local function clean(value)
  return tostring(value or ''):gsub('[\r\n\t]', ' '):gsub('%c', ''):gsub(' +', ' '):gsub('^ ', ''):gsub(' $', '')
end

local function clip(value, width)
  if fn.strdisplaywidth(value) <= width then return value end
  local count = fn.strchars(value)
  while count > 0 and fn.strdisplaywidth(fn.strcharpart(value, 0, count)) > width - 1 do count = count - 1 end
  return fn.strcharpart(value, 0, count) .. '…'
end

local function wrap(value, width, limit)
  local result, line = {}, ''
  for word in clean(value):gmatch('%S+') do
    local next_line = line == '' and word or line .. ' ' .. word
    if line ~= '' and fn.strdisplaywidth(next_line) > width then
      result[#result + 1], line = line, word
    else line = next_line end
  end
  if line ~= '' then result[#result + 1] = line end
  if #result > limit then
    result[limit] = table.concat(result, ' ', limit)
    while #result > limit do table.remove(result) end
  end
  for index, text in ipairs(result) do result[index] = clip(text, width) end
  return result
end

local function hold_notice(event)
  if event.type ~= 'notice' then return false end
  local text = tostring(event.text or '')
  return text:find('You control this worktree', 1, true) or text:find('Taking control.', 1, true)
end

function M.render(session, width, height)
  local view = { lines = {}, marks = {}, rows = {} }
  width, height = math.floor(tonumber(width) or 40), math.floor(tonumber(height) or 8)
  if width < 1 or height < 1 then return view end
  session = session or {}
  local events = session.events or {}
  local first, request = 1, nil
  for index = #events, 1, -1 do
    local event = events[index]
    if event.type == 'message' and event.role == 'user' then first, request = index + 1, event; break end
  end
  local assistant, action, failure, human
  for index = first, #events do
    local event = events[index]
    if event.type == 'message' and event.role == 'assistant' and clean(event.text) ~= '' then assistant = event end
    if event.type == 'file' or event.type == 'tool' then action = event end
    if event.type == 'error' or (event.type == 'tool' and event.status == 'error') then failure = event end
    if session.human_control and (event.type == 'human' or hold_notice(event)) then human = event end
  end
  local blocks = {}
  local function block(event, label, value, group, maximum, inline)
    if not event then return end
    local text = clean(value)
    local body = inline and wrap(label .. (text ~= '' and (' ' .. text) or ''), width, maximum)
      or wrap(text, width, math.max(1, maximum - 1))
    local content = inline and body or { clip(label, width) }
    if not inline then vim.list_extend(content, body) end
    local minimum = event.type == 'message' and event.role == 'assistant' and 3 or 2
    blocks[#blocks + 1] = { event = event, content = content, group = group,
      minimum = inline and 1 or math.min(minimum, #content), maximum = math.min(maximum, #content) }
  end
  if failure then
    local label = failure.type == 'tool' and ('ATTENTION / ' .. clean(failure.name or 'tool')) or 'ATTENTION'
    block(failure, label, failure.text, 'KilnError', 3)
  end
  if human then
    local label = human.type == 'human' and 'YOU SAVED' or 'YOU EDIT'
    block(human, label, human.path or human.text, 'KilnUser', 3)
  end
  if assistant then block(assistant, clean(assistant.agent or session.provider or 'AGENT'):upper(), assistant.text, 'KilnSuccess', 5) end
  if action and action ~= failure then
    if action.type == 'file' then
      block(action, 'FILE' .. (action.action and (' / ' .. clean(action.action)) or ''), action.path or action.text, 'KilnAccent', 2, true)
    else
      local label = clean(action.name or 'TOOL') .. (action.status and (' / ' .. clean(action.status)) or '')
      block(action, label, action.text, 'KilnTool', 2, true)
    end
  end
  -- Before the provider emits anything, the actual submitted request is the
  -- only current-turn content available. Do not invent a progress message.
  if #blocks == 0 and request then block(request, 'YOU', request.text, 'KilnAccent', 3) end

  local remaining = height
  for _, item in ipairs(blocks) do
    item.allocated = math.min(item.minimum, remaining)
    remaining = remaining - item.allocated
  end
  -- Give errors and narration their readable lines before secondary actions.
  for _, item in ipairs(blocks) do
    local extra = math.min(item.maximum - item.allocated, remaining)
    item.allocated, remaining = item.allocated + extra, remaining - extra
  end
  for _, item in ipairs(blocks) do
    if item.allocated > 0 then
      local content = vim.list_slice(item.content, 1, item.allocated)
      if item.allocated < #item.content then
        content[#content] = clip(table.concat(item.content, ' ', item.allocated), width)
      end
      for index, line in ipairs(content) do
        if line ~= '' then
          view.lines[#view.lines + 1] = line
          view.rows[#view.lines] = item.event
          if index == 1 or item.group == 'KilnError' then
            view.marks[#view.marks + 1] = { row = #view.lines, group = item.group }
          end
        end
      end
    end
  end
  return view
end

return M

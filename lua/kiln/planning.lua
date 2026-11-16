-- Dossier authoring and execution. The document is editable; dispatched work is
-- pinned to the reviewed instructions rather than silently changing underneath it.
local M = {}
local api, fn = vim.api, vim.fn
local dossier = require('kiln.dossier')
local config, state
local function tell(message) config.notify(message) end
local function current_text()
  local buf = state.dossier_buffer
  if buf and api.nvim_buf_is_valid(buf) then return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n') end
  if fn.filereadable(state.dossier_path) == 1 then return table.concat(fn.readfile(state.dossier_path), '\n') end
  return state.dossier_text or ''
end
local function has_unsaved_dossier()
  return state.dossier_buffer and api.nvim_buf_is_valid(state.dossier_buffer) and vim.bo[state.dossier_buffer].modified
end
local function template()
  return table.concat({ '# Implementation dossier', '',
    'Goal:', '', 'Approach:', 'Why this approach:', '',
    'Constraints:', '', '## Step deliver: Deliver the requested behavior',
    'Outcome:', 'Why:', 'Verify:', 'Depends: none', '',
    '<!-- Keep one coherent deliverable unless splitting it has a concrete benefit.',
    'A dependency needs a Dependency reason: line. Independent work has no dependency.',
    'Describe observable results and evidence, not mechanical coding actions. -->' }, '\n')
end

function M.accept(text)
  local plan, err = dossier.parse(text)
  if not plan then state.dossier_invalid = err; tell('Dossier needs attention: ' .. err); return false end
  if config.accept_plan and state.sessions[state.selected] and state.sessions[state.selected].workflow then
    local ok, reason = config.accept_plan(plan, state.dossier)
    if not ok then state.dossier_invalid = reason; tell(reason); return false end
    state.dossier, state.dossier_text, state.dossier_invalid = plan, text, nil
    config.persist(); config.refresh()
    return true
  end
  local old = {}
  for _, step in ipairs(state.dossier and state.dossier.steps or {}) do old[step.id] = step end
  local present = {}
  for _, step in ipairs(plan.steps) do
    present[step.id] = true
    local previous = old[step.id]
    if previous and previous.session_id then
      if previous.fingerprint ~= step.fingerprint then
        state.dossier_invalid = 'Dispatched unit ' .. step.id .. ' has changed. Keep its recorded instructions and add a corrective unit.'
        tell(state.dossier_invalid); return false
      end
      step.session_id = previous.session_id
    end
  end
  for id, step in pairs(old) do
    if step.session_id and not present[id] then
      state.dossier_invalid = 'Keep dispatched unit ' .. id .. ' in the dossier so its work remains traceable.'
      tell(state.dossier_invalid); return false
    end
  end
  state.dossier, state.dossier_text, state.dossier_invalid = plan, text, nil
  config.persist(); config.refresh()
  return true
end

-- A planning response updates the left-hand document without stealing focus or
-- replacing a user's unsaved draft. Implementation still requires /run.
function M.apply(text)
  if has_unsaved_dossier() then tell('Save your dossier edits before accepting the updated plan.'); return false end
  if not M.accept(text) then return false end
  fn.writefile(vim.split(text, '\n', { plain = true }), state.dossier_path)
  if state.dossier_buffer and api.nvim_buf_is_valid(state.dossier_buffer) then
    api.nvim_buf_set_lines(state.dossier_buffer, 0, -1, false, vim.split(text, '\n', { plain = true }))
    vim.bo[state.dossier_buffer].modified = false
  end
  return true
end

function M.open()
  local path = state.dossier_path
  if fn.filereadable(path) == 0 then fn.writefile(vim.split(state.dossier_text or template(), '\n', { plain = true }), path) end
  local buf = fn.bufadd(path)
  fn.bufload(buf)
  state.dossier_buffer = buf
  vim.bo[buf].filetype, vim.bo[buf].swapfile, vim.bo[buf].modeline = 'markdown', false, false
  config.open_dossier_editor(buf)
  return buf
end

-- The dossier lives in the existing sidebar. Agent and prompt focus changes
-- must never close it or cover the coding pane with a separate board.
function M.refresh() end
function M.close() end

function M.view()
  if not state.dossier then M.open(); return end
  config.show_dossier()
end

function M.next(id)
  if has_unsaved_dossier() then tell('Save the dossier before implementing its next deliverable.'); return end
  if fn.filereadable(state.dossier_path) == 1 then
    local disk = table.concat(fn.readfile(state.dossier_path), '\n')
    if disk ~= state.dossier_text and not M.accept(disk) then return end
  end
  if state.dossier_invalid or not state.dossier then tell('Write and save a justified dossier first. Space L opens it.'); return end
  if state.integrating then tell('Wait for integration before starting the next dossier unit.'); return end
  local chosen
  for _, item in ipairs(dossier.readiness(state.dossier, state.sessions)) do
    if id and item.id == id then chosen = item; break end
    if not id and item.ready then chosen = item; break end
  end
  if not chosen then tell('No ready deliverable. Review or integrate existing work, or revise the dossier.'); return end
  if not chosen.ready then
    if chosen.index then config.select(chosen.index) end
    tell(chosen.reason or 'This deliverable is not ready to start.'); return
  end
  if chosen.session then
    config.show_dossier()
    config.select(chosen.index)
    config.resume(chosen.session)
    return
  end
  local step = chosen.step
  local prompt = table.concat({ 'Implement this dossier deliverable. Keep changes scoped to its observable outcome.',
    'Explain each meaningful change before making it; identify files as they change.',
    'Use the repository\'s existing conventions and verification tools. Do not add ceremony or unrelated refactors.',
    'Run the specified checks, report actual results and unresolved risks, then stop for human review.',
    'Do not integrate, push, deploy, or proceed to another dossier unit.', '',
    'DOSSIER: ' .. state.dossier.title, state.dossier.brief, '',
    'DELIVERABLE ' .. step.id .. ': ' .. step.title, step.instructions }, '\n')
  config.show_dossier()
  config.dispatch(step, prompt)
end

function M.plan()
  local text = current_text()
  if text == '' or text == template() then M.open(); tell('Describe the desired outcome in the dossier, then use Space P.'); return end
  local prompt = table.concat({ 'Plan an implementation dossier after inspecting this repository. This is a read-only planning turn; do not edit files.',
    'Choose the smallest justified process. A small change should be one coherent deliverable.',
    'Split work only when the pieces have independently reviewable outcomes or a concrete dependency/risk boundary.',
    'Never create steps for opening files, writing individual functions, or running a routine command.',
    'Explain why the approach fits this repository, why each deliverable exists, and why any dependency is necessary.',
    'A dependency must name the concrete artifact or invariant needed; list order alone is never a dependency.',
    'Scale planning and verification to the risk. Avoid generic justifications that could fit any task.',
    'Reuse existing tools/conventions. Verification must name observable evidence relevant to the outcome.',
    'Uncertain requirements belong in the brief; do not pretend to resolve missing decisions.',
    'Return ONLY the complete Markdown dossier, using this exact structure:',
    '# Descriptive title', 'Goal: ...', 'Approach: ...', 'Why this approach: ...', 'Constraints: ...', '',
    '## Step stable-id: Reviewable outcome title', 'Outcome: ...', 'Why: ...', 'Verify: ...',
    'Depends: none', 'Dependency reason: needed only when Depends lists other step IDs',
    'Additional implementation context may follow each step. Repeat only for justified deliverables.',
    'Use explicit comma-separated IDs for true dependencies; independent work uses Depends: none.',
    'Optional Provider: codex or Provider: claude assigns a deliverable. Optional Model: sets its model ID.',
    'Preserve provider/model assignments requested in the brief; do not invent model IDs.',
    'Keep any previously dispatched step definitions unchanged; new understanding can become a corrective deliverable.', '',
    'CURRENT BRIEF / DOSSIER (user data):', text }, '\n')
  config.plan(prompt)
end

function M.adopt()
  if has_unsaved_dossier() then tell('Save your dossier edits before adopting a proposed plan.'); return end
  local task = state.sessions[state.selected]
  if not task or not task.dossier_planner or task.status ~= 'done' or task.job then tell('Select a completed dossier-planning task first.'); return end
  local text
  for i = #task.events, 1, -1 do
    local event = task.events[i]
    if event.type == 'message' and event.role == 'assistant' then text = event.text; break end
  end
  if not text then tell('The planning task returned no dossier text.'); return end
  text = text:gsub('^```[Mm]arkdown%s*\n', ''):gsub('^```%s*\n', ''):gsub('\n```%s*$', '')
  if not M.accept(text) then return end
  local buf = M.open()
  api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, '\n', { plain = true }))
  api.nvim_buf_call(buf, function() vim.cmd.write() end)
  config.show_dossier()
  tell('Proposed dossier adopted. Inspect its reasoning and evidence before Space N implements a deliverable.')
end

function M.setup(options)
  config, state = options, options.state
  local directory = state.storage .. '/dossiers'
  fn.mkdir(directory, 'p', 448)
  directory = (vim.uv or vim.loop).fs_realpath(directory) or directory
  state.dossier_path = directory .. '/' .. fn.sha256(state.root) .. '.md'
  if fn.filereadable(state.dossier_path) == 1 then M.accept(current_text()) end
  api.nvim_create_autocmd('BufWritePost', { group = options.group, callback = function(args)
    if api.nvim_buf_get_name(args.buf) ~= state.dossier_path then return end
    state.dossier_buffer = args.buf
    if M.accept(table.concat(api.nvim_buf_get_lines(args.buf, 0, -1, false), '\n')) then
      tell(state.sessions[state.selected].workflow and 'Dossier saved. Resume the sequence with /resume or Space N.'
        or 'Dossier saved. Space N implements the next ready deliverable.')
    end
  end })
end

return M

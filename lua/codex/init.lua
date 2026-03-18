local M = {}

local defaults = {
  width = 0.48,
  height = 1.0,
  margin = 2,
  prompt_height = 7,
  toggle_key = '<leader>cc',
  quit_key = '<C-q>',
  send_key = '<CR>',
  attach_file_key = '<C-f>',
  interrupt_key = '<C-c>',
  max_attachment_lines = 180,
  app_server_cmd = { 'codex', 'app-server', '--listen', 'stdio://' },
  approval_policy = nil,
  sandbox = nil,
  personality = 'pragmatic',
}

local state = {
  transcript_buf = nil,
  transcript_win = nil,
  prompt_buf = nil,
  prompt_win = nil,
  source_win = nil,
  attachments = {},
  last_snapshot = nil,
  session = {
    job = nil,
    initialized = false,
    initialize_sent = false,
    thread_id = nil,
    request_id = 0,
    pending = {},
    after_initialize = {},
    after_thread = {},
    stdout_tail = '',
    stderr_tail = '',
    active_turn_id = nil,
    turn_running = false,
  },
  transcript = {
    line_count = 0,
    active_messages = {},
  },
  ui_status = 'Ready',
  ui_status_animated = false,
  ui_spinner_index = 1,
  ui_spinner_timer = nil,
  pending_approval = nil,
  latest_turn_diff = '',
  file_change_items = {},
}

local config = vim.deepcopy(defaults)
local spinner_frames = { '|', '/', '-', '\\' }
local transcript_ns = vim.api.nvim_create_namespace('codex_panel_transcript')
local find_source_win
local close_window

local function is_valid_buf(buf)
  return type(buf) == 'number' and vim.api.nvim_buf_is_valid(buf)
end

local function is_valid_win(win)
  return type(win) == 'number' and vim.api.nvim_win_is_valid(win)
end

local function is_plugin_buf(buf)
  return buf == state.transcript_buf
    or buf == state.prompt_buf
end

local function short_path(path)
  if not path or path == '' then
    return '[No Name]'
  end

  local cwd = vim.loop.cwd()
  if cwd and path:sub(1, #cwd) == cwd then
    local rel = path:sub(#cwd + 2)
    if rel ~= '' then
      return rel
    end
  end

  return vim.fn.fnamemodify(path, ':~')
end

local function join_path(root, relative)
  if relative:sub(1, 1) == '/' then
    return relative
  end
  if root:sub(-1) == '/' then
    return root .. relative
  end
  return root .. '/' .. relative
end

local function trim_lines(lines, limit)
  if #lines <= limit then
    return vim.deepcopy(lines)
  end

  local trimmed = {}
  for i = 1, limit do
    trimmed[i] = lines[i]
  end
  trimmed[#trimmed + 1] = ('... [%d more lines omitted]'):format(#lines - limit)
  return trimmed
end

local function trim_text(value)
  return (value or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function sanitize_text(value)
  if value == nil then
    return ''
  end
  if value == vim.NIL then
    return ''
  end
  return tostring(value):gsub('%z', '')
end

local function diff_paths(diff)
  local paths = {}
  local seen = {}
  for line in sanitize_text(diff):gmatch('[^\n]+') do
    local path = line:match('^diff %-%-git a/(.-) b/')
    if path and not seen[path] then
      seen[path] = true
      paths[#paths + 1] = path
    end
  end
  return paths
end

local function cache_file_change_item(item)
  if not item or item.type ~= 'fileChange' or not item.id then
    return
  end

  local changes = {}
  for _, change in ipairs(item.changes or {}) do
    changes[#changes + 1] = {
      path = sanitize_text(change.path),
      diff = sanitize_text(change.diff),
      kind = sanitize_text(change.kind),
    }
  end
  state.file_change_items[item.id] = changes
end

local function approval_lines(decoded)
  local method = decoded.method
  local params = decoded.params or {}
  local lines = { '', 'Approval Required' }

  if method == 'item/commandExecution/requestApproval' then
    lines[#lines + 1] = sanitize_text(params.command or params.reason or 'Approve command execution?')
  elseif method == 'item/fileChange/requestApproval' then
    lines[#lines + 1] = sanitize_text(params.reason or 'Approve file change?')

    local changes = state.file_change_items[params.itemId] or {}
    local paths = {}
    for _, change in ipairs(changes) do
      if change.path ~= '' then
        paths[#paths + 1] = change.path
      end
    end
    if vim.tbl_isempty(paths) then
      paths = diff_paths(state.latest_turn_diff)
    end

    if not vim.tbl_isempty(paths) then
      lines[#lines + 1] = ''
      lines[#lines + 1] = 'Files'
      for _, path in ipairs(paths) do
        lines[#lines + 1] = '- ' .. path
      end
    end

    local diff = ''
    if not vim.tbl_isempty(changes) then
      local chunks = {}
      for _, change in ipairs(changes) do
        if change.diff ~= '' then
          chunks[#chunks + 1] = change.diff
        end
      end
      diff = table.concat(chunks, '\n')
    end
    if diff == '' then
      diff = state.latest_turn_diff
    end

    diff = sanitize_text(diff)
    if diff ~= '' then
      lines[#lines + 1] = ''
      lines[#lines + 1] = '```diff'
      for _, line in ipairs(vim.split(diff, '\n', { plain = true })) do
        lines[#lines + 1] = line
      end
      lines[#lines + 1] = '```'
    end
  elseif method == 'item/permissions/requestApproval' then
    lines[#lines + 1] = sanitize_text(params.reason or 'Approve extra permissions?')
  else
    lines[#lines + 1] = sanitize_text('Unhandled request: ' .. tostring(method))
  end

  lines[#lines + 1] = ''
  lines[#lines + 1] = 'Type `y` to approve once, `a` to approve for the session, or `n` to decline. Then press Enter.'
  return lines
end

local function normalize_decoded(value)
  if value == vim.NIL then
    return nil
  end

  if type(value) ~= 'table' then
    return value
  end

  local normalized = {}
  for key, item in pairs(value) do
    local normalized_item = normalize_decoded(item)
    if normalized_item ~= nil then
      normalized[key] = normalized_item
    end
  end
  return normalized
end

local function buf_line_count(buf)
  return vim.api.nvim_buf_line_count(buf)
end

local function ensure_transcript_buf()
  if is_valid_buf(state.transcript_buf) then
    return state.transcript_buf
  end

  state.transcript_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.transcript_buf].bufhidden = 'hide'
  vim.bo[state.transcript_buf].buftype = 'nofile'
  vim.bo[state.transcript_buf].swapfile = false
  vim.bo[state.transcript_buf].filetype = 'markdown'
  vim.bo[state.transcript_buf].modifiable = false
  return state.transcript_buf
end

local function ensure_prompt_buf()
  if is_valid_buf(state.prompt_buf) then
    return state.prompt_buf
  end

  state.prompt_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.prompt_buf].bufhidden = 'hide'
  vim.bo[state.prompt_buf].buftype = 'nofile'
  vim.bo[state.prompt_buf].swapfile = false
  vim.bo[state.prompt_buf].filetype = 'text'
  vim.api.nvim_buf_set_lines(state.prompt_buf, 0, -1, false, { '' })
  return state.prompt_buf
end

local function highlight_transcript()
  if not is_valid_buf(state.transcript_buf) then
    return
  end

  vim.api.nvim_buf_clear_namespace(state.transcript_buf, transcript_ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(state.transcript_buf, 0, -1, false)
  local in_diff = false

  for index, line in ipairs(lines) do
    local lnum = index - 1

    if line == 'Approval Required' then
      vim.api.nvim_buf_add_highlight(state.transcript_buf, transcript_ns, 'WarningMsg', lnum, 0, -1)
    elseif line == 'Codex' or line == 'You' or line == 'System' then
      vim.api.nvim_buf_add_highlight(state.transcript_buf, transcript_ns, 'Title', lnum, 0, -1)
    end

    if line == '```diff' then
      in_diff = true
      vim.api.nvim_buf_add_highlight(state.transcript_buf, transcript_ns, 'Special', lnum, 0, -1)
    elseif line == '```' and in_diff then
      in_diff = false
      vim.api.nvim_buf_add_highlight(state.transcript_buf, transcript_ns, 'Special', lnum, 0, -1)
    elseif in_diff then
      local group
      if line:match('^%+') and not line:match('^%+%+%+') then
        group = 'DiffAdd'
      elseif line:match('^%-') and not line:match('^%-%-%-') then
        group = 'DiffDelete'
      elseif line:match('^@@') then
        group = 'DiffText'
      elseif line:match('^diff %-%-git') or line:match('^index ') or line:match('^%-%-%- ') or line:match('^%+%+%+ ') then
        group = 'Directory'
      end
      if group then
        vim.api.nvim_buf_add_highlight(state.transcript_buf, transcript_ns, group, lnum, 0, -1)
      end
    end
  end
end

local function set_window_options(win, opts)
  if not is_valid_win(win) then
    return
  end

  opts = opts or {}
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].foldcolumn = '0'
  vim.wo[win].spell = false
  vim.wo[win].wrap = opts.wrap ~= false
  vim.wo[win].cursorline = opts.cursorline == true
  vim.wo[win].winfixbuf = true
  vim.wo[win].winhighlight = 'Normal:Normal,NormalNC:Normal,EndOfBuffer:Normal,SignColumn:Normal'
end

local function status_label()
  if not state.ui_status or state.ui_status == '' then
    return ' Codex '
  end
  local prefix = ''
  if state.ui_status_animated then
    prefix = spinner_frames[state.ui_spinner_index] .. ' '
  end
  return ' Codex  %#String#' .. prefix .. state.ui_status .. '%* '
end

local function render_status()
  if is_valid_win(state.transcript_win) then
    vim.wo[state.transcript_win].winbar = status_label()
  end
end

local function stop_spinner()
  if state.ui_spinner_timer then
    state.ui_spinner_timer:stop()
    state.ui_spinner_timer:close()
    state.ui_spinner_timer = nil
  end
  state.ui_status_animated = false
  state.ui_spinner_index = 1
end

local function start_spinner()
  if state.ui_spinner_timer then
    return
  end

  state.ui_status_animated = true
  state.ui_spinner_timer = vim.uv.new_timer()
  state.ui_spinner_timer:start(0, 120, vim.schedule_wrap(function()
    state.ui_spinner_index = (state.ui_spinner_index % #spinner_frames) + 1
    render_status()
  end))
end

local function update_status(text, animated)
  state.ui_status = text or ''
  if animated then
    start_spinner()
  else
    stop_spinner()
  end
  render_status()
end

local function window_layout()
  local total_width = vim.o.columns
  local total_height = vim.o.lines - vim.o.cmdheight
  local margin = math.max(config.margin, 1)
  local width = math.max(math.floor(total_width * config.width), 64)
  local height = math.max(math.floor(total_height * config.height), 24)

  width = math.min(width, total_width - (margin * 2))
  height = math.min(height, total_height - (margin * 2))

  local row = margin
  local col = margin

  col = total_width - width - margin

  return {
    row = math.max(row, 0),
    col = math.max(col, 0),
    width = width,
    height = height,
  }
end

local function open_windows()
  local layout = window_layout()
  local total_height = vim.o.lines - vim.o.cmdheight
  local prompt_height = math.min(config.prompt_height, math.max(total_height - 8, 4))

  ensure_transcript_buf()
  ensure_prompt_buf()
  local source_win = find_source_win()
  if is_valid_win(source_win) then
    state.source_win = source_win
  end

  if not is_valid_win(state.transcript_win) or not is_valid_win(state.prompt_win) then
    close_window(state.prompt_win)
    close_window(state.transcript_win)
    state.prompt_win = nil
    state.transcript_win = nil

    if is_valid_win(state.source_win) then
      vim.api.nvim_set_current_win(state.source_win)
    end

    vim.cmd('botright vnew')
    state.prompt_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(state.prompt_win, state.prompt_buf)

    vim.cmd('aboveleft split')
    state.transcript_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(state.transcript_win, state.transcript_buf)
  end

  vim.api.nvim_win_set_width(state.transcript_win, layout.width)
  vim.api.nvim_win_set_width(state.prompt_win, layout.width)
  vim.api.nvim_win_set_height(state.prompt_win, prompt_height)
  vim.api.nvim_set_current_win(state.prompt_win)

  set_window_options(state.transcript_win, { wrap = true, cursorline = false })
  set_window_options(state.prompt_win, { wrap = true, cursorline = true })
  vim.wo[state.transcript_win].winbar = state.ui_status and state.ui_status ~= '' and (' ' .. state.ui_status .. ' ') or ''
  vim.wo[state.prompt_win].winbar = ''
  vim.wo[state.transcript_win].winfixwidth = true
  vim.wo[state.prompt_win].winfixwidth = true
end

close_window = function(win)
  if is_valid_win(win) then
    vim.api.nvim_win_close(win, true)
  end
end

local function normalize_lines(lines)
  local normalized = {}

  for _, line in ipairs(lines or {}) do
    local value = sanitize_text(line)
    local split = vim.split(value, '\n', { plain = true })

    if vim.tbl_isempty(split) then
      normalized[#normalized + 1] = ''
    else
      for _, part in ipairs(split) do
        normalized[#normalized + 1] = part
      end
    end
  end

  if vim.tbl_isempty(normalized) then
    return { '' }
  end

  return normalized
end

local function set_buf_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, normalize_lines(lines))
  vim.bo[buf].modifiable = false
end

local function transcript_set_lines(lines)
  ensure_transcript_buf()
  set_buf_lines(state.transcript_buf, lines)
  highlight_transcript()
  state.transcript.line_count = #lines
  if is_valid_win(state.transcript_win) then
    vim.api.nvim_win_set_cursor(state.transcript_win, { math.max(state.transcript.line_count, 1), 0 })
  end
end

local function transcript_lines()
  ensure_transcript_buf()
  return vim.api.nvim_buf_get_lines(state.transcript_buf, 0, -1, false)
end

local function transcript_append(lines)
  local current = transcript_lines()
  vim.list_extend(current, normalize_lines(lines))
  transcript_set_lines(current)
  return #current
end

find_source_win = function()
  local current = vim.api.nvim_get_current_win()
  local current_buf = vim.api.nvim_win_get_buf(current)
  if not is_plugin_buf(current_buf) then
    return current
  end

  if is_valid_win(state.source_win) then
    local source_buf = vim.api.nvim_win_get_buf(state.source_win)
    if not is_plugin_buf(source_buf) then
      return state.source_win
    end
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if not is_plugin_buf(buf) then
      return win
    end
  end

  return current
end

local function capture_selection(buf)
  local start_pos = vim.api.nvim_buf_get_mark(buf, '<')
  local end_pos = vim.api.nvim_buf_get_mark(buf, '>')
  if start_pos[1] == 0 or end_pos[1] == 0 then
    return nil
  end

  local start_row = start_pos[1] - 1
  local start_col = start_pos[2]
  local end_row = end_pos[1] - 1
  local end_col = end_pos[2] + 1

  local ok, text = pcall(vim.api.nvim_buf_get_text, buf, start_row, start_col, end_row, end_col, {})
  if not ok or not text or vim.tbl_isempty(text) then
    return nil
  end

  return {
    lines = trim_lines(text, config.max_attachment_lines),
    start_line = start_row + 1,
    start_col = start_col,
    end_line = end_row + 1,
    end_col = end_col,
  }
end

local function capture_buffer_excerpt(buf, cursor_line)
  local padding = 6
  local total = buf_line_count(buf)
  local start_line = math.max(cursor_line - padding, 1)
  local end_line = math.min(cursor_line + padding, total)
  local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
  return trim_lines(lines, config.max_attachment_lines)
end

local function snapshot_editor(kind)
  local win = find_source_win()
  state.source_win = win

  local buf = vim.api.nvim_win_get_buf(win)
  local path = vim.api.nvim_buf_get_name(buf)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local resolved_kind = kind or 'buffer'
  local snippet
  local range

  if resolved_kind == 'selection' then
    local selection = capture_selection(buf)
    if selection then
      snippet = selection.lines
      range = selection
    else
      resolved_kind = 'buffer'
    end
  end

  if resolved_kind ~= 'selection' then
    snippet = capture_buffer_excerpt(buf, cursor[1])
    resolved_kind = 'buffer'
  end

  return {
    kind = resolved_kind,
    abs_path = path,
    path = short_path(path),
    filetype = vim.bo[buf].filetype,
    cursor = { line = cursor[1], col = cursor[2] + 1 },
    range = range,
    lines = snippet,
  }
end

local function refresh_snapshot(kind)
  state.last_snapshot = snapshot_editor(kind)
end

local function attachment_id(kind, abs_path, range)
  local base = table.concat({ kind or 'attachment', abs_path or '', range and range.start_line or '', range and range.end_line or '' }, ':')
  return base
end

local function make_attachment(snapshot, label)
  return {
    id = attachment_id(snapshot.kind, snapshot.abs_path, snapshot.range),
    kind = snapshot.kind,
    label = label or snapshot.path,
    path = snapshot.path,
    abs_path = snapshot.abs_path,
    filetype = snapshot.filetype ~= '' and snapshot.filetype or 'text',
    lines = vim.deepcopy(snapshot.lines),
    cursor = snapshot.cursor,
    range = snapshot.range,
    source = 'explicit',
  }
end

local function add_attachment(attachment)
  for _, existing in ipairs(state.attachments) do
    if existing.id == attachment.id then
      return existing
    end
  end

  state.attachments[#state.attachments + 1] = attachment
  return attachment
end

local function clear_attachments()
  state.attachments = {}
end

local function attachment_lines(attachment)
  local lines = {
    ('Attachment: %s'):format(attachment.label),
    ('Path: %s'):format(attachment.path),
  }

  if attachment.source == 'implicit_active_buffer' then
    lines[#lines + 1] = 'Role: this is the active editor buffer currently open in Neovim'
  end

  if attachment.range then
    lines[#lines + 1] = ('Selection: lines %d-%d'):format(attachment.range.start_line, attachment.range.end_line)
  elseif attachment.cursor then
    lines[#lines + 1] = ('Cursor: line %d, column %d'):format(attachment.cursor.line, attachment.cursor.col)
  end

  lines[#lines + 1] = '```' .. attachment.filetype
  for _, line in ipairs(attachment.lines) do
    lines[#lines + 1] = line
  end
  lines[#lines + 1] = '```'
  return lines
end

local function build_turn_text(prompt, attachments, unresolved_mentions)
  local lines = {}
  local trimmed_prompt = trim_text(prompt)
  if trimmed_prompt ~= '' then
    for _, line in ipairs(vim.split(prompt, '\n', { plain = true })) do
      lines[#lines + 1] = line
    end
  else
    lines[#lines + 1] = 'Use the attached context.'
  end

  if unresolved_mentions and not vim.tbl_isempty(unresolved_mentions) then
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'Unresolved @ mentions: ' .. table.concat(unresolved_mentions, ', ')
  end

  if attachments and not vim.tbl_isempty(attachments) then
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'Attached editor context from Neovim:'
    lines[#lines + 1] = 'Treat these attachments as the live editor context, especially the active buffer if marked that way.'
    for _, attachment in ipairs(attachments) do
      lines[#lines + 1] = ''
      vim.list_extend(lines, attachment_lines(attachment))
    end
  end

  return table.concat(lines, '\n')
end

local function prompt_text()
  ensure_prompt_buf()
  return table.concat(vim.api.nvim_buf_get_lines(state.prompt_buf, 0, -1, false), '\n')
end

local function implicit_attachments()
  local snapshot = snapshot_editor('buffer')
  state.last_snapshot = snapshot

  if not snapshot or snapshot.path == '[No Name]' then
    return {}
  end

  local attachment = make_attachment(snapshot, snapshot.path)
  attachment.source = 'implicit_active_buffer'
  return { attachment }
end

local function clear_prompt()
  ensure_prompt_buf()
  vim.api.nvim_buf_set_lines(state.prompt_buf, 0, -1, false, { '' })
end

local function append_log(lines)
  transcript_append(normalize_lines(lines))
end

local function append_system(message)
  append_log({ '', 'System', message })
end

local function render_message_item(item_id)
  local item = state.transcript.active_messages[item_id]
  if not item then
    return
  end

  local all_lines = transcript_lines()
  local body = vim.split(item.text, '\n', { plain = true })
  if vim.tbl_isempty(body) then
    body = { '' }
  end

  local replacement = { item.header }
  vim.list_extend(replacement, body)

  local before = {}
  for i = 1, item.start_line - 1 do
    before[#before + 1] = all_lines[i]
  end

  local after = {}
  for i = item.end_line + 1, #all_lines do
    after[#after + 1] = all_lines[i]
  end

  local merged = before
  vim.list_extend(merged, replacement)
  vim.list_extend(merged, after)
  transcript_set_lines(merged)

  local delta = #replacement - (item.end_line - item.start_line + 1)
  item.end_line = item.start_line + #replacement - 1
  state.transcript.active_messages[item_id] = item

  if delta ~= 0 then
    for other_id, other in pairs(state.transcript.active_messages) do
      if other_id ~= item_id and other.start_line > item.start_line then
        other.start_line = other.start_line + delta
        other.end_line = other.end_line + delta
      end
    end
  end
end

local function focus_transcript()
  if is_valid_win(state.transcript_win) then
    vim.api.nvim_set_current_win(state.transcript_win)
  end
end

local function focus_prompt()
  if is_valid_win(state.prompt_win) then
    if is_valid_win(state.transcript_win) then
      vim.api.nvim_win_set_cursor(state.transcript_win, { math.max(state.transcript.line_count, 1), 0 })
    end
    vim.api.nvim_set_current_win(state.prompt_win)
    vim.cmd('startinsert')
  end
end

local function ensure_message_item(item_id, header)
  local existing = state.transcript.active_messages[item_id]
  if existing then
    return existing
  end

  local start = transcript_append({ '', header, '' }) - 2
  local item = {
    header = header,
    text = '',
    start_line = start,
    end_line = start + 2,
  }
  state.transcript.active_messages[item_id] = item
  return item
end

local function append_user_turn(prompt, attachments)
  local lines = { '', 'You' }
  local trimmed = trim_text(prompt)
  if trimmed ~= '' then
    vim.list_extend(lines, vim.split(prompt, '\n', { plain = true }))
  else
    lines[#lines + 1] = '[attachments only]'
  end

  transcript_append(lines)
end

local function next_request_id()
  state.session.request_id = state.session.request_id + 1
  return state.session.request_id
end

local function send_rpc(method, params, callback)
  local session = state.session
  if not session.job then
    if callback then
      callback(nil, 'Codex app-server is not running')
    end
    return
  end

  local id = next_request_id()
  if callback then
    session.pending[id] = callback
  end

  local payload = vim.json.encode({
    jsonrpc = '2.0',
    id = id,
    method = method,
    params = params,
  })
  vim.fn.chansend(session.job, payload .. '\n')
end

local function flush_initialize_queue()
  local queue = state.session.after_initialize
  state.session.after_initialize = {}
  for _, callback in ipairs(queue) do
    callback()
  end
end

local function flush_thread_queue()
  local queue = state.session.after_thread
  state.session.after_thread = {}
  for _, callback in ipairs(queue) do
    callback()
  end
end

local function append_server_error(prefix, error)
  local message = prefix
  if type(error) == 'table' then
    if error.message then
      message = prefix .. ': ' .. error.message
    else
      message = prefix .. ': ' .. vim.inspect(error)
    end
  elseif error then
    message = prefix .. ': ' .. tostring(error)
  end
  append_system(message)
  update_status('Error', false)
end

local function send_rpc_result(id, result)
  if not state.session.job then
    return
  end

  vim.fn.chansend(state.session.job, vim.json.encode({
    jsonrpc = '2.0',
    id = id,
    result = result,
  }) .. '\n')
end

local function handle_server_request(decoded)
  local method = decoded.method
  local params = decoded.params or {}
  local kind

  if method == 'item/commandExecution/requestApproval' then
    kind = 'command'
  elseif method == 'item/fileChange/requestApproval' then
    kind = 'file'
  elseif method == 'item/permissions/requestApproval' then
    kind = 'permissions'
  else
    append_system(('Unhandled Codex request: %s'):format(method))
    return
  end

  append_log(approval_lines(decoded))
  state.pending_approval = {
    id = decoded.id,
    kind = kind,
    params = params,
  }
  update_status('Approval Needed', false)
end

local function ensure_initialized(callback)
  local session = state.session
  if session.initialized then
    callback()
    return
  end

  session.after_initialize[#session.after_initialize + 1] = callback
  if session.initialize_sent then
    return
  end

  session.initialize_sent = true
  send_rpc('initialize', {
    clientInfo = {
      name = 'nvim-codex-panel',
      title = 'Codex Panel',
      version = '0.2.0',
    },
    capabilities = {
      experimentalApi = true,
    },
  }, function(result, error)
    if error then
      append_server_error('Codex initialize failed', error)
      return
    end
    session.initialized = true
    append_system('Codex app-server connected')
    update_status('Ready', false)
    flush_initialize_queue()
  end)
end

local function ensure_thread(callback)
  local session = state.session
  ensure_initialized(function()
    if session.thread_id then
      callback()
      return
    end

    session.after_thread[#session.after_thread + 1] = callback
    if #session.after_thread > 1 then
      return
    end

    local params = {
      cwd = vim.loop.cwd(),
      serviceName = 'nvim-codex-panel',
      ephemeral = false,
      personality = config.personality,
      experimentalRawEvents = false,
      persistExtendedHistory = true,
    }

    if config.approval_policy then
      params.approvalPolicy = config.approval_policy
    end
    if config.sandbox then
      params.sandbox = config.sandbox
    end

    send_rpc('thread/start', params, function(result, error)
      if error then
        append_server_error('Failed to start Codex thread', error)
        state.session.after_thread = {}
        return
      end

      session.thread_id = result.thread.id
      append_system(('Thread ready: %s'):format(result.thread.id))
      update_status('Ready', false)
      flush_thread_queue()
    end)
  end)
end

local function process_response(decoded)
  local callback = state.session.pending[decoded.id]
  if not callback then
    return
  end

  state.session.pending[decoded.id] = nil
  if decoded.error then
    callback(nil, decoded.error)
  else
    callback(decoded.result, nil)
  end
end

local function handle_notification(decoded)
  local method = decoded.method
  local params = decoded.params or {}

  if method == 'item/agentMessage/delta' then
    local item = ensure_message_item(params.itemId, 'Codex')
    item.text = item.text .. sanitize_text(params.delta or '')
    render_message_item(params.itemId)
    update_status('Answering…', true)
    return
  end

  if method == 'turn/started' then
    state.session.turn_running = true
    state.session.active_turn_id = params.turn and params.turn.id or state.session.active_turn_id
    update_status('Working…', true)
    return
  end

  if method == 'turn/completed' then
    state.session.turn_running = false
    state.session.active_turn_id = nil
    update_status('Ready', false)
    return
  end

  if method == 'thread/started' then
    if params.thread and params.thread.id then
      state.session.thread_id = params.thread.id
    end
    return
  end

  if method == 'thread/status/changed' then
    return
  end

  if method == 'item/started' or method == 'item/completed' then
    cache_file_change_item(params.item)
    return
  end

  if method == 'turn/diff/updated' then
    state.latest_turn_diff = sanitize_text(params.diff or '')
    if state.pending_approval and state.pending_approval.kind == 'file' then
      append_log({
        '',
        'Diff Updated',
        'Latest file-change diff received from Codex.',
      })
      append_log(approval_lines({
        method = 'item/fileChange/requestApproval',
        params = state.pending_approval.params,
      }))
    end
    return
  end

  if method == 'error' then
    local error = params.error or {}
    local suffix = params.willRetry and ' (retrying)' or ''
    append_system(('Codex error: %s%s'):format(error.message or 'unknown error', suffix))
    update_status('Error', false)
    return
  end

  if method:match('^codex/event/') then
    return
  end

  if method == 'item/reasoning/textDelta' then
    update_status('Thinking…', true)
    return
  end

  if method == 'item/reasoning/summaryTextDelta' or method == 'item/plan/delta' then
    update_status('Planning…', true)
    return
  end
end

local function process_line(line)
  line = sanitize_text(line)
  if line == '' then
    return
  end

  local ok, decoded = pcall(vim.json.decode, line)
  if not ok or type(decoded) ~= 'table' then
    append_system(line)
    return
  end

  decoded = normalize_decoded(decoded)

  if decoded.id ~= nil and decoded.method then
    handle_server_request(decoded)
    return
  end

  if decoded.id ~= nil then
    process_response(decoded)
    return
  end

  if decoded.method then
    handle_notification(decoded)
  end
end

local function process_stream(kind, data)
  local session = state.session
  local tail_key = kind == 'stdout' and 'stdout_tail' or 'stderr_tail'
  local pending = session[tail_key] or ''
  if not data or vim.tbl_isempty(data) then
    return
  end

  local chunks = vim.deepcopy(data)
  chunks[1] = pending .. (chunks[1] or '')

  local complete_count = #chunks
  if chunks[#chunks] ~= '' then
    session[tail_key] = chunks[#chunks]
    complete_count = #chunks - 1
  else
    session[tail_key] = ''
  end

  for index = 1, complete_count do
    local line = chunks[index]
    if line and line ~= '' then
      process_line(line:gsub('\r$', ''))
    end
  end
end

local function teardown_session()
  local session = state.session
  if session.job then
    pcall(vim.fn.jobstop, session.job)
  end

  state.session = {
    job = nil,
    initialized = false,
    initialize_sent = false,
    thread_id = nil,
    request_id = 0,
    pending = {},
    after_initialize = {},
    after_thread = {},
    stdout_tail = '',
    stderr_tail = '',
    active_turn_id = nil,
    turn_running = false,
  }
end

local function ensure_session()
  if state.session.job then
    return true
  end

  local ok, job = pcall(vim.fn.jobstart, config.app_server_cmd, {
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      vim.schedule(function()
        process_stream('stdout', data)
      end)
    end,
    on_stderr = function(_, data)
      vim.schedule(function()
        process_stream('stderr', data)
      end)
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if state.session.stdout_tail ~= '' then
          process_line(state.session.stdout_tail)
        end
        if state.session.stderr_tail ~= '' then
          process_line(state.session.stderr_tail)
        end
        append_system(('Codex app-server exited (%s)'):format(code))
        update_status('Offline', false)
        teardown_session()
      end)
    end,
  })

  if not ok or type(job) ~= 'number' or job <= 0 then
    append_system('Failed to start codex app-server')
    return false
  end

  state.session.job = job
  update_status('Starting…', true)
  ensure_initialized(function() end)
  return true
end

local function parse_mentions(prompt)
  local seen = {}
  local mentions = {}
  for token in prompt:gmatch('@([%w%._%-%/]+)') do
    if token ~= '' and not seen[token] then
      seen[token] = true
      mentions[#mentions + 1] = token
    end
  end
  return mentions
end

local function read_file_attachment(abs_path, label)
  local stat = vim.loop.fs_stat(abs_path)
  if not stat or stat.type ~= 'file' then
    return nil, ('Not a readable file: %s'):format(abs_path)
  end

  local ok, lines = pcall(vim.fn.readfile, abs_path, '', config.max_attachment_lines + 1)
  if not ok then
    return nil, ('Failed to read file: %s'):format(abs_path)
  end

  lines = trim_lines(lines, config.max_attachment_lines)
  return {
    id = attachment_id('file', abs_path),
    kind = 'file',
    label = label or short_path(abs_path),
    path = short_path(abs_path),
    abs_path = abs_path,
    filetype = vim.filetype.match({ filename = abs_path }) or vim.fn.fnamemodify(abs_path, ':e') or 'text',
    lines = lines,
    cursor = nil,
    range = nil,
  }, nil
end

local function fuzzy_search(query, callback)
  if not ensure_session() then
    callback(nil, 'Failed to start app-server')
    return
  end

  ensure_initialized(function()
    send_rpc('fuzzyFileSearch', {
      query = query,
      roots = { vim.loop.cwd() },
    }, function(result, error)
      if error then
        callback(nil, error)
        return
      end
      callback(result.files or {}, nil)
    end)
  end)
end

local function resolve_mentions(prompt, callback)
  local mentions = parse_mentions(prompt)
  if vim.tbl_isempty(mentions) then
    callback({}, {})
    return
  end

  local resolved = {}
  local unresolved = {}
  local index = 1

  local function step()
    local query = mentions[index]
    if not query then
      callback(resolved, unresolved)
      return
    end

    fuzzy_search(query, function(files, error)
      if error or not files or not files[1] then
        unresolved[#unresolved + 1] = '@' .. query
        index = index + 1
        step()
        return
      end

      local top = files[1]
      local abs_path = join_path(top.root, top.path)
      local attachment, read_error = read_file_attachment(abs_path, '@' .. query)
      if attachment then
        resolved[#resolved + 1] = attachment
      else
        unresolved[#unresolved + 1] = '@' .. query
        append_system(read_error)
      end
      index = index + 1
      step()
    end)
  end

  step()
end

local function merged_attachments(extra)
  local combined = {}
  local seen = {}

  local function add_many(items)
    for _, item in ipairs(items or {}) do
      if not seen[item.id] then
        seen[item.id] = true
        combined[#combined + 1] = item
      end
    end
  end

  add_many(state.attachments)
  add_many(extra)
  return combined
end

local function submit_approval_decision(decision)
  local approval = state.pending_approval
  if not approval then
    return false
  end

  state.pending_approval = nil
  clear_prompt()

  if approval.kind == 'permissions' then
    if decision == 'accept' then
      send_rpc_result(approval.id, { permissions = approval.params.permissions, scope = 'turn' })
    elseif decision == 'acceptForSession' then
      send_rpc_result(approval.id, { permissions = approval.params.permissions, scope = 'session' })
    else
      send_rpc_result(approval.id, { permissions = { network = nil, fileSystem = nil, macos = nil }, scope = 'turn' })
    end
  else
    send_rpc_result(approval.id, { decision = decision })
  end

  append_system(('Approval sent: %s'):format(decision))
  if decision == 'decline' then
    update_status('Waiting', false)
    if state.session.thread_id and state.session.active_turn_id then
      send_rpc('turn/interrupt', {
        threadId = state.session.thread_id,
        turnId = state.session.active_turn_id,
      }, function(_, error)
        if error then
          append_server_error('Interrupt after decline failed', error)
          return
        end
        append_system('Turn interrupted after decline')
      end)
    end
  else
    update_status('Working…', true)
  end
  focus_prompt()
  return true
end

local function send_prompt()
  local prompt = prompt_text()
  local trimmed = trim_text(prompt)
  local pending = vim.deepcopy(state.attachments)
  local use_implicit = vim.tbl_isempty(pending)

  if state.pending_approval then
    local decision = ({
      y = 'accept',
      yes = 'accept',
      a = 'acceptForSession',
      always = 'acceptForSession',
      n = 'decline',
      no = 'decline',
    })[(trimmed or ''):lower()]

    if not decision then
      append_system('Approval pending. Type y, a, or n and press Enter.')
      return
    end
    submit_approval_decision(decision)
    return
  end

  if trimmed == '' and vim.tbl_isempty(pending) then
    append_system('Nothing to send')
    return
  end

  if not ensure_session() then
    return
  end

  resolve_mentions(prompt, function(mention_attachments, unresolved_mentions)
    local all_attachments = merged_attachments(mention_attachments)
    if use_implicit and vim.tbl_isempty(all_attachments) then
      all_attachments = merged_attachments(implicit_attachments())
    end
    local payload = build_turn_text(prompt, all_attachments, unresolved_mentions)
    append_user_turn(prompt, all_attachments)
    clear_prompt()
    clear_attachments()

    ensure_thread(function()
      send_rpc('turn/start', {
        threadId = state.session.thread_id,
        input = {
          {
            type = 'text',
            text = payload,
          },
        },
      }, function(result, error)
        if error then
          append_server_error('Failed to start turn', error)
          return
        end

        state.session.turn_running = true
        state.session.active_turn_id = result.turn and result.turn.id or nil
      end)
    end)
  end)
end

local function attach_current(kind)
  local snapshot = snapshot_editor(kind)
  state.last_snapshot = snapshot
  add_attachment(make_attachment(snapshot))
end

local function attach_file_prompt()
  if not ensure_session() then
    return
  end

  vim.ui.input({ prompt = 'Attach file query: ' }, function(query)
    if not query or trim_text(query) == '' then
      return
    end

    fuzzy_search(query, function(files, error)
      if error then
        append_server_error('File search failed', error)
        return
      end

      if not files or not files[1] then
        append_system(('No files matched "%s"'):format(query))
        return
      end

      local choices = {}
      for i = 1, math.min(#files, 12) do
        local item = files[i]
        choices[#choices + 1] = {
          label = item.path,
          root = item.root,
          path = item.path,
        }
      end

      vim.ui.select(choices, {
        prompt = 'Attach file',
        format_item = function(item)
          return item.label
        end,
      }, function(choice)
        if not choice then
          return
        end

        local attachment, read_error = read_file_attachment(join_path(choice.root, choice.path))
        if not attachment then
          append_system(read_error)
          return
        end

        add_attachment(attachment)
        if is_valid_win(state.prompt_win) then
          vim.api.nvim_set_current_win(state.prompt_win)
          vim.cmd('startinsert')
        end
      end)
    end)
  end)
end

local function interrupt_turn()
  local session = state.session
  if not session.thread_id or not session.active_turn_id then
    append_system('No active turn to interrupt')
    return
  end

  send_rpc('turn/interrupt', {
    threadId = session.thread_id,
    turnId = session.active_turn_id,
  }, function(_, error)
    if error then
      append_server_error('Interrupt failed', error)
      return
    end
    append_system('Interrupt requested')
  end)
end

local function configure_prompt_keymaps()
  if not is_valid_buf(state.prompt_buf) then
    return
  end

  local opts = { buffer = state.prompt_buf, silent = true }
  vim.keymap.set('n', config.send_key, function()
    M.send()
  end, opts)
  vim.keymap.set({ 'n', 'i' }, '<Tab>', function()
    focus_transcript()
  end, opts)
  for lhs, decision in pairs({
    y = 'accept',
    a = 'acceptForSession',
    n = 'decline',
  }) do
    vim.keymap.set('i', lhs, function()
      if state.pending_approval then
        vim.schedule(function()
          submit_approval_decision(decision)
        end)
        return ''
      end
      return lhs
    end, { buffer = state.prompt_buf, silent = true, expr = true })
    vim.keymap.set('n', lhs, function()
      if state.pending_approval then
        submit_approval_decision(decision)
      else
        vim.api.nvim_feedkeys(lhs, 'n', false)
      end
    end, { buffer = state.prompt_buf, silent = true })
  end
  vim.keymap.set({ 'n', 'i' }, config.toggle_key, function()
    M.toggle()
  end, opts)
  vim.keymap.set({ 'n', 'i' }, config.attach_file_key, function()
    M.attach_file()
  end, opts)
  vim.keymap.set({ 'n', 'i' }, config.interrupt_key, function()
    M.interrupt()
  end, opts)
  vim.keymap.set({ 'n', 'i' }, config.quit_key, function()
    M.close()
  end, opts)

  if is_valid_buf(state.transcript_buf) then
    local transcript_opts = { buffer = state.transcript_buf, silent = true }
    vim.keymap.set('n', '<Tab>', function()
      focus_prompt()
    end, transcript_opts)
    vim.keymap.set('n', 'i', function()
      focus_prompt()
    end, transcript_opts)
  end
end

function M.open()
  open_windows()
  configure_prompt_keymaps()
  refresh_snapshot('buffer')
  if ensure_session() then
  end
  vim.api.nvim_set_current_win(state.prompt_win)
  vim.cmd('startinsert')
end

function M.close()
  close_window(state.prompt_win)
  close_window(state.transcript_win)
  state.prompt_win = nil
  state.transcript_win = nil
end

function M.toggle()
  if is_valid_win(state.prompt_win) then
    M.close()
  else
    M.open()
  end
end

function M.send()
  if not is_valid_win(state.prompt_win) then
    M.open()
  end
  send_prompt()
end

function M.attach_buffer()
  if not is_valid_win(state.prompt_win) then
    M.open()
  end
  attach_current('buffer')
end

function M.attach_selection()
  if not is_valid_win(state.prompt_win) then
    M.open()
  end
  attach_current('selection')
end

function M.attach_file()
  if not is_valid_win(state.prompt_win) then
    M.open()
  end
  attach_file_prompt()
end

function M.interrupt()
  interrupt_turn()
end

function M.setup(user_config)
  config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), user_config or {})

  vim.keymap.set({ 'n', 'i' }, config.toggle_key, function()
    M.toggle()
  end, { silent = true, desc = 'Toggle Codex popup' })

  vim.api.nvim_create_user_command('Codex', function()
    M.toggle()
  end, { desc = 'Toggle Codex popup' })

  vim.api.nvim_create_user_command('CodexToggle', function()
    M.toggle()
  end, { desc = 'Toggle Codex popup' })

  vim.api.nvim_create_user_command('CodexSend', function()
    M.send()
  end, { desc = 'Send the current Codex draft' })

  vim.api.nvim_create_user_command('CodexAttachFile', function()
    M.attach_file()
  end, { desc = 'Search and attach a file to Codex' })

  vim.api.nvim_create_user_command('CodexContext', function(command_opts)
    if command_opts.range > 0 then
      M.attach_selection()
    else
      M.attach_buffer()
    end
  end, { desc = 'Attach current editor context to Codex', range = true })

  vim.api.nvim_create_user_command('CodexInterrupt', function()
    M.interrupt()
  end, { desc = 'Interrupt the active Codex turn' })

  local group = vim.api.nvim_create_augroup('CodexPanelUi', { clear = true })
  vim.api.nvim_create_autocmd('VimResized', {
    group = group,
    callback = function()
      if is_valid_win(state.prompt_win) then
        open_windows()
      end
    end,
  })

  vim.api.nvim_create_autocmd({ 'BufEnter', 'WinEnter' }, {
    group = group,
    callback = function()
      local current_buf = vim.api.nvim_get_current_buf()
      if is_plugin_buf(current_buf) then
        return
      end
      state.source_win = vim.api.nvim_get_current_win()
      pcall(function()
        state.last_snapshot = snapshot_editor('buffer')
      end)
    end,
  })

  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      teardown_session()
    end,
  })
end

return M

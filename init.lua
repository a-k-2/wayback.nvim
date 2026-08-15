-- wayback.nvim
-- Diff any file (or directory) against a point in its Neovim undo history --
-- no git required. Reconstructs past content purely from persistent undofiles.

local M = {}

-- ============================================================================
-- Config
-- ============================================================================
M.config = {
  scan_window_secs = 24 * 3600, -- default: only look at the last 24h of undo history
  extensions = nil,             -- e.g. { "lua", "py" }; nil/empty = no filtering
  delta_cmd = "delta --paging=always "
    .. "--file-style=omit --file-decoration-style=omit "
    .. "--hunk-header-style=omit --hunk-header-decoration-style=omit "
    .. "--line-numbers",
}

local did_setup = false

-- ============================================================================
-- Helpers
-- ============================================================================
local function shell(cmd)
  local h = io.popen(cmd)
  if not h then return nil end
  local out = h:read("*a")
  h:close()
  return out
end

local function parse_time_arg(arg)
  if not arg or arg == "" then return nil end
  local num, unit = arg:match("^(%d+)([smhd])$")
  if num then
    local mult = ({ s = 1, m = 60, h = 3600, d = 86400 })[unit]
    return os.time() - (tonumber(num) * mult)
  end
  local out = shell(string.format("date -d %s +%%s 2>/dev/null", vim.fn.shellescape(arg)))
  if out and out:match("^%d+") then return tonumber(out) end
  return nil
end

local function parse_duration_secs(arg)
  if not arg or arg == "" then return nil end
  local num, unit = arg:match("^(%d+)([smhd])$")
  if not num then return nil end
  local mult = ({ s = 1, m = 60, h = 3600, d = 86400 })[unit]
  return tonumber(num) * mult
end

local function ext_allowed(filepath, extensions)
  if not extensions or #extensions == 0 then return true end
  local ext = vim.fn.fnamemodify(filepath, ":e")
  for _, e in ipairs(extensions) do
    if ext == e then return true end
  end
  return false
end

local function collect_files(paths, extensions)
  paths = (paths and #paths > 0) and paths or { "." }
  local exclude = "-not -path '*/.git/*' -not -path '*/node_modules/*' "
    .. "-not -path '*/.venv/*' -not -path '*/venv/*' -not -path '*/dist/*' "
    .. "-not -path '*/build/*' -not -path '*/target/*' -not -path '*/.cache/*'"
  local files = {}
  for _, p in ipairs(paths) do
    local stat = vim.uv.fs_stat(p)
    if stat and stat.type == "directory" then
      local h = io.popen(string.format("find %s -type f %s", vim.fn.shellescape(p), exclude))
      if h then
        for line in h:lines() do
          local f = vim.fn.fnamemodify(line, ":p")
          if ext_allowed(f, extensions) then table.insert(files, f) end
        end
        h:close()
      end
    elseif stat and stat.type == "file" then
      if ext_allowed(p, extensions) then table.insert(files, vim.fn.fnamemodify(p, ":p")) end
    end
  end
  return files
end

-- Keep undo entries within [now-window, now], plus one older "anchor" entry
-- per file so we always have a correct base state to reconstruct/diff from.
local function get_undo_entries(filepath, window_secs)
  local entries, older = {}, nil
  local cutoff = os.time() - window_secs
  pcall(function()
    local bufnr = vim.fn.bufadd(filepath)
    vim.fn.bufload(bufnr)
    local ut = vim.api.nvim_buf_call(bufnr, function() return vim.fn.undotree() end)
    local function walk(list)
      for _, node in ipairs(list) do
        if node.time >= cutoff then
          table.insert(entries, { file = filepath, seq = node.seq, time = node.time })
        elseif not older or node.time > older.time then
          older = { file = filepath, seq = node.seq, time = node.time }
        end
        if node.alt then walk(node.alt) end
      end
    end
    if ut and ut.entries then walk(ut.entries) end
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
  if older then table.insert(entries, older) end
  return entries
end

local function content_at_seq(filepath, seq)
  local lines = nil
  pcall(function()
    local bufnr = vim.fn.bufadd(filepath)
    vim.fn.bufload(bufnr)
    vim.api.nvim_buf_call(bufnr, function() pcall(vim.cmd, "silent undo " .. seq) end)
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
  return lines
end

local function seq_at_time(entries, target_time)
  local best = nil
  for _, e in ipairs(entries) do
    if e.time <= target_time and (not best or e.time > best.time) then best = e end
  end
  return best and best.seq or 0
end

local function human_ago(s)
  if s < 60 then return s .. "s ago" end
  if s < 3600 then return math.floor(s / 60) .. "m ago" end

  local d = math.floor(s / 86400)
  local h = math.floor((s % 86400) / 3600)
  local m = math.floor((s % 3600) / 60)

  local parts = {}
  if d > 0 then table.insert(parts, d .. "d") end
  if h > 0 or d > 0 then table.insert(parts, h .. "h") end
  table.insert(parts, m .. "m") -- always show minutes once we're at 1h+

  return table.concat(parts, " ") .. " ago"
end

-- returns unified diff text, added count, removed count, changed count
-- (changed = number of paired modified lines = min(added, removed))
local function file_diff(filepath, old_lines)
  local current = vim.fn.readfile(filepath)
  local old_text = table.concat(old_lines, "\n") .. "\n"
  local new_text = table.concat(current, "\n") .. "\n"
  if old_text == new_text then return nil end
  local rel = vim.fn.fnamemodify(filepath, ":.")
  local diff = vim.diff(old_text, new_text, { result_type = "unified", ctxlen = 3 })
  if not diff or diff == "" then return nil end

  local added, removed = 0, 0
  for line in diff:gmatch("[^\n]+") do
    if line:sub(1, 1) == "+" and line:sub(1, 3) ~= "+++" then
      added = added + 1
    elseif line:sub(1, 1) == "-" and line:sub(1, 3) ~= "---" then
      removed = removed + 1
    end
  end
  local changed = math.min(added, removed)

  local text = string.format("--- a/%s\n+++ b/%s\n%s", rel, rel, diff)
  return text, added, removed, changed
end

-- ============================================================================
-- Diff display (reused across "switch to another time")
-- ============================================================================
local diff_state = { win = nil, buf = nil }

function M.show_diff(diff_text, reopen_picker_fn)
  if diff_state.win and vim.api.nvim_win_is_valid(diff_state.win) then
    vim.api.nvim_set_current_win(diff_state.win)
  else
    vim.cmd("botright new")
    diff_state.win = vim.api.nvim_get_current_win()
  end

  local tmp = vim.fn.tempname()
  vim.fn.writefile(vim.split(diff_text, "\n"), tmp)

  vim.fn.termopen(string.format("%s < %s", M.config.delta_cmd, vim.fn.shellescape(tmp)))
  diff_state.buf = vim.api.nvim_get_current_buf()

  if reopen_picker_fn then
    vim.keymap.set("n", "t", reopen_picker_fn, { buffer = diff_state.buf, desc = "Switch point in time" })
  end
  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(diff_state.win) then vim.api.nvim_win_close(diff_state.win, true) end
  end, { buffer = diff_state.buf, desc = "Close diff" })

  vim.cmd("startinsert")
end

-- ============================================================================
-- Scan (builds per_file_entries) -- factored out so it can be re-run with a
-- bigger window on demand (via 'R' in the picker); default stays fast.
-- ============================================================================
local function scan(paths, extensions, window_secs)
  local files = collect_files(paths, extensions)
  vim.notify(string.format("wayback: scanning %d files (last %dh of undo history)...", #files, window_secs / 3600))
  vim.cmd("redraw")

  local per_file_entries = {}
  for i, f in ipairs(files) do
    if i % 20 == 0 then
      vim.notify(string.format("wayback: %d/%d: %s", i, #files, vim.fn.fnamemodify(f, ":t")))
      vim.cmd("redraw")
    end
    local entries = get_undo_entries(f, window_secs)
    if #entries > 0 then per_file_entries[f] = entries end
  end
  vim.notify(string.format("wayback: done. %d files touched in the last %dh.", vim.tbl_count(per_file_entries), window_secs / 3600))
  return per_file_entries
end

-- ============================================================================
-- Shared: diff one file at one point in time, then show it (with 't' to
-- switch to a different time afterward without rescanning).
-- ============================================================================
local function diff_one(filepath, target_time, per_file_entries, window_secs, paths, extensions)
  local entries = per_file_entries[filepath]
  if not entries then return end
  local seq = seq_at_time(entries, target_time)
  local old_lines = content_at_seq(filepath, seq)
  if not old_lines then
    vim.notify("wayback: could not reconstruct file content.", vim.log.levels.WARN)
    return
  end
  local d = file_diff(filepath, old_lines)
  if not d then
    vim.notify("wayback: no changes at that point in time.", vim.log.levels.INFO)
    return
  end
  M.show_diff(d, function() M.open_picker(per_file_entries, window_secs, paths, extensions) end)
end

-- ============================================================================
-- Main
-- ============================================================================
function M.run(opts)
  opts = opts or {}
  local extensions = opts.extensions or M.config.extensions
  local window_secs = opts.scan_window_secs or M.config.scan_window_secs
  local paths = opts.paths

  local per_file_entries = scan(paths, extensions, window_secs)

  if opts.time then
    local t = parse_time_arg(opts.time)
    if not t then
      vim.notify("wayback: could not parse time: " .. opts.time, vim.log.levels.ERROR)
      return
    end
    -- direct mode: diff every scanned file at this time, concatenated
    local parts = {}
    for f, entries in pairs(per_file_entries) do
      local seq = seq_at_time(entries, t)
      local old_lines = content_at_seq(f, seq)
      if old_lines then
        local d = file_diff(f, old_lines)
        if d then table.insert(parts, d) end
      end
    end
    if #parts == 0 then
      vim.notify("wayback: no changes found for that point in time.", vim.log.levels.INFO)
      return
    end
    M.show_diff(table.concat(parts, "\n"), function() M.open_picker(per_file_entries, window_secs, paths, extensions) end)
    return
  end

  M.open_picker(per_file_entries, window_secs, paths, extensions)
end

-- ============================================================================
-- Picker: one row per (file, timestamp), sorted by time desc, showing
-- filename + added/removed/changed counts. Preview shows that file's diff.
-- 'R' explicitly rescans with a larger, user-provided window (opt-in only,
-- so the default stays fast).
-- ============================================================================
function M.open_picker(per_file_entries, window_secs, paths, extensions)
  local now = os.time()
  local rows = {}

  for f, entries in pairs(per_file_entries) do
    for _, e in ipairs(entries) do
      if e.time >= now - window_secs then
        local old_lines = content_at_seq(f, e.seq)
        if old_lines then
          local _, added, removed, changed = file_diff(f, old_lines)
          if added and (added > 0 or removed > 0) then
            table.insert(rows, {
              file = f,
              rel = vim.fn.fnamemodify(f, ":."),
              time = e.time,
              ago = now - e.time,
              added = added,
              removed = removed,
              changed = changed,
            })
          end
        end
      end
    end
  end

  table.sort(rows, function(a, b) return a.time > b.time end)

  if #rows == 0 then
    vim.notify("wayback: no changes found in the scanned window.", vim.log.levels.INFO)
    return
  end

  local ok_telescope = pcall(require, "telescope")
  if not ok_telescope then
    vim.notify("wayback: telescope.nvim is required for the picker UI.", vim.log.levels.ERROR)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")
  local entry_display = require("telescope.pickers.entry_display")

  local displayer = entry_display.create({
    separator = " ",
    items = {
      { width = 16 }, -- ago
      { width = 19 }, -- absolute time
      { width = 40 }, -- filename
      { remaining = true }, -- +/- stats
    },
  })

  local previewer = previewers.new_buffer_previewer({
    title = "Diff",
    define_preview = function(self, entry)
      local r = entry.value
      local old_lines = content_at_seq(r.file, seq_at_time(per_file_entries[r.file], r.time))
      local lines = { "(no diff)" }
      if old_lines then
        local d = file_diff(r.file, old_lines)
        if d then lines = vim.split(d, "\n") end
      end
      vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
      vim.bo[self.state.bufnr].filetype = "diff"
    end,
  })

  pickers.new({}, {
    prompt_title = string.format("wayback: changes (last %dh) -- <CR> diff, R rescan further back", window_secs / 3600),
    finder = finders.new_table({
      results = rows,
      entry_maker = function(r)
        return {
          value = r,
          ordinal = r.rel .. " " .. human_ago(r.ago),
          display = function(entry)
            local rr = entry.value
            local hl = rr.ago >= 86400 and "Comment" or rr.ago >= 3600 and "WarningMsg" or "Normal"
            local stats = string.format("+%d -%d ~%d", rr.added, rr.removed, rr.changed)
            return displayer({
              { human_ago(rr.ago), hl },
              { os.date("%Y-%m-%d %H:%M:%S", rr.time), hl },
              { rr.rel, "Identifier" },
              { stats, "DiffText" },
            })
          end,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = previewer,
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        local selection = action_state.get_selected_entry()
        if not selection then
          vim.notify("wayback: no entry selected.", vim.log.levels.WARN)
          return
        end
        actions.close(prompt_bufnr)
        diff_one(selection.value.file, selection.value.time, per_file_entries, window_secs, paths, extensions)
      end)
      map("n", "R", function()
        actions.close(prompt_bufnr)
        vim.ui.input({ prompt = "Rescan how far back? (e.g. 3d, 7d): " }, function(input)
          local secs = parse_duration_secs(input)
          if not secs then
            vim.notify("wayback: invalid duration, expected e.g. '3d' or '12h'.", vim.log.levels.ERROR)
            return
          end
          local new_entries = scan(paths, extensions, secs)
          M.open_picker(new_entries, secs, paths, extensions)
        end)
      end, { desc = "Rescan further back (explicit)" })
      return true
    end,
  }):find()
end

-- ============================================================================
-- Setup / commands
-- ============================================================================
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  if did_setup then return end
  did_setup = true

  vim.api.nvim_create_user_command("WaybackDiff", function(cmd_opts)
    M.run({
      time = cmd_opts.args ~= "" and cmd_opts.args or nil,
      paths = { vim.fn.expand("%:p") },
    })
  end, { nargs = "?", desc = "WaybackDiff [time]  -- diff current buffer to a point in time (last 24h by default)" })

  vim.api.nvim_create_user_command("WaybackDirDiff", function(cmd_opts)
    M.run({
      paths = cmd_opts.args ~= "" and { cmd_opts.args } or nil,
    })
  end, { nargs = "?", complete = "file", desc = "WaybackDirDiff [path]  -- browse changes in the last 24h (picker); press R inside to go further back" })
end

return M

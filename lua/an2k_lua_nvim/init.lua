-- Neovim buffer integration: open ANSI/NIST-ITL files as an editable text view.

local an2k = require("an2k")
local view = require("an2k_lua_nvim.view")
local parse = require("an2k_lua_nvim.parse")
local image = require("an2k_lua_nvim.image")

local M = {}

-- Per-buffer model the view was rendered from (needed for binary payloads).
local models = {}

local ns = vim.api.nvim_create_namespace("an2k")

local function notify_err(msg)
  vim.notify("an2k: " .. msg, vim.log.levels.ERROR)
end

local function set_lines(buf, lines)
  local undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1 -- loading isn't an undoable change
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].undolevels = undolevels
  vim.bo[buf].modified = false
end

local function render(buf, file)
  models[buf] = file
  vim.diagnostic.reset(ns, buf)
  set_lines(buf, view.render(file))
end

-- Record index and record under the cursor (nil for new or unknown records).
local function record_at_cursor(buf)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(buf, 0, lnum, false)
  for i = #lines, 1, -1 do
    local index = lines[i]:match(view.HEADER)
    if index then
      local n = tonumber(index)
      return n, n and models[buf] and models[buf].records[n]
    end
  end
end

local function payload_at_cursor(buf)
  local n, record = record_at_cursor(buf)
  if not record then
    notify_err("cursor is not in a record loaded from the file (save first)")
    return
  end
  local data
  if record.tagged then
    data = an2k.get_value(record, 999)
  else
    data = record.data
  end
  if not data or #data == 0 then
    notify_err(string.format("record %d (Type-%d) has no image data", n, record.type))
    return
  end
  return data, n, record
end

-- Uncompressed grayscale payloads become a PNG; everything else is shown as-is.
local function viewable(record, data)
  if image.detect(data) then
    return data
  end
  if not record.tagged then
    local h = record.header
    if h.gca == 0 and (record.type == 3 or record.type == 4) then
      return image.raw_to_png(data, h.hll, h.vll, 8) or data
    elseif h.gca == 0 and (record.type == 5 or record.type == 6) then
      -- Binary (1 bpp) by definition, but some writers store 8-bit grayscale.
      return image.raw_to_png(data, h.hll, h.vll, 1, true) or image.raw_to_png(data, h.hll, h.vll, 8) or data
    end
    return data
  end
  local cga = an2k.get_value(record, 11)
  if record.type >= 13 and record.type <= 16 and (cga == "NONE" or cga == "0") then
    local w, h = tonumber(an2k.get_value(record, 6)), tonumber(an2k.get_value(record, 7))
    local depth = tonumber(an2k.get_value(record, 12) or "8")
    if w and h and (depth == 8 or depth == 1) then
      return image.raw_to_png(data, w, h, depth) or data
    end
  end
  return data
end

M.viewable = viewable

local function jump(pattern, flags)
  for _ = 1, vim.v.count1 do
    vim.fn.search(pattern, flags .. "W")
  end
end

---------------------------------------------------------------------------
-- Validation as diagnostics.

-- Buffer line (0-based) for each record header and tagged field, by record order.
local function line_map(lines)
  local headers, fields, types = {}, {}, {}
  for i, line in ipairs(lines) do
    local _, rtype = line:match(view.HEADER)
    if rtype then
      headers[#headers + 1] = i - 1
      types[#headers] = tonumber(rtype)
      fields[#headers] = {}
    elseif #headers > 0 then
      local num = line:match("^%d+%.(%d+)")
      if num then
        fields[#headers][tonumber(num)] = fields[#headers][tonumber(num)] or i - 1
      end
    end
  end
  return headers, fields, types
end

local function error_line(e, headers, fields, types)
  local ri = e.record_index
  if not ri and e.record_type then
    for k, t in ipairs(types) do
      if t == e.record_type then
        ri = k
        break
      end
    end
  end
  ri = ri or 1
  return (e.field_number and fields[ri] and fields[ri][e.field_number]) or headers[ri] or 0
end

-- Validates the buffer as `:w` would write it.  `name` is a profile from
-- an2k.profiles.names, or "none" for structural checks only.  Returns true when valid.
function M.validate_buffer(buf, name)
  local profile
  if name ~= "none" then
    profile = an2k.profiles[name]
    if not profile then
      notify_err(string.format("unknown profile '%s' (have: none, %s)", name, table.concat(an2k.profiles.names, ", ")))
      return false
    end
  end
  vim.b[buf].an2k_profile = name
  vim.diagnostic.reset(ns, buf)
  local orig = models[buf]
  if not orig then
    notify_err("buffer was not loaded from a valid file")
    return false
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local file, err = parse.parse(lines, orig)
  if file then
    -- Syncs LEN and CNT into the model, exactly as a write would.
    local _, werr = an2k.write_string(file)
    err = werr
  end
  if err then
    local lnum = tonumber(err:match("^line (%d+):"))
    vim.diagnostic.set(ns, buf, { { lnum = (lnum or 1) - 1, col = 0, severity = vim.diagnostic.severity.ERROR, message = err, source = "an2k" } })
    return false
  end

  local ok, errors = an2k.validate(file, profile)
  local label = profile and profile.name or "structure"
  if ok then
    vim.api.nvim_echo({ { "an2k: valid against " .. label } }, false, {})
    return true
  end
  local headers, fields, types = line_map(lines)
  local diags = {}
  for _, e in ipairs(errors) do
    diags[#diags + 1] = {
      lnum = error_line(e, headers, fields, types),
      col = 0,
      severity = vim.diagnostic.severity.ERROR,
      message = e.detail,
      code = e.code,
      source = "an2k " .. label,
    }
  end
  vim.diagnostic.set(ns, buf, diags)
  vim.api.nvim_echo({ { string.format("an2k: %d problem(s) against %s", #errors, label), "WarningMsg" } }, false, {})
  return false
end

function M.foldexpr(lnum)
  return vim.fn.getline(lnum):match("^== Record ") and ">1" or "="
end

local function setup_buffer(buf)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "eft"
  local map = function(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, desc = "an2k: " .. desc })
  end
  map("i", "<M-i>", "␟", "insert item separator")
  map("i", "<M-s>", "␞", "insert subfield separator")
  map({ "n", "x", "o" }, "]]", function() jump("^== Record ", "") end, "next record")
  map({ "n", "x", "o" }, "[[", function() jump("^== Record ", "b") end, "previous record")
  map("n", "gi", function()
    local data, n, record = payload_at_cursor(buf)
    if data then
      image.show(viewable(record, data), string.format("Record %d: Type-%d", n, record.type))
    end
  end, "show image")
  map("n", "ge", function()
    local data, n = payload_at_cursor(buf)
    if data then
      local stem = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t:r") .. ".rec" .. n
      image.extract(data, stem)
    end
  end, "extract payload")
  vim.api.nvim_buf_create_user_command(buf, "EftValidate", function(cmd)
    local name = cmd.args ~= "" and cmd.args or vim.b[buf].an2k_profile or vim.g.an2k_profile or "none"
    M.validate_buffer(buf, name)
  end, {
    nargs = "?",
    complete = function()
      return vim.list_extend({ "none" }, vim.deepcopy(an2k.profiles.names))
    end,
    desc = "an2k: validate against a profile (diagnostics)",
  })
  -- setup runs again on :e, so keep this buffer's autocmds in a group that is cleared each time.
  local group = vim.api.nvim_create_augroup("an2k_buf_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    buffer = buf,
    callback = function()
      vim.wo.foldmethod = "expr"
      vim.wo.foldexpr = "v:lua.require'an2k_lua_nvim'.foldexpr(v:lnum)"
      vim.wo.foldlevel = 99
    end,
  })
  -- Buffer-local so `:w any/path` works, not only paths matching the read patterns.
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = buf,
    callback = function(ev)
      M.write(buf, ev.match)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function() models[buf] = nil end,
  })
end

function M.read(buf, path)
  local file, err = an2k.read_file(path)
  setup_buffer(buf)
  if not file then
    models[buf] = nil
    set_lines(buf, { "# Not a readable ANSI/NIST-ITL file:", "# " .. tostring(err) })
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true
    return notify_err(err)
  end
  render(buf, file)
end

-- Writes the buffer to `path`.  Returns true on success.
function M.write(buf, path)
  local orig = models[buf]
  if not orig then
    notify_err("buffer was not loaded from a valid file; refusing to write")
    return false
  end
  local file, err = parse.parse(vim.api.nvim_buf_get_lines(buf, 0, -1, false), orig)
  if not file then
    notify_err(err)
    return false
  end
  local bytes
  bytes, err = an2k.write_string(file)
  if not bytes then
    notify_err(err)
    return false
  end
  -- Re-read what we produced so the view shows fresh LEN/CNT (and proves it parses).
  local again
  again, err = an2k.read_string(bytes)
  if not again then
    notify_err("refusing to write a file an2k can't read back: " .. err)
    return false
  end
  local fh
  fh, err = io.open(path, "wb")
  if not fh then
    notify_err(err)
    return false
  end
  fh:write(bytes)
  fh:close()

  local same_file = vim.fn.fnamemodify(path, ":p") == vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":p")
  if same_file then
    local view_state = vim.fn.winsaveview()
    render(buf, again)
    vim.fn.winrestview(view_state)
  end
  vim.api.nvim_echo({ { string.format('"%s" %d records, %dB written', path, #again.records, #bytes) } }, false, {})
  -- Keep diagnostics current once the buffer has been validated.
  if same_file and vim.b[buf].an2k_profile then
    M.validate_buffer(buf, vim.b[buf].an2k_profile)
  end
  return true
end

-- "*.eft" -> "*.[eE][fF][tT]": autocmd patterns are case-sensitive on Linux,
-- and EFTs often arrive as "*.EFT".
local function ignore_case(pattern)
  return (pattern:gsub("%a", function(c) return "[" .. c:lower() .. c:upper() .. "]" end))
end

function M.setup(patterns)
  local group = vim.api.nvim_create_augroup("an2k", { clear = true })
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = vim.tbl_map(ignore_case, patterns),
    callback = function(ev)
      M.read(ev.buf, ev.match)
    end,
  })
end

return M

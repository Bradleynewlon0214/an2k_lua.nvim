-- Tests for the Neovim view/editor.  Usage (from the repo root):  nvim -l test/spec.lua
-- Needs the an2k_lua library checked out at ../an2k_lua (or ../lua-an2k), or set AN2K_PATH.

local AN2K = os.getenv("AN2K_PATH") or (vim.fn.isdirectory("../an2k_lua") == 1 and "../an2k_lua" or "../lua-an2k")
package.path = "./lua/?.lua;./lua/?/init.lua;" .. AN2K .. "/lua/?.lua;" .. AN2K .. "/lua/?/init.lua;" .. package.path
vim.opt.rtp:prepend(AN2K)
vim.opt.rtp:prepend(".")

local an2k = require("an2k")
local view = require("an2k_lua_nvim.view")
local parse = require("an2k_lua_nvim.parse")
local text = require("an2k_lua_nvim.text")
local plugin = require("an2k_lua_nvim")

local FIXTURES = AN2K .. "/test/fixtures/"
local passed, failed = 0, 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    io.write("FAIL ", name, "\n    ", tostring(err), "\n")
  end
end

local function eq(a, b, what)
  if a ~= b then
    error(string.format("%s: expected %s, got %s", what or "value", vim.inspect(b), vim.inspect(a)), 2)
  end
end

local function slurp(path)
  local fh = assert(io.open(path, "rb"))
  local s = fh:read("*a")
  fh:close()
  return s
end

-- Render, apply `edit` to the lines, parse back, write, and re-read.
local function edit_roundtrip(name, edit)
  local orig = assert(an2k.read_file(FIXTURES .. name))
  local lines = view.render(orig)
  edit(lines)
  local file = assert(parse.parse(lines, orig))
  local bytes = assert(an2k.write_string(file))
  return assert(an2k.read_string(bytes)), bytes
end

local function find_line(lines, prefix)
  for i, l in ipairs(lines) do
    if l:sub(1, #prefix) == prefix then
      return i
    end
  end
  error("no line starting with " .. prefix, 2)
end

---------------------------------------------------------------------------

for _, name in ipairs(vim.fn.readdir(FIXTURES)) do
  test("view round-trip " .. name, function()
    local src = slurp(FIXTURES .. name)
    local orig = assert(an2k.read_string(src))
    local file = assert(parse.parse(view.render(orig), orig))
    local out = assert(an2k.write_string(file))
    assert(out == src, "bytes differ")
  end)
end

test("escaping round-trips awkward values", function()
  for _, s in ipairs({ "", "plain", "back\\slash", "tab\there\nnl", "\0\1\127", "caf\195\169", "lat\233n1", "\226\144\158\226\144\159", "\\x41" }) do
    local back = assert(text.unescape(text.escape(s)))
    eq(back, s, "escape " .. vim.inspect(s))
    assert(not text.escape(s):find("[%z\1-\31]"), "escaped text has no control bytes")
  end
  local subs = { { "a", "b" }, { "", "c\30d" } }
  local back = assert(text.parse_subfields(text.format_subfields(subs)))
  eq(vim.inspect(back), vim.inspect(subs), "subfields")
end)

test("edit a value", function()
  local file = edit_roundtrip("valid1.1.an2", function(lines)
    lines[find_line(lines, "2.018")] = "2.018 [NAM] = DOE,JANE␞SMITH,JOHN"
  end)
  local f = an2k.get_field(file.records[2], 18)
  eq(f.subfields[1][1], "DOE,JANE", "first subfield")
  eq(f.subfields[2][1], "SMITH,JOHN", "second subfield")
end)

test("add a field without a mnemonic, keep numeric position as typed", function()
  local file = edit_roundtrip("valid1.1.an2", function(lines)
    table.insert(lines, find_line(lines, "2.018") + 1, "2.019 = ALIAS")
  end)
  eq(an2k.get_value(file.records[2], 19), "ALIAS", "2.019")
end)

test("empty value with trailing whitespace stripped", function()
  local file = edit_roundtrip("valid1.1.an2", function(lines)
    lines[find_line(lines, "2.018")] = "2.018 [NAM] ="
  end)
  eq(an2k.get_value(file.records[2], 18), "", "2.018")
end)

test("delete a field", function()
  local file = edit_roundtrip("valid1.1.an2", function(lines)
    table.remove(lines, find_line(lines, "2.018"))
  end)
  eq(an2k.get_field(file.records[2], 18), nil, "2.018 gone")
end)

test("delete a record block updates CNT", function()
  local file = edit_roundtrip("valid1.1.an2", function(lines)
    local start = find_line(lines, "== Record 3:")
    while lines[start] do
      table.remove(lines, start)
    end
  end)
  eq(#file.records, 2, "records")
  eq(an2k.get_field(file.records[1], 3).subfields[1][2], "1", "CNT count")
end)

test("add a new tagged record", function()
  local file = edit_roundtrip("valid1.1.an2", function(lines)
    vim.list_extend(lines, { "== Record new: Type-9 ==", "9.002 = 05", "9.004 = U" })
  end)
  eq(#file.records, 4, "records")
  eq(file.records[4].type, 9, "type")
  eq(an2k.get_value(file.records[4], 4), "U", "9.004")
  eq(an2k.get_field(file.records[1], 3).subfields[4][2], "05", "CNT IDC")
end)

test("edit binary header", function()
  local file = edit_roundtrip("valid1.1.an2", function(lines)
    local start = find_line(lines, "== Record 3:")
    for i = start, #lines do
      if lines[i]:match("^%s+fgp") then
        lines[i] = "  fgp = 7 255 255 255 255 255"
      end
    end
  end)
  eq(file.records[3].header.fgp[1], 7, "fgp")
end)

test("image placeholder keeps payload", function()
  local orig = assert(an2k.read_file(FIXTURES .. "face_jpb_DOM_GMT_DCS.an2"))
  local lines = view.render(orig)
  local l = lines[find_line(lines, "10.999")]
  assert(l:find("<%d+ bytes, JPEG>"), l)
end)

local function expect_error(name, edit, pattern)
  test("error: " .. name, function()
    local orig = assert(an2k.read_file(FIXTURES .. "valid1.1.an2"))
    local lines = view.render(orig)
    edit(lines)
    local file, err = parse.parse(lines, orig)
    assert(file == nil, "expected failure")
    assert(err:find(pattern), "unexpected error: " .. err)
  end)
end

expect_error("garbage line", function(lines) table.insert(lines, 5, "hello") end, "^line 5:")
expect_error("wrong record type for tag", function(lines)
  lines[find_line(lines, "2.018")] = "3.018 = X"
end, "in a Type%-2 record")
expect_error("duplicate field", function(lines)
  table.insert(lines, find_line(lines, "2.018"), "2.018 = X")
end, "repeats")
expect_error("bad escape", function(lines)
  lines[find_line(lines, "2.018")] = "2.018 = a\\qb"
end, "bad escape")
expect_error("editing binary data", function(lines)
  local i = find_line(lines, "  data =")
  lines[i] = "  data = hello"
end, "can't be edited")
expect_error("unknown record index", function(lines)
  lines[find_line(lines, "== Record 2:")] = "== Record 9: Type-2 =="
end, "unknown record 9")

---------------------------------------------------------------------------
-- Images.

local image = require("an2k_lua_nvim.image")

test("raw grayscale -> PNG", function()
  eq(image.raw_to_png(string.rep("\0", 11), 4, 3, 8), nil, "size mismatch rejected")
  local png = assert(image.raw_to_png(string.rep("\0\64\128\255", 3), 4, 3, 8))
  eq(image.detect(png), "PNG", "detected")
  eq(png:sub(17, 24), "\0\0\0\4\0\0\0\3", "IHDR dimensions")
  -- 70000 bytes forces more than one stored deflate block.
  local big = assert(image.raw_to_png(string.rep("\200", 350 * 200), 350, 200, 8))
  if vim.fn.executable("chafa") == 1 then
    for _, p in ipairs({ png, big, assert(image.raw_to_png("\170\85", 8, 2, 1, true)) }) do
      local path = vim.fn.tempname() .. ".png"
      local fh = assert(io.open(path, "wb"))
      fh:write(p)
      fh:close()
      vim.fn.system({ "chafa", "-f", "symbols", "-s", "10x5", path })
      os.remove(path)
      eq(vim.v.shell_error, 0, "chafa decodes generated PNG")
    end
  end
end)

test("viewable converts raw Type-3, rejects malformed Type-6", function()
  local f3 = assert(an2k.read_file(FIXTURES .. "type_3_wvu.an2"))
  eq(image.detect(plugin.viewable(f3.records[3], f3.records[3].data)), "PNG", "Type-3")
  local f6 = assert(an2k.read_file(FIXTURES .. "valid1.2.an2"))
  eq(image.detect(plugin.viewable(f6.records[4], f6.records[4].data)), nil, "Type-6 with wrong size")
end)

---------------------------------------------------------------------------
-- Buffer integration: open, edit, :w, reopen.

test("buffer read / edit / write", function()
  plugin.setup({ "*.an2" })
  local tmp = vim.fn.tempname() .. ".an2"
  local fh = assert(io.open(tmp, "wb"))
  fh:write(slurp(FIXTURES .. "valid1.1.an2"))
  fh:close()

  vim.cmd.edit(tmp)
  local buf = vim.api.nvim_get_current_buf()
  eq(vim.bo[buf].filetype, "eft", "filetype")
  eq(vim.bo[buf].modified, false, "not modified after load")
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local i = find_line(lines, "2.018")
  vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { "2.018 [NAM] = EDITED,NAME" })
  vim.cmd.write()
  eq(vim.bo[buf].modified, false, "not modified after write")

  local file = assert(an2k.read_file(tmp))
  eq(an2k.get_value(file.records[2], 18), "EDITED,NAME", "written value")

  -- A bad edit must not touch the file and must leave the buffer modified.
  local before = slurp(tmp)
  vim.api.nvim_buf_set_lines(buf, 4, 4, false, { "not a field" })
  pcall(vim.cmd.write)
  eq(slurp(tmp), before, "file untouched after failed write")
  eq(vim.bo[buf].modified, true, "still modified")

  vim.cmd("bwipeout!")
  os.remove(tmp)
end)

test("uppercase extension opens in the viewer", function()
  plugin.setup({ "*.an2" })
  local tmp = vim.fn.tempname() .. ".AN2"
  local fh = assert(io.open(tmp, "wb"))
  fh:write(slurp(FIXTURES .. "valid1.1.an2"))
  fh:close()
  vim.cmd.edit(tmp)
  eq(vim.bo.filetype, "eft", "filetype")
  vim.cmd("bwipeout!")
  os.remove(tmp)
end)

test(":EftValidate shows diagnostics and clears them after a fix + :w", function()
  plugin.setup({ "*.tdf" })
  local tmp = vim.fn.tempname() .. ".tdf"
  local fh = assert(io.open(tmp, "wb"))
  fh:write(slurp(FIXTURES .. "sre_with_face.tdf"))
  fh:close()
  vim.cmd.edit(tmp)
  local buf = vim.api.nvim_get_current_buf()
  local ns = vim.api.nvim_get_namespaces().an2k
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  vim.cmd("EftValidate noram")
  local diags = vim.diagnostic.get(buf, { namespace = ns })
  eq(#diags, 1, "one NORAM problem")
  eq(diags[1].code, "MISSING_FIELD", "code")
  eq(diags[1].lnum + 1, find_line(lines, "== Record 3: Type-10"), "on the Type-10 header")
  eq(vim.b[buf].an2k_profile, "noram", "profile remembered")

  -- A field-level error lands on the field's own line.
  local pry = find_line(lines, "1.006")
  vim.api.nvim_buf_set_lines(buf, pry - 1, pry, false, { "1.006 [PRY] = 0" })
  vim.cmd("EftValidate")
  local on_pry = vim.tbl_filter(function(d) return d.lnum + 1 == pry end, vim.diagnostic.get(buf, { namespace = ns }))
  eq(#on_pry, 1, "PRY diagnostic on its line")

  -- Fix both, :w re-validates and clears.
  vim.api.nvim_buf_set_lines(buf, pry - 1, pry, false, { "1.006 [PRY] = 5" })
  local t10 = find_line(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "10.003")
  vim.api.nvim_buf_set_lines(buf, t10, t10, false, { "10.004 = SRC1" })
  vim.cmd.write()
  eq(#vim.diagnostic.get(buf, { namespace = ns }), 0, "clean after fix")

  -- Parse errors are reported on their line.
  vim.api.nvim_buf_set_lines(buf, 4, 4, false, { "garbage" })
  eq(plugin.validate_buffer(buf, "noram"), false, "invalid")
  eq(vim.diagnostic.get(buf, { namespace = ns })[1].lnum, 4, "parse error line")
  eq(plugin.validate_buffer(buf, "nope"), false, "unknown profile")

  vim.cmd("bwipeout!")
  os.remove(tmp)
end)

test(":EftValidate after deleting a record uses the synced CNT", function()
  plugin.setup({ "*.an2" })
  vim.cmd.edit(FIXTURES .. "valid1.1.an2")
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local start = find_line(lines, "== Record 3:")
  vim.api.nvim_buf_set_lines(buf, start - 1, -1, false, {})
  eq(plugin.validate_buffer(buf, "none"), true, "CNT would be rewritten by :w")
  vim.cmd("bwipeout!")
end)

test("gi opens an image float", function()
  if vim.fn.executable("chafa") ~= 1 then
    return
  end
  plugin.setup({ "*.an2" })
  vim.cmd.edit(FIXTURES .. "valid1.3.an2")
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  vim.api.nvim_win_set_cursor(0, { find_line(lines, "10.999"), 0 })
  local before = #vim.api.nvim_list_wins()
  vim.cmd("normal gi")
  eq(#vim.api.nvim_list_wins(), before + 1, "float opened")
  eq(vim.api.nvim_win_get_config(0).relative, "editor", "float is current")
  vim.cmd("normal q")
  eq(#vim.api.nvim_list_wins(), before, "q closes it")
  vim.cmd("bwipeout!")
end)

io.write(string.format("%d passed, %d failed\n", passed, failed))
if failed > 0 then
  os.exit(1)
end

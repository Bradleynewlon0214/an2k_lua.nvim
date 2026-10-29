-- Read buffer lines (as produced by view.lua) back into an an2k model.
--
-- Records are keyed by their "== Record N:" header, where N indexes the model
-- the buffer was rendered from; binary payloads shown as "<N bytes, ...>"
-- placeholders are taken from that record.  "== Record new: Type-T ==" starts
-- a new tagged record.

local model = require("an2k.model")
local text = require("an2k_lua_nvim.text")
local view = require("an2k_lua_nvim.view")

local M = {}

local unpack = table.unpack or unpack

local function fail(lnum, msg)
  error(string.format("line %d: %s", lnum, msg), 0)
end

local function find_field(record, num)
  if record then
    for _, f in ipairs(record.fields) do
      if f.num == num then
        return f
      end
    end
  end
end

local function tagged_line(cur, line, lnum)
  local tag, rest = line:match("^(%d+%.%d+)%s*(.*)$")
  if not tag then
    fail(lnum, "expected 'T.NNN = value'")
  end
  rest = rest:gsub("^%b[]%s*", "")
  local value = rest:match("^= ?(.*)$")
  if not value then
    fail(lnum, "expected '=' after " .. tag)
  end
  local t, num = model.parse_tag(tag)
  if t ~= cur.record.type then
    fail(lnum, string.format("field %s in a Type-%d record", tag, cur.record.type))
  end
  if cur.seen[num] then
    fail(lnum, string.format("field %s repeats line %d", tag, cur.seen[num]))
  end
  cur.seen[num] = lnum

  local f = { tag = tag, type = t, num = num }
  if num == 999 and t ~= 1 then
    if value:match(view.PLACEHOLDER) then
      local orig = find_field(cur.orig, 999)
      if not orig or not orig.data then
        fail(lnum, "placeholder has no original data; enter bytes as escaped text instead")
      end
      f.data = orig.data
    else
      local raw, err = text.unescape(value)
      if not raw then
        fail(lnum, err)
      end
      f.data = raw
    end
  else
    local subfields, err = text.parse_subfields(value)
    if not subfields then
      fail(lnum, err)
    end
    f.subfields = subfields
  end
  local fields = cur.record.fields
  fields[#fields + 1] = f
end

local function binary_line(cur, line, lnum)
  local key, value = line:match("^%s*(%a+)%s*= ?(.*)$")
  if not key then
    fail(lnum, "expected 'key = value' in a binary record")
  end
  local record = cur.record
  if key == "data" then
    if not value:match(view.PLACEHOLDER) then
      fail(lnum, "binary record data can't be edited as text")
    end
    record.data = cur.orig.data
    return
  end
  for _, def in ipairs(model.binary_layouts[record.type]) do
    local name, n = def[1], def[2]
    if name == key then
      if name == "fgp" then
        local fgp = {}
        for v in value:gmatch("%S+") do
          fgp[#fgp + 1] = tonumber(v)
        end
        if #fgp ~= n then
          fail(lnum, string.format("fgp needs %d numbers", n))
        end
        for _, v in ipairs(fgp) do
          if not v or v < 0 or v > 255 or v % 1 ~= 0 then
            fail(lnum, "fgp values must be integers 0-255")
          end
        end
        record.header.fgp = fgp
      else
        local v = tonumber(value)
        if not v or v < 0 or v >= 256 ^ n or v % 1 ~= 0 then
          fail(lnum, string.format("%s must be an integer 0-%d", name, 256 ^ n - 1))
        end
        record.header[name] = v
      end
      return
    end
  end
  fail(lnum, string.format("Type-%d has no header field '%s'", record.type, key))
end

-- LEN must lead every tagged record; it is recomputed on write.
local function finish(cur)
  if not cur or not cur.record.tagged then
    return
  end
  local fields = cur.record.fields
  for i, f in ipairs(fields) do
    if f.num == 1 then
      table.remove(fields, i)
      table.insert(fields, 1, f)
      return
    end
  end
  table.insert(fields, 1, model.new_field(cur.record.type, 1, "0"))
end

local function parse(lines, orig)
  local file = { records = {} }
  local cur
  local used = {}
  for lnum, line in ipairs(lines) do
    local index, rtype = line:match(view.HEADER)
    if index then
      finish(cur)
      rtype = tonumber(rtype)
      local record, orig_record
      if index == "new" then
        if model.is_binary_type(rtype) then
          fail(lnum, "new binary records can't be created in the buffer")
        end
        record = { type = rtype, tagged = true, fields = {} }
      else
        local n = tonumber(index)
        orig_record = n and orig.records[n]
        if not orig_record then
          fail(lnum, "unknown record " .. index .. " (use 'new' for added records)")
        end
        if orig_record.type ~= rtype then
          fail(lnum, string.format("record %d is Type-%d, not Type-%d", n, orig_record.type, rtype))
        end
        if used[n] then
          fail(lnum, string.format("record %d appears twice (also line %d)", n, used[n]))
        end
        used[n] = lnum
        if orig_record.tagged then
          record = { type = rtype, tagged = true, fields = {} }
        else
          local header = {}
          for k, v in pairs(orig_record.header) do
            header[k] = type(v) == "table" and { unpack(v) } or v
          end
          record = { type = rtype, tagged = false, header = header, data = orig_record.data }
        end
      end
      if #file.records == 0 and rtype ~= 1 then
        fail(lnum, "the first record must be Type-1")
      elseif #file.records > 0 and rtype == 1 then
        fail(lnum, "only the first record may be Type-1")
      end
      file.records[#file.records + 1] = record
      cur = { record = record, orig = orig_record, seen = {} }
    elseif line:match("^%s*$") or line:match("^#") then
      -- blank or comment
    elseif not cur then
      fail(lnum, "field before the first '== Record' header")
    elseif cur.record.tagged then
      tagged_line(cur, line, lnum)
    else
      binary_line(cur, line, lnum)
    end
  end
  finish(cur)
  if #file.records == 0 then
    fail(#lines, "no records")
  end
  return file
end

-- Returns the model, or nil and an error message naming the line.
function M.parse(lines, orig)
  local ok, res = pcall(parse, lines, orig)
  if not ok then
    return nil, res
  end
  return res
end

return M

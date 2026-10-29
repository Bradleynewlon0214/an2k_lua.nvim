-- Render an an2k model as buffer lines.  parse.lua reads the same format back.

local model = require("an2k.model")
local names = require("an2k_lua_nvim.names")
local text = require("an2k_lua_nvim.text")
local image = require("an2k_lua_nvim.image")

local M = {}

-- Header grammar shared with parse.lua: "== Record <n|new>: Type-<t> ...".
M.HEADER = "^== Record (%w+): Type%-(%d+)"

function M.header(index, record)
  return string.format(
    "== Record %s: Type-%d %s%s ==",
    tostring(index),
    record.type,
    names.records[record.type] or "",
    record.tagged and "" or " (binary)"
  )
end

function M.placeholder(data)
  return string.format("<%d bytes, %s>", #data, image.detect(data) or "binary")
end

M.PLACEHOLDER = "^<%d+ bytes, [^>]*>$"

local function field_line(f)
  local mnem = names.field(f.type, f.num)
  local value = f.data and M.placeholder(f.data) or text.format_subfields(f.subfields)
  return string.format("%s%s = %s", f.tag, mnem and (" [" .. mnem .. "]") or "", value)
end

local function binary_lines(record, lines)
  for _, def in ipairs(model.binary_layouts[record.type]) do
    local name = def[1]
    local v = record.header[name]
    if name == "fgp" then
      v = table.concat(v, " ")
    end
    lines[#lines + 1] = string.format("  %s = %s", name, tostring(v))
  end
  lines[#lines + 1] = "  data = " .. M.placeholder(record.data)
end

function M.render(file)
  local lines = {
    "# ANSI/NIST-ITL transaction. LEN and CNT are recomputed on :w.",
    "# ␟ item (<M-i>)  ␞ subfield (<M-s>)  gi show image  ge extract payload  ]] [[ records",
  }
  for i, record in ipairs(file.records) do
    lines[#lines + 1] = M.header(i, record)
    if record.tagged then
      for _, f in ipairs(record.fields) do
        lines[#lines + 1] = field_line(f)
      end
    else
      binary_lines(record, lines)
    end
  end
  return lines
end

return M

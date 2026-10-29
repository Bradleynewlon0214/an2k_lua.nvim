-- Field values as buffer text and back.
--
-- Subfields are joined with ␞ (U+241E) and items with ␟ (U+241F).  Inside an
-- item: `\` -> `\\`, control bytes -> `\xNN`, literal ␞/␟ -> `␞`/`␟`,
-- and when the item is not valid UTF-8, bytes >= 0x80 -> `\xNN` as well.

local M = {}

M.SUBFIELD = "\226\144\158" -- ␞
M.ITEM = "\226\144\159" -- ␟

-- Strict-enough UTF-8 check (rejects overlongs' lead bytes and stray continuations).
function M.valid_utf8(s)
  local i, n = 1, #s
  while i <= n do
    local c = s:byte(i)
    local len
    if c < 0x80 then
      len = 1
    elseif c >= 0xC2 and c <= 0xDF then
      len = 2
    elseif c >= 0xE0 and c <= 0xEF then
      len = 3
    elseif c >= 0xF0 and c <= 0xF4 then
      len = 4
    else
      return false
    end
    for k = i + 1, i + len - 1 do
      local cc = s:byte(k)
      if not cc or cc < 0x80 or cc > 0xBF then
        return false
      end
    end
    i = i + len
  end
  return true
end

local function hex(c)
  return string.format("\\x%02X", c:byte())
end

function M.escape(item)
  local s = item:gsub("\\", "\\\\")
  if M.valid_utf8(item) then
    s = s:gsub("%c", hex)
  else
    s = s:gsub("[%c\128-\255]", hex)
  end
  s = s:gsub(M.SUBFIELD, "\\u241E"):gsub(M.ITEM, "\\u241F")
  return s
end

-- Returns the raw item, or nil and an error message.
function M.unescape(s)
  local out, i = {}, 1
  while true do
    local j = s:find("\\", i, true)
    if not j then
      out[#out + 1] = s:sub(i)
      return table.concat(out)
    end
    out[#out + 1] = s:sub(i, j - 1)
    local nxt = s:sub(j + 1, j + 1)
    if nxt == "\\" then
      out[#out + 1] = "\\"
      i = j + 2
    elseif nxt == "x" and s:sub(j + 2, j + 3):match("^%x%x$") then
      out[#out + 1] = string.char(tonumber(s:sub(j + 2, j + 3), 16))
      i = j + 4
    elseif s:sub(j + 1, j + 5) == "u241E" then
      out[#out + 1] = M.SUBFIELD
      i = j + 6
    elseif s:sub(j + 1, j + 5) == "u241F" then
      out[#out + 1] = M.ITEM
      i = j + 6
    else
      return nil, "bad escape '\\" .. nxt .. "' (use \\\\, \\xNN, \\u241E or \\u241F)"
    end
  end
end

local function split(s, sep)
  local out, i = {}, 1
  while true do
    local j = s:find(sep, i, true)
    if not j then
      out[#out + 1] = s:sub(i)
      return out
    end
    out[#out + 1] = s:sub(i, j - 1)
    i = j + #sep
  end
end

function M.format_subfields(subfields)
  local subs = {}
  for i, sub in ipairs(subfields) do
    local items = {}
    for j, item in ipairs(sub) do
      items[j] = M.escape(item)
    end
    subs[i] = table.concat(items, M.ITEM)
  end
  return table.concat(subs, M.SUBFIELD)
end

-- Returns subfields, or nil and an error message.
function M.parse_subfields(s)
  local subfields = {}
  for i, sub in ipairs(split(s, M.SUBFIELD)) do
    local items = {}
    for j, item in ipairs(split(sub, M.ITEM)) do
      local raw, err = M.unescape(item)
      if not raw then
        return nil, err
      end
      items[j] = raw
    end
    subfields[i] = items
  end
  return subfields
end

return M

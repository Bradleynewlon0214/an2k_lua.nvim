-- Embedded image payloads: format detection, chafa preview, extraction.

local M = {}

local magics = {
  { "\255\216\255", "JPEG", "jpg", true },
  { "\137PNG\r\n\26\n", "PNG", "png", true },
  { "\0\0\0\12jP  \r\n\135\n", "JPEG 2000", "jp2", false },
  { "\255\79\255\81", "JPEG 2000 codestream", "j2k", false },
  { "\255\160", "WSQ", "wsq", false },
  { "II*\0", "TIFF", "tif", true },
  { "MM\0*", "TIFF", "tif", true },
  { "GIF8", "GIF", "gif", true },
  { "BM", "BMP", "bmp", false },
}

-- Returns format name, file extension, and whether chafa can display it.
function M.detect(data)
  for _, m in ipairs(magics) do
    if data:sub(1, #m[1]) == m[1] then
      return m[2], m[3], m[4]
    end
  end
  return nil, "bin", false
end

---------------------------------------------------------------------------
-- Uncompressed grayscale -> PNG (stored deflate blocks), so chafa can show it.

local bit = require("bit")

local crc_table = {}
for n = 0, 255 do
  local c = n
  for _ = 1, 8 do
    if bit.band(c, 1) == 1 then
      c = bit.bxor(0xEDB88320, bit.rshift(c, 1))
    else
      c = bit.rshift(c, 1)
    end
  end
  crc_table[n] = c
end

local function crc32(s)
  local c = 0xFFFFFFFF
  for i = 1, #s do
    c = bit.bxor(crc_table[bit.band(bit.bxor(c, s:byte(i)), 0xFF)], bit.rshift(c, 8))
  end
  return bit.bxor(c, 0xFFFFFFFF) % 2 ^ 32
end

local function adler32(s)
  local a, b = 1, 0
  for i = 1, #s do
    a = (a + s:byte(i)) % 65521
    b = (b + a) % 65521
  end
  return b * 65536 + a
end

local function u32(v)
  return string.char(math.floor(v / 16777216) % 256, math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256)
end

local function u16le(v)
  return string.char(v % 256, math.floor(v / 256))
end

local function chunk(kind, body)
  return u32(#body) .. kind .. body .. u32(crc32(kind .. body))
end

-- Raw grayscale pixels (rows packed, `depth` 8 or 1 bits per pixel) as a PNG.
-- Returns nil unless `data` is exactly the size the dimensions imply.
-- `invert` flips 1-bit images, where ANSI/NIST uses 1 for black.
function M.raw_to_png(data, width, height, depth, invert)
  local row_bytes = math.ceil(width * depth / 8)
  if width < 1 or height < 1 or #data ~= row_bytes * height then
    return nil
  end
  local rows = {}
  for y = 0, height - 1 do
    local row = data:sub(y * row_bytes + 1, (y + 1) * row_bytes)
    if invert then
      row = row:gsub(".", function(c) return string.char(255 - c:byte()) end)
    end
    rows[#rows + 1] = "\0" .. row -- filter type 0
  end
  local raw = table.concat(rows)
  local blocks = { "\120\1" } -- zlib header, no compression
  local pos = 1
  repeat
    local piece = raw:sub(pos, pos + 65534)
    pos = pos + #piece
    local final = pos > #raw and 1 or 0
    blocks[#blocks + 1] = string.char(final) .. u16le(#piece) .. u16le(65535 - #piece) .. piece
  until pos > #raw
  blocks[#blocks + 1] = u32(adler32(raw))
  return "\137PNG\r\n\26\n"
    .. chunk("IHDR", u32(width) .. u32(height) .. string.char(depth, 0, 0, 0, 0))
    .. chunk("IDAT", table.concat(blocks))
    .. chunk("IEND", "")
end

local function write_bytes(path, data)
  local f, err = io.open(path, "wb")
  if not f then
    return nil, err
  end
  f:write(data)
  f:close()
  return true
end

local function float(buf, title, width, height)
  width = math.min(width, vim.o.columns - 4)
  height = math.min(height, vim.o.lines - 4)
  return vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = vim.o.winborder == "" and "rounded" or nil,
    title = " " .. title .. " ",
    title_pos = "center",
  })
end

-- Shows image bytes in a float drawn by chafa (plain text, so it works over tmux/ssh).
function M.show(data, title)
  local format, ext, displayable = M.detect(data)
  if not displayable then
    vim.notify(
      string.format("an2k: %s images can't be shown in nvim; use ge to extract", format or "unknown"),
      vim.log.levels.WARN
    )
    return
  end
  local path = vim.fn.tempname() .. "." .. ext
  local ok, err = write_bytes(path, data)
  if not ok then
    return vim.notify("an2k: " .. tostring(err), vim.log.levels.ERROR)
  end
  if vim.fn.executable("chafa") ~= 1 then
    vim.notify("an2k: install chafa to view images in nvim; opening with the system viewer", vim.log.levels.WARN)
    return vim.ui.open(path)
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local win = float(buf, title, math.floor(vim.o.columns * 0.7), math.floor(vim.o.lines * 0.7))
  -- The float may be clamped to the editor, so size chafa from the window it actually got.
  local cols, rows = vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win)
  vim.fn.jobstart(
    { "chafa", "-f", "symbols", "-c", "full", "--animate", "off", "-s", cols .. "x" .. rows, path },
    { term = true, on_exit = function() os.remove(path) end }
  )
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", lhs, function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end, { buffer = buf, desc = "an2k: close image" })
  end
  vim.cmd.stopinsert()
end

-- Prompts for a path (default `default_stem.<ext>`) and writes the payload there.
function M.extract(data, default_stem)
  local _, ext = M.detect(data)
  vim.ui.input({ prompt = "Extract to: ", default = default_stem .. "." .. ext, completion = "file" }, function(path)
    if not path or path == "" then
      return
    end
    path = vim.fn.expand(path)
    local ok, err = write_bytes(path, data)
    if ok then
      vim.notify(string.format("an2k: wrote %d bytes to %s", #data, path))
    else
      vim.notify("an2k: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

return M

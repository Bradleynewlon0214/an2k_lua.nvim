-- Open ANSI/NIST-ITL / EBTS transaction files as an editable structured view.
-- Override the file patterns with vim.g.an2k_patterns before this loads.

if vim.g.loaded_an2k then
  return
end
vim.g.loaded_an2k = true

require("an2k_lua_nvim").setup(vim.g.an2k_patterns or { "*.eft", "*.ebts", "*.an2", "*.an2k", "*.nist" })

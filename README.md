# an2k_lua.nvim

Neovim viewer/editor for ANSI/NIST-ITL transaction files (FBI EBTS), built on
[an2k_lua](https://github.com/Bradleynewlon0214/an2k_lua).

With lazy.nvim:

```lua
{
  "Bradleynewlon0214/an2k_lua.nvim",
  lazy = false,
  dependencies = { "Bradleynewlon0214/an2k_lua" },
}
```

Opening `*.eft`, `*.ebts`, `*.an2`, `*.an2k` or `*.nist` (override with `vim.g.an2k_patterns`)
shows one line per field, folded per record:

```
== Record 2: Type-2 User-defined Descriptive Text ==
2.018 [NAM] = smith,tom
14.021 = 7␟31␟31␟31␟31␞8␟32␟32␟32␟32
== Record 3: Type-4 High-resolution Grayscale Fingerprint (binary) ==
  fgp = 10 255 255 255 255 255
  data = <14846 bytes, WSQ>
```

- Edit values, add/delete field lines, delete record blocks, or add a
  `== Record new: Type-T ==` block; `:w` writes through an2k (LEN/CNT recomputed).
  A line that doesn't parse aborts the write and names the line.
- `␟` separates items (`<M-i>`), `␞` subfields (`<M-s>`). Escapes: `\\`, `\xNN`, `␞`, `␟`.
- `<N bytes, …>` placeholders keep the original payload; binary payloads aren't editable as text.
- `gi` shows the record's image with chafa (JPEG, PNG, TIFF, GIF, and uncompressed grayscale
  via an on-the-fly PNG). WSQ and JPEG 2000 can't be shown; `ge` extracts any payload to a file.
- `]]` / `[[` jump between records.
- `:EftValidate [none|noram|fbi_ebts_11|dod_ebts_4_1]` validates the buffer as `:w` would write
  it and shows problems as diagnostics on the field (or record header) lines. The profile is
  remembered per buffer and re-checked after each `:w`; `vim.g.an2k_profile` sets a default.

## Tests

```
nvim -l test/spec.lua
```

Expects the an2k_lua library checked out next to this repo, at `../an2k_lua` (or
`../lua-an2k`), for the library and its `test/fixtures/`. Set `AN2K_PATH` to point elsewhere.

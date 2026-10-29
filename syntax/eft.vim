" Structured view of ANSI/NIST-ITL transactions (see lua/an2k_lua_nvim/view.lua).
if exists('b:current_syntax')
  finish
endif

syntax match eftComment     /^#.*$/
syntax match eftHeader      /^== Record .* ==$/
syntax match eftTag         /^\d\+\.\d\+/ nextgroup=eftMnemonic skipwhite
syntax match eftMnemonic    /\[[^]]*\]/ contained
syntax match eftKey         /^\s\+\a\+\ze\s*=/
syntax match eftSeparator   /[␞␟]/
syntax match eftEscape      /\\\(\\\|x\x\x\|u241[EF]\)/
syntax match eftPlaceholder /<\d\+ bytes, [^>]*>$/

highlight default link eftComment     Comment
highlight default link eftHeader      Title
highlight default link eftTag         Identifier
highlight default link eftMnemonic    Type
highlight default link eftKey         Identifier
highlight default link eftSeparator   Delimiter
highlight default link eftEscape      SpecialChar
highlight default link eftPlaceholder Special

let b:current_syntax = 'eft'

" Lightweight built-in syntax for Kiln's Elixir workspaces.
if exists('b:current_syntax')
  finish
endif
syntax keyword elixirKeyword defmodule def defp defmacro defmacrop do end fn case cond with for if unless else rescue catch after try receive when use import require alias quote unquote
syntax keyword elixirBoolean true false nil
syntax keyword elixirOperator and or not in
syntax match elixirComment "#.*$"
syntax match elixirNumber "\<\d\+\%(\.\d\+\)\?\>"
syntax match elixirAtom ":[a-zA-Z_][a-zA-Z0-9_!?]*"
syntax match elixirModule "\<[A-Z][a-zA-Z0-9_]*\%([.][A-Z][a-zA-Z0-9_]*\)*\>"
syntax match elixirAttribute "@[a-zA-Z_][a-zA-Z0-9_]*"
syntax match elixirPipe "|>"
syntax region elixirString start=+"+ skip=+\\.+ end=+"+
highlight default link elixirKeyword Statement
highlight default link elixirBoolean Constant
highlight default link elixirOperator Statement
highlight default link elixirComment Comment
highlight default link elixirNumber Number
highlight default link elixirAtom Special
highlight default link elixirModule Type
highlight default link elixirAttribute PreProc
highlight default link elixirPipe Special
highlight default link elixirString String
let b:current_syntax = 'elixir'

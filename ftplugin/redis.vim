" Vim filetype plugin
" Language:    Redis commands (dblite `.redis` scratch buffers)

if exists("b:did_ftplugin")
  finish
endif
let b:did_ftplugin = 1

setlocal commentstring=#\ %s
setlocal comments=:#

" `JSON.GET` is one command and `user:1042:profile` is one key, so `w`, `*`,
" `yiw` and completion should all treat them as single words rather than
" stopping at every separator.
setlocal iskeyword+=.
setlocal iskeyword+=:
setlocal iskeyword+=45

" Statements are newline-delimited: a wrapped line would become two commands.
setlocal formatoptions-=t
setlocal formatoptions-=c

let b:undo_ftplugin = "setlocal commentstring< comments< iskeyword< formatoptions<"

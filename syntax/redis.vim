" Vim syntax file
" Language:    Redis commands (dblite `.redis` scratch buffers)
" Maintainer:  dblite.nvim
"
" One command per line, `#` comments — the shape `:DbliteRun` executes. The
" point of the highlighting is to make the verb, its flags and its keys
" separable at a glance; anything not recognised stays unhighlighted, which is
" itself the signal that a flag was mistyped.

if exists("b:current_syntax")
  finish
endif

syn case ignore

" Order matters: the first item defined wins where two can match at the same
" position, so the command-at-line-start rule is declared before the flag rule
" that would otherwise claim `GET` or `TYPE` on column one.
syn match redisComment /#.*$/ contains=@Spell

syn match redisCommand /^\s*\zs[A-Za-z][A-Za-z0-9_]*\%(\.[A-Za-z][A-Za-z0-9_]*\)*/

" Flags are matched, not `syn keyword`ed: a keyword outranks every match in
" Vim regardless of definition order, which would repaint `GET` at line start.
" The lookbehind keeps this rule off column one.
syn match redisFlag /\%(^\s*\)\@<!\<\%(NX\|XX\|GT\|LT\|EX\|PX\|EXAT\|PXAT\|KEEPTTL\|PERSIST\|WITHSCORES\|WITHVALUES\|WITHCOORD\|WITHDIST\|WITHHASH\|LIMIT\|MATCH\|COUNT\|TYPE\|ASC\|DESC\|ALPHA\|BY\|GET\|SET\|STORE\|AGGREGATE\|WEIGHTS\|SUM\|MIN\|MAX\|REV\|BYSCORE\|BYLEX\|LEFT\|RIGHT\|BEFORE\|AFTER\|BLOCK\|STREAMS\|NOMKSTREAM\|MAXLEN\|MINID\|IDLE\|FORCE\|JUSTID\|REPLACE\|ABSTTL\|FREQ\|IDLETIME\|SAMPLES\|RESET\|NOSAVE\|SCHEDULE\|ASYNC\|SYNC\|INDENT\|NEWLINE\|SPACE\|NOESCAPE\|FILTER\|RANK\|MEMORY\|USAGE\|DOCTOR\|SEGFAULT\)\>/

" Not `oneline`: a quote left open continues the command onto the next line,
" which is how a JSON argument is written across several lines.
syn region redisString start=/"/ skip=/\\./ end=/"/
syn region redisString start=/'/ skip=/\\./ end=/'/

" A trailing backslash outside quotes continues the command. Highlighting it
" distinguishes a deliberate continuation from a stray character.
syn match redisContinuation /\\\s*$/

" A JSONPath argument to the RedisJSON commands: `$`, `$.name`, `$..tags[0]`.
syn match redisPath /\$[^ \t]*/

" Namespaced keys are the overwhelmingly common shape, and picking them out
" separates the key from its surrounding arguments.
syn match redisKey /\<[A-Za-z0-9_.-]\+:[A-Za-z0-9_.:{}*?-]\+/

syn match redisGlob /[*?]/

syn match redisNumber /\<-\=\d\+\%(\.\d\+\)\=\>/

hi def link redisComment Comment
hi def link redisCommand Statement
hi def link redisFlag    Type
hi def link redisString  String
hi def link redisPath    Special
hi def link redisKey     Identifier
hi def link redisGlob    Special
hi def link redisNumber  Number
hi def link redisContinuation Special

let b:current_syntax = "redis"

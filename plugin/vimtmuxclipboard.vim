
func! s:TmuxBufferName()
    let l:list = systemlist('tmux list-buffers -F"#{buffer_name}"')
    if len(l:list)==0
        return ""
    else
        return l:list[0]
    endif
endfunc

func! s:TmuxBuffer()
    return system('tmux show-buffer')
endfunc

func! s:Enable()

    if $TMUX=='' 
        " not in tmux session
        return
    endif

    let s:lastbname=""

    " if support TextYankPost
    if exists('##TextYankPost')==1
        " @"
        augroup vimtmuxclipboard
            autocmd!
            autocmd FocusLost * call s:update_from_tmux()
            autocmd	FocusGained   * call s:update_from_tmux()
            autocmd TextYankPost * silent! call system('tmux loadb -',join(v:event["regcontents"],"\n"))
            autocmd TextYankPost * silent! call s:OSCYankString(join(v:event["regcontents"],"\n"))
            autocmd TextYankPost * silent! call system('xsel --clipboard --input',join(v:event["regcontents"],"\n"))
        augroup END
        let @" = s:TmuxBuffer()
    else
        " vim doesn't support TextYankPost event
        " This is a workaround for vim
        augroup vimtmuxclipboard
            autocmd!
            autocmd FocusLost     *  silent! call system('tmux loadb -',@")
            autocmd	FocusGained   *  let @" = s:TmuxBuffer()
        augroup END
        let @" = s:TmuxBuffer()
    endif

endfunc

func! s:update_from_tmux()
    let buffer_name = s:TmuxBufferName()
    if s:lastbname != buffer_name
        let @" = s:TmuxBuffer()
    endif
    let s:lastbname=s:TmuxBufferName()
endfunc

" Send a string to the terminal's clipboard using OSC52.
function! s:OSCYankString(str)
  let length = strlen(a:str)
  let limit = get(g:, 'oscyank_max_length', 100000)
  let osc52_key = 'default'

  if length > limit
    echohl WarningMsg
    echo '[oscyank] Selection has length ' . length . ', limit is ' . limit
    echohl None
    return
  endif

  if exists('g:oscyank_term')  " Explicitly use a supported terminal.
    let osc52_key = get(g:, 'oscyank_term')
  else  " Fallback to auto-detection.
    if !empty($TMUX)
      let osc52_key = 'tmux'
    elseif match($TERM, 'screen') > -1
      let osc52_key = 'screen'
    elseif match($TERM, 'kitty') > -1
      let osc52_key = 'kitty'
    endif
  endif

  let osc52 = get(s:osc52_table, osc52_key, s:osc52_table['default'])(a:str)
  call s:raw_echo(osc52)
endfunction

" This function base64's the entire string and wraps it in a single OSC52.
" It's appropriate when running in a raw terminal that supports OSC 52.
function! s:get_OSC52(str)
  let b64 = s:b64encode(a:str, 0)
  return "\e]52;c;" . b64 . "\x07"
endfunction

" This function base64's the entire string and wraps it in a single OSC52 for
" tmux.
" This is for `tmux` sessions which filters OSC52 locally.
function! s:get_OSC52_tmux(str)
  let b64 = s:b64encode(a:str, 0)
  return "\ePtmux;\e\e]52;c;" . b64 . "\x07\e\\"
endfunction

" This function base64's the entire source, wraps it in a single OSC52, and then
" breaks the result into small chunks which are each wrapped in a DCS sequence.
" This is appropriate when running on `screen`. Screen doesn't support OSC52,
" but will pass the contents of a DCS sequence to the outer terminal unchanged.
" It imposes a small max length to DCS sequences, so we send in chunks.
function! s:get_OSC52_DCS(str)
  let b64 = s:b64encode(a:str, 76)
  " Remove the trailing newline.
  let b64 = substitute(b64, '\n*$', '', '')
  " Replace each newline with an <end-dcs><start-dcs> pair.
  let b64 = substitute(b64, '\n', "\e/\eP", "g")
  " (except end-of-dcs is "ESC \", begin is "ESC P", and I can't figure out
  " how to express "ESC \ ESC P" in a single string. So the first substitute
  " uses "ESC / ESC P" and the second one swaps out the "/". It seems like
  " there should be a better way.)
  let b64 = substitute(b64, '/', '\', 'g')
  " Now wrap the whole thing in <start-dcs><start-osc52>...<end-osc52><end-dcs>.
  return "\eP\e]52;c;" . b64 . "\x07\e\x5c"
endfunction

" Kitty versions below 0.22.0 require the clipboard to be flushed before
" accepting a new string.
" https://sw.kovidgoyal.net/kitty/changelog/#id33
function! s:get_OSC52_kitty(str)
  call s:raw_echo("\e]52;c;!\x07")
  return s:get_OSC52(a:str)
endfunction

" Echo a string to the terminal without munging the escape sequences.
function! s:raw_echo(str)
  if has('win32') && has('nvim')
    call chansend(v:stderr, a:str)
  else
    if filewritable('/dev/fd/2')
      call writefile([a:str], '/dev/fd/2', 'b')
    else
      exec("silent! !echo " . shellescape(a:str))
      redraw!
    endif
  endif
endfunction

" Encode a string of bytes in base 64.
" If size is > 0 the output will be line wrapped every `size` chars.
function! s:b64encode(str, size)
  let bytes = s:str2bytes(a:str)
  let b64_arr = []

  for i in range(0, len(bytes) - 1, 3)
    let n = bytes[i] * 0x10000
          \ + get(bytes, i + 1, 0) * 0x100
          \ + get(bytes, i + 2, 0)
    call add(b64_arr, s:b64_table[n / 0x40000])
    call add(b64_arr, s:b64_table[n / 0x1000 % 0x40])
    call add(b64_arr, s:b64_table[n / 0x40 % 0x40])
    call add(b64_arr, s:b64_table[n % 0x40])
  endfor

  if len(bytes) % 3 == 1
    let b64_arr[-1] = '='
    let b64_arr[-2] = '='
  endif

  if len(bytes) % 3 == 2
    let b64_arr[-1] = '='
  endif

  let b64 = join(b64_arr, '')
  if a:size <= 0
    return b64
  endif

  let chunked = ''
  while strlen(b64) > 0
    let chunked .= strpart(b64, 0, a:size) . "\n"
    let b64 = strpart(b64, a:size)
  endwhile

  return chunked
endfunction

function! s:str2bytes(str)
  return map(range(len(a:str)), 'char2nr(a:str[v:val])')
endfunction

" Lookup table for g:oscyank_term.
let s:osc52_table = {
      \ 'default': function('s:get_OSC52'),
      \ 'kitty': function('s:get_OSC52_kitty'),
      \ 'screen': function('s:get_OSC52_DCS'),
      \ 'tmux': function('s:get_OSC52_tmux'),
      \ }

" Lookup table for s:b64encode.
let s:b64_table = [
      \ "A","B","C","D","E","F","G","H","I","J","K","L","M","N","O","P",
      \ "Q","R","S","T","U","V","W","X","Y","Z","a","b","c","d","e","f",
      \ "g","h","i","j","k","l","m","n","o","p","q","r","s","t","u","v",
      \ "w","x","y","z","0","1","2","3","4","5","6","7","8","9","+","/",
      \ ]

call s:Enable()

" " workaround for this bug
" if shellescape("\n")=="'\\\n'"
" 	let l:s=substitute(l:s,'\\\n',"\n","g")
" 	let g:tmp_s=substitute(l:s,'\\\n',"\n","g")
" 	");
" 	let g:tmp_cmd='tmux set-buffer ' . l:s
" endif
" silent! call system('tmux loadb -',l:s)

" NOTE: you could set these two global variables in your .vimrc if you want to
" override the defaults of root/localhost
if ! exists('g:MySchema_default_user')
  let g:MySchema_default_user = 'root'
endif
if ! exists('g:MySchema_default_host')
  " these days 127.0.0.1 is a more convenient default host because I'm usually running mysql in a
  " container with an exposed port
  let g:MySchema_default_host = '127.0.0.1'
endif

function! <SID>GetConnectInfo() " {{{
    let l:engine = <SID>GetGlobalEngine()

    let l:info = {
          \ 'engine': l:engine,
          \ }

    if l:engine == 'mysql' && exists('g:MySchema_authorized_mysql_command')
      " if there is an authorized command, we don't need to prompt for credentials
      let l:info.command = g:MySchema_authorized_mysql_command
    else
      let l:info.host = <SID>GetGlobalHost()
      let l:info.user = <SID>GetGlobalUser()
      let l:info.pass = <SID>GetGlobalPass()
    endif

    return l:info
endfun " }}}

function! MySchema#GetSchema(table_name)
  " do we know what mysql server to use?
  call inputsave()
  try
    " collect credentials if we don't have them yet
    let l:connect = <SID>GetConnectInfo()

    if !strlen(a:table_name)
      " if no table name was specified, we want to ask the user which database
      " to show tables from
      let l:db = <SID>PromptDB(l:connect, 'Show tables from which database?')
      if strlen(l:db)
        call <SID>ShowTables(l:connect, l:db)
      endif
    elseif exists('b:MySchema_database') && strlen(b:MySchema_database)
      " if this window was opened by MySchema#GetSchema(), we know what
      " database to look in automatically
      call <SID>ShowTableFromDB(l:connect, b:MySchema_database, a:table_name)
    elseif exists('g:MySchema_db') && g:MySchema_db
      " if the user has previously specified that we are in single-database
      " mode, show the table from that db
      call <SID>ShowTableFromDB(l:connect, g:MySchema_db, a:table_name)
    else
      " scan all databases to see which one has this table
      let l:db_list = <SID>FindDatabasesWithTable(l:connect, a:table_name)

      " if there are no databases, show an error
      if ! len(l:db_list)
        echohl Error
        echo "No databases contain a table named" a:table_name
        echohl None
      elseif len(l:db_list) == 1
        " if there is only one database that contains a table with this name,
        " show its schema
        call <SID>ShowTableFromDB(l:connect, l:db_list[0], a:table_name)
      else
        " show the user a menu of databases to choose from
        let l:db = <SID>ChooseDatabase(printf('Show table %s from which database?', a:table_name), l:db_list)
        if strlen(l:db)
          call <SID>ShowTableFromDB(l:connect, l:db, a:table_name)
        endif
      endif
    endif
  finally
    call inputrestore()
    echohl None
  endtry

endfunction

" if g:MySchema_db is set, then we are operating in 'single-db' mode
" 

function! MySchema#ResetOptions(preserve)
  if a:preserve
    if exists('g:MySchema_host') && strlen(g:MySchema_host)
      let g:MySchema_default_host = g:MySchema_host
    endif
    if exists('g:MySchema_user') && strlen(g:MySchema_user)
      let g:MySchema_default_user = g:MySchema_user
    endif
  endif
  unlet! g:MySchema_engine g:MySchema_host g:MySchema_user g:MySchema_pass g:MySchema_db
endfunction

function! <SID>GetGlobalEngine()
  if !exists('g:MySchema_engine') || !strlen(g:MySchema_engine)
    let l:engines = ['MySQL', 'Postgresql']
    let l:idx = VimUI#SelectOne('engine: ', l:engines, 1)
    if l:idx >= 0
      let g:MySchema_engine = tolower(l:engines[l:idx])
    else
      let g:MySchema_engine = ''
    endif
  endif
  return g:MySchema_engine
endfunction

function! <SID>GetGlobalHost()
  if !exists('g:MySchema_host') || !strlen(g:MySchema_host)
    echohl Question
    let g:MySchema_host = input('mysql host: ', g:MySchema_default_host)
    echohl None
  endif
  return g:MySchema_host
endfunction

function! <SID>GetGlobalUser()
  if !exists('g:MySchema_user') || !strlen(g:MySchema_user)
    echohl Question
    let g:MySchema_user = input('mysql user: ', g:MySchema_default_user)
    echohl None
  endif
  return g:MySchema_user
endfunction

function! <SID>GetGlobalPass()
  if !exists('g:MySchema_pass')
    echohl Question
    let g:MySchema_pass = inputsecret('password: ')
    echohl None
  endif
  return g:MySchema_pass
endfunction

function! <SID>PromptDB(connect, prompt)
  " generate a list of all databases
  if a:connect.engine == 'mysql'
    let l:mysql = <SID>GetMysqlCMD(a:connect)
    let l:db_string = system(l:mysql.' --skip-column-names', 'show databases')
    let l:db_string = <SID>RemoveWarning(l:db_string)
    if v:shell_error
      " if the mysql command fails, it may be because the credentials are
      " invalid, so we reset them
      call MySchema#ResetOptions(1)
      echohl Error
      echo l:db_string
      echohl None
      return ''
    endif

    let l:db_list = split(l:db_string)
  else
    " postgresql
    let l:db_list = <SID>GetPsqlDatabases(a:connect)
  endif

  if ! len(l:db_list)
    echohl Error
    echo "No databases on this host"
    echohl None
    return ''
  endif

  return <SID>ChooseDatabase(a:prompt, l:db_list)
endfunction

let s:vim_ui_checked = 0

function! <SID>ChooseDatabase(prompt, db_list)
  " if we haven't looked for VimUI yet, do so now
  if ! s:vim_ui_checked
    runtime autoload/VimUI.vim
  endif

  " see if the VimUI#SelectOne() function is available
  if exists('*VimUI#SelectOne')
    let l:idx = VimUI#SelectOne(a:prompt, a:db_list, 1)
    return l:idx >= 0 ? a:db_list[l:idx] : ""
  endif

  " fallback to old-style prompt

  " ask the user to choose a database
  echohl Question
  echo a:prompt
  let l:choices = []
  let l:idx = 0
  for l:db_name in a:db_list
    call add(l:choices, l:idx.' '.l:db_name)
    let l:idx += 1
  endfor
  let l:idx = inputlist(l:choices)
  echohl None
  return a:db_list[l:idx]
endfunction

function! <SID>GetMysqlCMD(connect)
  let l:command = get(a:connect, 'command', '')
  if strlen(l:command)
    return l:command
  endif

  return printf('mysql -h%s -u%s -p%s',
        \ shellescape(a:connect.host),
        \ shellescape(a:connect.user),
        \ shellescape(a:connect.pass))
endfunction

function! <SID>GetPsqlCMD(connect, dbname, compact)
  let l:cmd = printf('psql -h %s -U %s %s',
        \ shellescape(a:connect.host),
        \ shellescape(a:connect.user),
        \ shellescape(a:dbname))
  if a:compact
    let l:cmd .= ' --tuples-only'
  endif
  if len(a:connect.pass)
    let l:cmd .= '-p '.shellescape(a:connect.pass)
  else
    let l:cmd .= ' --no-password'
  endif
  return l:cmd
endfunction

function! <SID>GetPsqlDatabases(connect)
  let l:cmd = <SID>GetPsqlCMD(a:connect, 'postgres', 1)
  let l:query  = "SELECT datname FROM pg_database"
  let l:query .= " WHERE datistemplate = 'f' AND datname != 'postgres'"
  let l:output = system(l:cmd, l:query)
  if v:shell_error
    let l:host = get(a:connect, 'command', get(a:connect, 'host', ''))
    echohl Error
    echo "Could not get database list from ".l:host
    echohl None
    echo l:output
    return ['postgres']
  endif
  return split(l:output)
endfunction

function! <SID>ShowTables(connect, database)
  " output a list of all tables
  if a:connect.engine == 'mysql'
    let l:mysql = <SID>GetMysqlCMD(a:connect)
    let l:table_string = system(l:mysql.' -t '.a:database, 'show tables')
    let l:table_string = <SID>RemoveWarning(l:table_string)
  else
    " postgresql
    let l:psql = <SID>GetPsqlCMD(a:connect, a:database, 0)
    let l:table_string = system(l:psql, '\d+')
  endif
  if v:shell_error
    " if the mysql command fails, it may be because the credentials are
    " invalid, so we reset them
    call MySchema#ResetOptions(1)
    echohl Error
    echo l:table_string
    echohl None
    return ''
  endif

  if <SID>NewWindow(l:table_string, 'Tables in '.a:database)
    " remember what database we are looking at in this buffer, in case user
    " asks for a table in this file
    let b:MySchema_database = a:database
  endif
endfunction

function! <SID>ShowTableFromDB(connect, database, table_name)
  let l:queries = []
  if a:connect.engine == 'mysql'
    call add(l:queries, [ printf("DESC %s.%s", a:database, a:table_name), '-t', 0 ])
    call add(l:queries, [ printf("SHOW CREATE TABLE %s.%s\\G", a:database, a:table_name), '-N', 2])
    call add(l:queries, [ printf("SHOW KEYS FROM %s.%s", a:database, a:table_name), '-t', 0])
  else
    call add(l:queries, [ '\d+ '.a:table_name, '', 0])
  endif

  " output a list of all tables
  let l:results = []
  for [ l:query, l:options, l:headsize ] in l:queries
    if a:connect.engine == 'mysql'
      let l:cmd = <SID>GetMysqlCMD(a:connect)
      let l:output = system(l:cmd.' '.l:options, l:query)
      let l:output = <SID>RemoveWarning(l:output)
    else
      " postgresql
      let l:cmd = <SID>GetPsqlCMD(a:connect, a:database, 0)
      let l:output = system(l:cmd.' '.l:options, l:query)
    endif
    let l:output = substitute(l:output, '\\n', '\n', 'g')
    if v:shell_error
      call MySchema#ResetOptions(1)
      echohl Error
      echo l:output
      echohl None
      return
    endif
    if l:headsize
      " if this option is used, we need to strip that many lines from the
      " start of the output
      let l:output = substitute(l:output, repeat('[^\n]\{-}\n', l:headsize), '', '')
    endif
    call add(l:results, l:output)
  endfor

  call <SID>NewWindow(join(l:results, "\n"), printf("%s.%s", a:database, a:table_name))
endfunction

function! <SID>RemoveWarning(output)
  return substitute(a:output, '\%(Warning:\|mysql: \[Warning\]\) Using a password on the command line interface can be insecure\.[\r\n]*', "", "g")
endfunction

function! <SID>FindDatabasesWithTable(connect, table_name)
  if a:connect.engine == 'mysql'
    let l:mysql  = <SID>GetMysqlCMD(a:connect)
    let l:query  = printf('SELECT TABLE_SCHEMA FROM information_schema.TABLES WHERE TABLE_NAME = "%s"', a:table_name)
    let l:output = system(l:mysql.' --skip-column-names', l:query)
    let l:output = <SID>RemoveWarning(l:output)
    if v:shell_error
      call MySchema#ResetOptions(1)
      echohl Error
      echo l:output
      echohl None
      return []
    endif

    " split into table names
    return split(l:output)
  endif

  " postgresql
  let l:matches = []
  for l:dbname in <SID>GetPsqlDatabases(a:connect)
    let l:psql  = <SID>GetPsqlCMD(a:connect, l:dbname, 1)
    let l:query  = "SELECT COUNT(*) FROM information_schema.tables"
    let l:query .= " WHERE table_schema NOT IN('pg_catalog', 'information_schema')"
    let l:query .= " AND table_name = '".a:table_name."'"
    let l:output = system(l:psql, l:query)
    if v:shell_error
      call MySchema#ResetOptions(1)
      echohl Error
      echo l:output
      echohl None
      return []
    endif
    if l:output !~ '^\_s*0\_s*$'
      call add(l:matches, l:dbname)
    endif
  endfor
  return l:matches
endfunction

function! <SID>NewWindow(contents, bufname)
  let l:split = 0
  try
    new
    let l:split = 1
    setlocal buftype=nofile bufhidden=wipe
    " other preferences
    setlocal nowrap foldcolumn=0 nonu
    call append(1, split(a:contents, "\n"))
    " delete first (empty) line in file
    normal! ggdd

    " try and set a name on the buffer ... but don't warn if it fails
    if strlen(a:bufname)
      silent! exe 'file' escape(a:bufname, '\ ')
    endif

    return 1
  catch
    if l:split
      close
    endif
  endtry

  " failed
  return 0
endfunction

function! MySchema#SQLWindow()
  " override some local settings in the window
  if ! exists('b:MySchema_results_for')
    setfiletype mysql
  endif

  nnoremap <buffer> <F12> :call <SID>RunSQL()<CR>
endfunction

function! <SID>RunSQL()
  " if we are in the results window, switch back to the other window first
  if exists('b:MySchema_results_for')
    let l:winnr = bufwinnr(b:MySchema_results_for)
    if l:winnr
      " jump back to SQL file's window
      exe l:winnr 'wincmd w'
    else
      exe 'buffer' b:MySchema_results_for
    endif
  endif

  let l:original_buffer = bufnr("")

  " collect credentials if we don't have them yet
  let l:connect = <SID>GetConnectInfo()

  " ask the user which database to run again?
  if exists('b:MySchema_database') && strlen(b:MySchema_database)
    let l:db = b:MySchema_database
  else
    let l:db = <SID>PromptDB(l:connect, 'Run SQL again which database?')
    if ! strlen(l:db)
      echohl Error
      echo 'You must select a database to continue'
      echohl None
      return
    endif
  endif

  " what's our buffer's filename
  let l:source = expand("%:p")

  " do we need to destroy any other buffers first?
  if exists('b:MySchema_destroy')
    if len(b:MySchema_destroy)
      exe 'bwipeout' join(b:MySchema_destroy)
      let b:MySchema_destroy = []
    endif
  else
    let b:MySchema_destroy = []
  endif

  " run the SQL queries now using the credentials provided
  if l:connect.engine == 'mysql'
    let l:cmd = <SID>GetMysqlCMD(l:connect).' -t '.shellescape(l:db)
    let l:output = system(l:cmd.' < '.l:source)
    let l:output = <SID>RemoveWarning(l:output)
  else
    let l:cmd = <SID>GetPsqlCMD(l:connect, l:db, 0)
    let l:output = system(l:cmd.' < '.l:source)
  endif
  if v:shell_error
    echohl Error
    echo l:output
    echohl None
    return ''
  endif

  " remember database name for next time
  let b:MySchema_database = l:db

  let l:name  = fnamemodify(l:source, ':t').' @ '.strftime("%H:%M:%S")
  if <SID>NewWindow(l:output, l:name)
    let l:new_buf = bufnr("")

    " remember what our original buffer was
    let b:MySchema_results_for = l:original_buffer
    
    " set up mapping for this window as well
    call MySchema#SQLWindow()

    " we'll resize the original SQL window if there isn't enough room to
    " display everything
    let l:do_resize = line('$') >= winheight(0)

    " add the new window's buffer number to the list of buffers to destroy
    " when we re-run
    wincmd p
    call insert(b:MySchema_destroy, l:new_buf)

    " also, set our SQL query window to minimum height so the results get
    " maximum height
    if l:do_resize
      " resize the current window to one more than the size of the last line
      execute 'resize' line('$') + 1
    endif

    " jump back to results window
    wincmd p
  endif

endfunction

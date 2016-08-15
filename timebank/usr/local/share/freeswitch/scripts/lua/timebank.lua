--[[

  Copyright (C) 2016 Open Lab Athens.

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <http://www.gnu.org/licenses/>.

  @license GPL-3.0+ <http://spdx.org/licenses/GPL-3.0+>


  Changes

  15-8-2016: Rowan Thorpe <rowan@rowanthorpe.com>: Original commit

]]

--[[
 TODO (descending order of priority)

   * if "κτλ." doesn't sound right, expand them all to "και λοιπά"
   * add table "attended_event" with:
      - id       [unique-primary-key]
      - user_id  [non-unique, must exist in usr:id]
      - event_id [non-unique, must exist in event:id]
     using the same logic/trigger as for "provided_service" (web frontend can then have entry-interface for that to transcribe from
     "attendees_names_recording" file), then delete the recording file
   * solve how to stop input-callback during recordfile() from logging "error" text
   * get hanguphook stuff working properly rather than homespun thingy
   * split database *-name columns to column-per-language, allow st.lang to dictate which db-field is retrieved for speech
   * add plluau trigger (as superuser) in postgres to lo_import() (as non-superuser), then revert to using large objects instead of
     filenames to /var/lib/timebank
   * inject 2nd param (boolean) to ifReady() to indicate that after checking for session/usable session-methods (or bailing out), then do
     sequences of multiple method/function calls (taken one per table-entry in 3rd param), otherwise do single call as per present behaviour
   * rewrite more things to use loopUntilGet() in non-generic mode (more DRYness)
   * use freeswitch.Dbh instead of luasql (for connection pooling)
   * transactional postgres statements if/when appropriate => st.db.conn:prepare(), st.db.conn:commit(), st.db.conn:rollback()
   * wherever there is a lot of sequential concatenating of strings, put each in a temp-table, then do one table.concat at the end
   * abstract and separate as many functions as possible into "lib" file for reuse on other projects
   * work out if possible to have an auto-close method to do closeCurs() and closeConn() when a cursor-iterator ends or goes out of scope?!

 ONGOING CHECKING

  * check that durations in all playandgetdigits() are sensible, and check syntax/args of each, and include chars in "terminators" field
  * check #*0 actions do as expected in various places (and press-x-or-wait-to-do-y stuff)
]]

---- REQUIRES ----

--local ls = require('luasql.postgres')
local pgmoon = require('pgmoon')
local posix = require('posix')
--[[ this version uses ffi within luajit...
local ffi = require('ffi')
]]

---- SETUP ----

-- CONFIG

--[[ this version uses ffi within luajit...
ffi.cdef[[
   int mkstemps(char *template, int suffixlen);
   int close(int fildes);
] ] -- remove the space here when uncommenting...
]]

local LUA_DIRSEP = string.sub(package.config, 1, 1)
local cf = {
   is_submenu = false,
   deflang = "el",
   db = {
      name = "timebank",
      user = "timebank",
      pwd = '----------',
      addr = "127.0.0.1",
      port = 5432,
   },
   lang = {
      en = {
	 speech = {
	    engine = "tts_commandline",
	    voice = "en1",
	 },
	 tree = {
	    [1] = "sector",
	    [2] = "category",
	    [3] = "service",
	 },
	 phrase = {
	    lang_prompt = "Press 2 for Greek.",
	    welcome = "Welcome to the time bank. At any point press hash to repeat a menu, press star to exit, or press 0 to go to the previous menu.",
	    userid_prompt = "Enter your user I.D.",
	    pin_prompt = "Enter your pin.",
	    shortcut_prompt = "Press 1 to shortcut to entering the %s code. Press 2 or wait to browse to the %s code.",
            timestamp_prompt = "Enter the date and time it occurred in twelve-digit form. Four digits for the year, two digits for the month, two digits for the day, two digits for the hours in twenty-four hour form, and two digits for the minutes.",
            duration_prompt = "Enter the duration in minutes.",
            attendees_num_prompt = "Enter the number of attendees.",
            attendees_names_prompt = "After you hear the tone and recording starts please say the names of the attendees. Press any key to stop recording.",
            confirm_recording_prompt = "Press 1 to continue.",
            confirm_all_prompt = "While the entered information is played back at any time press 1 to confirm and submit the information. The %s name is %s. The start time is year %d, month %d, day of month %d, at time %d %d. The duration is %s minutes. The number of attendees is %s. The attendee list recording will now be played back.",
	    invalid_input = "Invalid input.",
	    failed_login = "Failed login attempt.",
	    try_again = "Try again.",
	    too_many_failures = "Too many failed attempts.",
	    greet_user = "Hello %s.",
	    please_select_x = "Please select %s.",
	    press_x_for_y = "Press %d for %s.",
	    data_submitted = "The data has been submitted.",
	    data_not_submitted = "The submission can not be made due to conflicting data. Are you registered yet to provide the selected %s?",
	    goodbye = "Goodbye.",
	    internal_error = "Internal error. Please let us know about this, and when it happened.",
	 },
      },
      el = {
	 speech = {
	    engine = "tts_commandline",
	    voice = "gr2",
	 },
	 tree = {
	    [1] = "τομέα",
	    [2] = "κατηγορία",
	    [3] = "υπηρεσία",
	 },
	 phrase = {
	    lang_prompt = "Πληκτρολογήστε 1 για τα αγγλικά.",
	    welcome = "Καλώς ήρθατε στη Χρονική Τράπεζα. Σε κάθε στιγμή πατήστε δίεση για να επαναλάβετε ένα μενού, πατήστε αστεράκι για να βγείτε, ή πατήστε 0 για να πάτε στο προηγούμενο μενού.",
	    userid_prompt = "Πληκτρολογήστε το αναγνωριστικό σας.",
            pin_prompt = "Πληκτρολογήστε τον κωδικό σας.",
	    shortcut_prompt = "Πληκτρολογήστε 1 για να μεταφερθείτε απευθείς στην πληκτρολόγηση του κωδικού %s. Πατήστε 2 ή περιμένετε για να περιηγηθείτε προς τον κωδικό %s.",
            timestamp_prompt = "Πληκτρολογήστε την ημερομηνία και την ώρα που έλαβε χώρα σε δώδεκα-ψήφια μορφή. Τέσσερα ψηφία για το έτος, δύο ψηφία για το μήνα, δύο ψηφία για την ημέρα, δύο ψηφία για την ώρα σε εικοσιτετράωρη μορφή, και δύο ψηφία για τα λεπτά.",
            duration_prompt = "Πληκτρολογήστε τη διάρκεια σε λεπτά.",
            attendees_num_prompt = "Πληκτρολογήστε πόσα άτομα την παρακολούθησαν.",
            attendees_names_prompt = "Αφού ακούσετε τον ήχο και ξεκινήσει η καταγραφή παρακαλώ πείτε τα ονόματα των συμμετεχόντων. Πατήστε οποιοδήποτε πλήκτρο για να σταματήσετε την καταγραφή.",
            confirm_recording_prompt = "Πληκτρολογήστε 1 για να συνεχίσετε.",
            confirm_all_prompt = "Καθώς οι πληροφορίες που εισάγατε αναπαράγονται ανά πάσα στιγμή πατήστε 1 για να επιβεβαιώσετε και να υποβάλλετε τις πληροφορίες του συμβάντος. Το όνομα %s είναι %s. Η ώρα έναρξης είναι το έτος %d, ο μήνας %d, η ημέρα του μήνα %d, η ώρα %d %d. Η διάρκεια είναι %s λεπτά. Ο αριθμός των συμμετεχόντων είναι %s. Η ηχογραφημένη λίστα συμμετεχόντων θα ακουστεί τώρα.",
	    invalid_input = "Μη έγκυρη επιλογή.",
	    failed_login = "Αποτυχημένη προσπάθεια σύνδεσης.",
	    try_again = "Προσπαθήστε ξανά.",
	    too_many_failures = "Φτάσατε το όριο αποτυχημένων προσπαθειών.",
	    greet_user = "Γεια σας %s.",
	    please_select_x = "Παρακαλούμε επιλέξτε %s.",
	    press_x_for_y = "Πατήστε %d για %s.",
	    data_submitted = "Τα δεδομένα έχουν υποβληθεί.",
	    data_not_submitted = "Η υποβολή δεν ήταν δυνατή λόγω αντικρουόμενων δεδομένων. Έχετε εγγραφεί για να παρέχετε την επιλεγμένη %s?",
	    goodbye = "Αντίο.",
	    internal_error = "Εσωτερικό σφάλμα. Παρακαλώ ενημερώστε μας για αυτό καθώς και το πότε έγινε."
	 },
      },
   },
   tree = {
      [1] = { colname = "sector",   max_digits = 1, selected = nil },
      [2] = { colname = "category", max_digits = 2, selected = nil },
      [3] = { colname = "service",  max_digits = 3, selected = nil },
   },
}

-- STATE
local st = {
   user = nil,
   callerid = nil,
   lang = cf.lang[cf.deflang],
--   hangup_reason = "normal", -- TODO: once hanguphook is working use this to give more debug info
   recording_file_submitted = false,
   db = {
      env = nil,
      conn = nil,
      curs = nil,
   },
}

---- FUNCTIONS & OBJECT/FUNCTION_SHORTCUTS ----
--  NB: cf and st are tables (reference type), so functions can edit them in-place, just use function retvals for success/failure

local s = session
local fsl = freeswitch.consoleLog
local sf = string.format
local ss = string.sub

local function logWhere(where)
   fsl("NOTICE", sf("in %s()\n", where))
end

local function funcInfo(aspect, func)
   if not func then
      func = 2
   end
   local infotable
   local retval
   if aspect == "name" then
      infotable = debug.getinfo(func, "n")
      retval = infotable.name
      if retval == nil then
	 infotable = debug.getinfo(func, "S")
	 retval = infotable.short_src .. ":" .. infotable.linedefined
      end
   elseif aspect == "file" then
      infotable = debug.getinfo(func, "S")
      retval = infotable.short_src
   elseif aspect == "line" then
      infotable = debug.getinfo(func, "S")
      retval = infotable.linedefined
   end
   return retval
end

local function lw()
   logWhere(funcInfo("name", 3))
end

local function catch(err)
   lw()
   if err then
      error(sf("Failure was: %s\n", err))
   else
      -- NB: this shows up as an "error" in the log, but error() inside a hanguphook doesn't, once using hanguphook properly it will not be a problem
      error()
   end
end

local function interpolate(text, ...)
   lw()
   if select("#", ...) ~= 0 then
      text = sf(text, ...)
   end
   return text
end

local function map(fn, array)
   lw()
   local new_array = {}
   for i,v in ipairs(array) do
      new_array[i] = fn(v)
   end
   return new_array
end

local function fileExists(name)
   lw()
   if name == nil then
      return false
   end
   local f = io.open(name, "r")
   if f == nil then
      return false
   else
      io.close(f)
      return true
   end
end

local function ttsURI(text, ...)
   lw()
   text = interpolate(text, ...)
   local retval = sf("tts://%s|%s|%s", st.lang.speech.engine, st.lang.speech.voice, text)
   fsl("DEBUG", sf("generated '%s' URI\n", retval))
   return retval
end

local function closeDBObj(objtype)
   lw()
   if st.db[objtype] then
      st.db[objtype]:close()
      st.db[objtype] = nil
   end
end

local function dbCleanup()
   lw()
   for _, thing in ipairs({"curs", "conn", "env"}) do
      fsl("NOTICE", sf("cleaning up %s\n", thing))
      closeDBObj(thing)
   end
end

local function cleanupAndExit(msg)
   lw()
   if (not st.recording_file_submitted) and fileExists(recording_file) then
      os.remove(recording_file)
   end
   dbCleanup()
   if msg then
      pcall(s.speak, s, st.lang.phrase.internal_error)
   end
   pcall(s.hangup, s)
   catch(msg)
end

--[[ FIXME: this behaves weird, for now I'm handling cleanupAndExit(), with checks by ifReady(), rather than losing time on auto-hook
local function onHangup(s, ...) -- , status, arg
   lw()
   dbCleanup()
   --if status == "normal" then
      error()           -- FIXME: this should work, and not throw error in log according to docs, but it doesn't...
   --else
   --   s:destroy(status) -- ?!?: this throws segfault and kills freeswitch
   --   return "exit"
   --end
end
]]

local function assertNonEmpty(retval, caller_name)
   lw()
   local retval_type = type(retval)
   if retval == nil or retval == "" or (retval_type == 'table' and next(retval) == nil) then
      cleanupAndExit(sf("%s() returned empty [type '%s']", caller_name, retval_type))
   else
      return retval
   end
end

local function ifReady(assert_non_empty, to_call, ...)
   lw()
   local calltype = type(to_call)
   if not s then
      cleanupAndExit(sf("The session object has disappeared entirely. That should NOT happen.\n"))
   else
      for _, methodname in ipairs({"hangup", "ready", "sleep"}) do
         if not s[methodname] then
            cleanupAndExit(sf("The session:%s method has disappeared entirely. That should NOT happen.\n", methodname))
         end
      end
      if not s:ready() then
         s:sleep(300)
         if not s:ready() then
            fsl("NOTICE", sf("Caller has hung up\n"))
            cleanupAndExit()
         end
      elseif calltype == "function" or calltype == "table" or calltype == "userdata" then
	 local suffix = ""
	 if assert_non_empty then
	    local suffix = " [with assert]"
	 end
	 local callername
	 local retval
	 if calltype == "function" then
	    callername = funcInfo("name", to_call)
	    fsl("DEBUG", sf("running %s() with %d arguments%s\n", callername, select("#", ...), suffix))
	    retval = to_call(...)
	 else -- if calltype == "table" or calltype == "userdata" then
	    local argsnum = select("#", ...) - 1
	    callername = ({...})[1]
	    fsl("DEBUG", sf("running [object]:%s() with %d arguments%s\n", callername, argsnum, suffix))
	    if argsnum == 0 then
	       retval = to_call[callername](to_call)
	    else
	       retval = to_call[callername](to_call, select(2, ...)) -- NB: remember unpack(arguments) trims nils...
	    end
	 end
	 if assert_non_empty then
	    return assertNonEmpty(retval, callername)
	 else
	    return retval
	 end
      else
	 error(sf("Unknown calltype '%s'", calltype))
      end
   end
end

local function getDBEnv()
   lw()
   st.db.env = assertNonEmpty(ls.postgres(), "ls.postgres")
end

local function getDBConn()
   lw()
   -- TODO: replace these hardcoded vals with settings from cf table, but test for typos while doing it
   st.db.conn = assertNonEmpty(st.db.env:connect('----------', '----------', '----------', "127.0.0.1", 5432), "st.db.env:connect")
end

local function getDBCurs(assert_non_empty, sql, ...)
   lw()
   if select("#", ...) ~= 0 then
      sql = sf(sql, ...)
   end
   fsl("DEBUG", sf("Executing SQL: %s\n", sql))
   st.db.curs = ifReady(assert_non_empty, st.db.conn, "execute", sql)
end

function getDBIter(rowtype)
   lw()
   return
      function ()
	 return st.db.curs:fetch({}, rowtype)
      end
end

local function applySQL(sql, ...)
   lw()
   getDBConn()
   getDBCurs(false, sql .. " RETURNING TRUE", ...)
   local retval = st.db.curs and st.db.curs:numrows() == 1
   closeDBObj("curs"); closeDBObj("conn")
   return retval
end

local function getDBIterator(maximum_one, rowtype, sql, ...)
   lw()
   getDBConn(); getDBCurs(true, sql, ...)
   local numrows = st.db.curs:numrows()
   if maximum_one and numrows > 1 then
      cleanupAndExit(sf("Expected at most 1 row, received %d", numrows))
   end
   local iter = getDBIter(rowtype)
   -- NB: remember to run closeDBObj("curs") and closeDBObj("conn") after you finish with the iterator (or have an automatic method, see TODO)
   return iter, numrows
end

local function getRows(maximum_one, rowtype, sql, ...)
   lw()
   local rows = {}
   local iter, numrows = getDBIterator(maximum_one, rowtype, sql, ...)
   for i in iter do
      rows[#rows + 1] = i
   end
   closeDBObj("curs"); closeDBObj("conn")
   return rows
end

local function keyPress(s, input_type, data, arg)
   lw()
   return input_type ~= "dtmf"
end

local function langSelect()
   lw()
   ifReady(false, s, "flushDigits")
   lang = ifReady(false, s, "playAndGetDigits", 0, 1, 1, 3000, "", ttsURI(st.lang.phrase.lang_prompt), "", "\\d*")
   if lang == "1" then
      fsl("DEBUG", sf("Setting lang to English.\n"))
      st.lang = cf.lang.en
      ifReady(false, s, "set_tts_params", st.lang.speech.engine, st.lang.speech.voice)
   else
      fsl("DEBUG", sf("Setting lang to Greek.\n"))
      st.lang = cf.lang.el
      ifReady(false, s, "set_tts_params", st.lang.speech.engine, st.lang.speech.voice)
   end
   return true
end

local function loopUntilGet(preGetFunc, getFunc, goodResultFunc, min, max, tries, wait, phrase, valid_regex, inter_digit_wait)
   lw()
   local var
   local loop_state = "#"
   local attempts_left = 3
   while loop_state == "#" and attempts_left ~= 0 do
      if preGetFunc ~= nil then
	 preGetFunc()
      end
      ifReady(false, s, "setVariable", "read_terminator_used", nil)
      ifReady(false, s, "flushDigits")
      if getFunc == nil then
	 var = ifReady(false, s, "playAndGetDigits", min, max, tries, wait, "#*", ttsURI(st.lang.phrase[phrase]), ttsURI(st.lang.phrase.invalid_input), valid_regex, nil, inter_digit_wait)
      else
	 var = getFunc(min, max, tries, wait, phrase, valid_regex, inter_digit_wait)
      end
      local terminator = ifReady(false, s, "getVariable", "read_terminator_used")
      if terminator == "*" then
	 loop_state = "*"
      elseif var == "0" then
	 loop_state = "0"
      elseif not terminator then
	 if var == "" then
	    ifReady(false, s, "speak", st.lang.phrase.too_many_failures)
	    loop_state = false
	 else
	    if goodResultFunc ~= nil then
	       goodResultFunc()
	    end
	    loop_state = true
	 end
      end
      attempts_left = attempts_left - 1
      if attempts_left ~= 0 and loop_state == "#" then
	 ifReady(false, s, "speak", st.lang.phrase.try_again)
      end
   end
   if attempts_left == 0 then
      ifReady(false, s, "speak", st.lang.phrase.too_many_failures)
      loop_state = false
   end
   return var, loop_state
end

local function authUser() -- true => success, false => failure, "*" => early-exit
   lw()
   local user_id
   local username
   local return_type = false
   local rows_by_num = getRows(true, "n", "SELECT id, username, allow_pinless FROM usr WHERE phone = '%s'", st.callerid)
   if #rows_by_num == 1 then
      local row_by_num = rows_by_num[1]
      if row_by_num[3] == "t" then
	 user_id = tonumber(row_by_num[1])
	 username = row_by_num[2]
	 fsl("INFO", sf("User %d access automatically granted by phone number\n", user_id))
	 return_type = true
      end
   else -- #rows_by_num must be 0 here due to getRows(true,...)

      local loop_state = "#"
      local attempts_left = 3
      while loop_state == "#" and attempts_left ~= 0 do
	 ifReady(false, s, "setVariable", "read_terminator_used", nil)
	 ifReady(false, s, "flushDigits")
	 user_id = ifReady(false, s, "playAndGetDigits", 1, 4, 3, 4000, "#*", ttsURI(st.lang.phrase.userid_prompt), ttsURI(st.lang.phrase.invalid_input), "^0|\\d{4}$", nil, 3000)
	 local terminator = ifReady(false, s, "getVariable", "read_terminator_used")
	 if terminator == "*" then
	    loop_state = "*"
	 elseif user_id == "0" then
	    loop_state = "0"
	 elseif not terminator then
	    if user_id == "" then
	       ifReady(false, s, "speak", st.lang.phrase.too_many_failures)
	       loop_state = false
	    else
	       ifReady(false, s, "flushDigits")
	       local pin = ifReady(false, s, "playAndGetDigits", 1, 4, 3, 4000, "#*", ttsURI(st.lang.phrase.pin_prompt), ttsURI(st.lang.phrase.invalid_input), "^0|\\d{4}$", nil, 3000)
	       local terminator = ifReady(false, s, "getVariable", "read_terminator_used")
	       if terminator == "*" then
		  loop_state = "*"
	       elseif pin == "0" then
		  loop_state = "0"
	       elseif not terminator then
		  if pin == "" then
		     ifReady(false, s, "speak", st.lang.phrase.too_many_failures)
		     loop_state = false
		  else
		     user_id = tonumber(user_id) -- NB: retain pin as "numeric string" here, type:number eats leading zeroes
		     local rows_by_userid = getRows(true, "n", "SELECT digest('%s', 'sha256'), pin, username, allow_pin FROM usr WHERE id = %d", pin, user_id)
		     if #rows_by_userid == 1 then
			local row_by_userid = rows_by_userid[1]
			if row_by_userid[4] == "t" and row_by_userid[1] == row_by_userid[2] then
			   username = row_by_userid[3]
			   fsl("INFO", sf("User %d login successful\n", user_id))
			   loop_state = true
			else
			   ifReady(false, s, "speak", st.lang.phrase.failed_login)
			end
		     end
		  end
	       end
	    end
	 end
	 attempts_left = attempts_left - 1
	 if attempts_left ~= 0 and loop_state == "#" then
	    ifReady(false, s, "speak", st.lang.phrase.try_again)
	 end
      end
      if attempts_left == 0 then
	 ifReady(false, s, "speak", st.lang.phrase.too_many_failures)
	 return_type = false
      else
	 return_type = loop_state
      end
   end
   if return_type == true then
      ifReady(false, s, "speak", sf(st.lang.phrase.greet_user, username))
      st.user = user_id
   end
   return return_type
end

local function browseMenus()
   lw()
   local index = 1
   local shortcut = false
   do
      local last_menu_name = st.lang.tree[#cf.tree]
      local attempts_left = 3
      local tts_phrase = sf(st.lang.phrase.shortcut_prompt, last_menu_name, last_menu_name)
      ifReady(false, s, "setVariable", "read_terminator_used", nil)
      ifReady(false, s, "flushDigits")
      do_shortcut = ifReady(false, s, "playAndGetDigits", 0, 1, 3, 4000, "*", ttsURI(tts_phrase), ttsURI(st.lang.phrase.invalid_input), "^[012]?$")
      local terminator = ifReady(false, s, "getVariable", "read_terminator_used")
      if terminator then
	 return "*"
      elseif do_shortcut == "0" then
	 return do_shortcut
      elseif do_shortcut == "1" then
	 index = #cf.tree
	 shortcut = true
      end
   end
   local loop_state = "#"
   do
      local selected
      local attempts_left = 3
      while loop_state == "#" and attempts_left ~= 0 and index ~= 0 and index ~= #cf.tree + 1 do
	 local this_menu = cf.tree[index]
	 local terminator
	 do
	    local msg = sf(st.lang.phrase.please_select_x, st.lang.tree[index])
	    if not shortcut then
	       local sql = sf("SELECT id, %sname FROM %s", this_menu.colname, this_menu.colname)
	       if index ~= 1 then
		  do
		     local parent_menu = cf.tree[index - 1]
		     sql = sf("%s WHERE %s_id = %d", sql, parent_menu.colname, parent_menu.selected)
		  end
	       end
	       sql = sql .. " ORDER BY id"
	       local rows = getRows(false, "n", sql)
	       msg = msg .. " " .. table.concat(map(function(x) return sf(st.lang.phrase.press_x_for_y, x[1], x[2]) end, rows), " ")
	    end
	    local non_first_digits_str = ""
	    local digits_num_minus_one = this_menu.max_digits - 1
	    if digits_num_minus_one ~= 0 then
	       non_first_digits_str = sf("[0-9]{0,%d}", digits_num_minus_one)
	    end
	    ifReady(false, s, "setVariable", "read_terminator_used", nil)
	    ifReady(false, s, "flushDigits")
	    selected = ifReady(false, s, "playAndGetDigits", 1, this_menu.max_digits, 3, 4000, "#*", ttsURI(msg), ttsURI(st.lang.phrase.invalid_input), sf("^0|[1-9]%s$", non_first_digits_str), nil, 3000)
	    terminator = ifReady(false, s, "getVariable", "read_terminator_used")
	 end
	 if terminator == "#" then
	    attempts_left = attempts_left - 1
	    if attempts_left ~= 0 then
	       ifReady(false, s, "speak", st.lang.phrase.try_again)
	    end
	 elseif terminator == "*" then
	    loop_state = "*"
	 elseif selected == "" then
	    ifReady(false, s, "speak", st.lang.phrase.too_many_failures)
	    loop_state = false
	    break
	 elseif selected == "0" then
	    index = index - 1
	 else
	    this_menu.selected = tonumber(selected)
	    index = index + 1
	 end
      end
   end
   if index == 0 then
      loop_state = "0"
   elseif loop_state == "#" and index == #cf.tree + 1 then
      loop_state = true
   end
   return loop_state
end

local function processEvent()
   lw()
   local loop_state, starttime, duration, attendees, recording_confirmed, user_id, last_menu_colname, last_menu_selected_id

   starttime, loop_state = loopUntilGet(nil, nil, nil, 12, 12, 3, 4000, "timestamp_prompt", "^(2\\d{3}(0\\d|1[0-2])([0-2]\\d|3[0-1])([0-1]\\d|2[0-3])[0-5]\\d)|0$", 3000)
   if loop_state ~= true then return loop_state end

   duration, loop_state = loopUntilGet(nil, nil, nil, 1, 3, 3, 4000, "duration_prompt", "^0|[1-9]\\d{0,2}$", 3000)
   if loop_state ~= true then return loop_state end

   attendees, loop_state = loopUntilGet(nil, nil, nil, 1, 3, 3, 4000, "attendees_num_prompt", "0|[1-9]\\d{0,2}", 3000)
   if loop_state ~= true then return loop_state end

   do
      local retval
--[[ this version uses ffi within luajit...
      local C = ffi.C
      recording_file = LUA_DIRSEP .. "var" .. LUA_DIRSEP .. "lib" .. LUA_DIRSEP .. "timebank" .. LUA_DIRSEP .. "XXXXXX.wav"
      local fd = C.mkstemps(file_template, 4)
      if fd == -1 then
         cleanupAndExit("Failed attempting to create tempfile via ffi mkstemps()")
      end
]]
      local fd
      fd, recording_file = posix.mkstemp(LUA_DIRSEP .. "var" .. LUA_DIRSEP .. "lib" .. LUA_DIRSEP .. "timebank" .. LUA_DIRSEP .. "XXXXXX")
      if fd == -1 then
	 cleanupAndExit("Failed attempting to create tempfile via posix.mkstemp()")
      end
--[[ this version uses ffi within luajit...
      local retval = C.close(fd)
      if retval == -1 then
         cleanupAndExit("Failed attempting to close tempfile handle via ffi close()")
      end
]]
      local retval = posix.close(fd)
      if retval == -1 then
	 cleanupAndExit("Failed attempting to close tempfile handle via posix.close()")
      end
      -- NB: this is a (tiny) race-condition but the best we can easily achieve without luajit/ffi/mkstemps
      if fileExists(recording_file .. ".wav") or not os.rename(recording_file, recording_file .. ".wav") then
	 cleanupAndExit("Failed moving tempfile to suffixed location")
      else
	 recording_file = recording_file .. ".wav"
      end
      local function recordFile()
	 ifReady(false, s, "speak", st.lang.phrase.attendees_names_prompt)
	 ifReady(false, s, "execute", "playback", "tone_stream://%(500,0,440)")
	 ifReady(false, s, "flushDigits")
	 ifReady(false, s, "setInputCallback", "keyPress", "")
	 ifReady(false, s, "recordFile", recording_file, 60, 30, 4)
	 ifReady(false, s, "unsetInputCallback")
      end
      recording_confirmed, loop_state = loopUntilGet(recordFile, nil, nil, 0, 1, 1, 4000, "confirm_recording_prompt", "^[01]$", 3000)
      if loop_state ~= true then return loop_state end
   end

   user_id = st.user
   last_menu_colname = cf.tree[#cf.tree].colname
   last_menu_selected_id = cf.tree[#cf.tree].selected
   do
      local last_menu_name = st.lang.tree[#cf.tree]
      local last_menu_selected_name_rows = getRows(true, "n", "SELECT %sname from %s WHERE id = %d", last_menu_colname, last_menu_colname, last_menu_selected_id)
      local last_menu_selected_name
      if #last_menu_selected_name_rows == 1 then
	 last_menu_selected_name = last_menu_selected_name_rows[1][1]
      else
	 return false
      end
      local event_confirmed
      local loop_state = "#"
      local attempts_left = 3
      while loop_state == "#" and attempts_left ~= 0 do
	 --[[
            NB: To do chained error-checking here terminators and builtin regexes are too messy, so I do my own sanity-checking instead
	        seeing it is only single-digit, therefore doesnt need "early-exit" handling
	 ]]
	 ifReady(false, s, "flushDigits")
	 event_confirmed = ifReady(false, s, "playAndGetDigits", 0, 1, 1, 4000, "", ttsURI(st.lang.phrase.confirm_all_prompt, last_menu_name, last_menu_selected_name, ss(starttime, 1, 4), ss(starttime, 5, 6), ss(starttime, 7, 8), ss(starttime, 9, 10), ss(starttime, 11, 12), duration, attendees), "", "")
	 if event_confirmed == "" then
	    event_confirmed = ifReady(false, s, "playAndGetDigits", 0, 1, 1, 4000, "", recording_file, "", "")
	 end
	 if event_confirmed == "*" or event_confirmed == "0" then
	    loop_state = event_confirmed
	 elseif event_confirmed == "1" then
	    loop_state = true
	 else
	    attempts_left = attempts_left - 1
	    if attempts_left ~= 0 and loop_state == "#" then
	       ifReady(false, s, "speak", st.lang.phrase.try_again)
	    end
	 end
      end
      if attempts_left == 0 then
	 ifReady(false, s, "speak", st.lang.phrase.too_many_failures)
	 loop_state = false
      end
      if loop_state ~= true then
	 return loop_state
      end
   end
   if posix.chmod(recording_file, "rw-r--r--") ~= 0 then
      cleanupAndExit(sf("Failed trying to chmod '%s' to rw-r--r--", recording_file))
   end
   local retval
   do
      local sql = sf("INSERT INTO event (starttime, duration, attendees, usr_id, %s_id, attendees_names_recording) VALUES ('%s-%s-%s %s:%s:00.00000+03', %d, %d, %d, %d, '%s')", last_menu_colname, ss(starttime, 1, 4), ss(starttime, 5, 6), ss(starttime, 7, 8), ss(starttime, 9, 10), ss(starttime, 11, 12), tonumber(duration), tonumber(attendees), user_id, last_menu_selected_id, recording_file)
      retval = applySQL(sql)
      if retval then
	 ifReady(false, s, "speak", st.lang.phrase.data_submitted)
	 st.recording_file_submitted = true
      else
	 ifReady(false, s, "speak", sf(st.lang.phrase.data_not_submitted, st.lang.tree[#st.lang.tree]))
      end
   end
   return retval ~= nil and retval ~= false
end

local function main()
   lw()
   local authorised = false
   ifReady(false, s, "sleep", "2000")

   -- Language select

   langSelect()
   while true do

      -- Welcome

      ifReady(false, s, "speak", st.lang.phrase.welcome)
      ifReady(false, s, "sleep", 1000)

      -- Authorisation

      if not authorised then -- NB: keep authorisation inside the main loop even though it is one-time, so it happens after the (repeatable) greeting
	 local authorised = authUser()
	 if authorised ~= true then
	    return authorised
	 end
      end

      -- Main loop

      local retval = "#"
      while retval == "#" do

         -- Browse menus

	 retval = browseMenus()
	 if retval == false or retval == "*" then
	    return retval
	 elseif retval =="0" then
	    break
	 elseif retval == true then

	    local retval = "#"
	    while retval == "#" do

               -- Process event data

	       retval = processEvent()
	       if retval == true or retval == false or retval == "*" then
		  return retval
	       elseif retval == "0" then
		  break
	       elseif retval ~= "#" then
		  fsl("WARNING", sf("Unknown return value '%s' for processEvent().\n", retval))
		  return false
	       end
	    end
	 elseif retval ~= "#" then
	    fsl("WARNING", sf("Unknown return value '%s' for browseMenus().\n", retval))
	    return false
	 end
      end
   end
end

------------------------

st.callerid = assertNonEmpty(s:getVariable("translated"), "session:getVariable")
s:set_tts_params(st.lang.speech.engine, st.lang.speech.voice)
--s:setHangupHook("onHangup", "st.hangup_reason")
s:setAutoHangup(false)
if cf.is_submenu then
   fsl("DEBUG", sf("Running as a submenu.\n"))
--   s:setAutoHangup(false)
else
   fsl("DEBUG", sf("Not running as a submenu.\n"))
--   s:setAutoHangup(true)
   s:answer()
end
getDBEnv()

fsl("NOTICE", sf("Timebank menu started.\n"))
do
   local recording_file
   local retval = main()
   do
      local text = "Timebank menu finished"
      if retval == "0" then
	 text = text .. " with request for parent menu"
	 if cf.is_submenu then
	    fsl("NOTICE", sf("%s.\n", text))
	 else
	    fsl("WARNING", sf("%s, which isn't possible.\n", text))
	 end
      elseif retval == "*" then
	 fsl("NOTICE", sf("%s by request.\n", text))
      elseif retval == true then
	 fsl("NOTICE", sf("%s successfully.\n", text))
      elseif retval == false then
	 fsl("NOTICE", sf("%s unsuccessfully.\n", text))
      end
   end
   if not retval == "0" or not cf.is_submenu then
      ifReady(false, s, "speak", st.lang.phrase.goodbye)
      ifReady(false, s, "sleep", 2000)
      fsl("DEBUG", "End of Call. Server hanging up.\n")
      cleanupAndExit()
   end
end

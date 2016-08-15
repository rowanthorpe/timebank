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

local pgmoon = require('pgmoon')
local json = require('cjson')
local fsl = freeswitch.consoleLog
local sf = string.format

local db = {
   cf = {
      host = '127.0.0.1',
      port = 5432,
      database = 'api',
      user = 'api',
      password = '----------',
   },
   st = {
      object = nil,
      connected = false,
   },
}

local function logWhere(where)
   fsl('DEBUG', sf("in %s()\n", where))
--   print('DEBUG', sf("in %s()\n", where))
end

local function funcInfo(aspect, func)
   if not func then
      func = 2
   end
   local infotable, retval
   if aspect == 'name' then
      infotable = debug.getinfo(func, 'n')
      retval = infotable.name
      if retval == nil then
	 infotable = debug.getinfo(func, 'S')
	 retval = infotable.short_src .. ':' .. infotable.linedefined
      end
   elseif aspect == 'file' then
      infotable = debug.getinfo(func, 'S')
      retval = infotable.short_src
   elseif aspect == 'line' then
      infotable = debug.getinfo(func, 'S')
      retval = infotable.linedefined
   end
   return retval
end

local function lw()
   logWhere(funcInfo('name', 3))
end

local function interpolate(text, ...)
   lw()
   if select('#', ...) ~= 0 then
      text = sf(text, ...)
   end
   return text
end

local function dbObjInstantiate() lw()
   db.st.object = pgmoon.new(db.cf)
end

local function dbObjDestroy() lw()
   db.st.object = nil
end

local function dbConnect() lw()
   return db.st.object:connect()
--   return true
end

local function dbDisconnect() lw()
   return db.st.object:disconnect()
--   return true
end

local function dbQuery(sql) lw()
   return db.st.object:query(sql)
--   print(sql)
--   return true
end

local function dbCleanup() lw()
   local success, err = true
   if db.st.connected then
      success, err = dbDisconnect()
      if success then
         db.st.connected = false
      end
   end
   if db.st.object and not db.st.connected then
      dbObjDestroy()
   end
   return success, err
end

local function cleanupIfFailed(result, err) lw()
   if result == nil then
      if err then
         err = sf("Error: %s\n", err)
      end
      local dbResult, dbErr = dbCleanup()
      if not dbResult and dbErr then
         err = err .. sf("Error: %s\n", dbErr)
      end
      error(err)
      return true
   else
      return false
   end
end

local function applySQL(sql) lw()
   local retval
   local result, err = dbConnect()
   if not cleanupIfFailed(result, err) then
      retval, err = dbQuery(sql)
      if not cleanupIfFailed(retval, err) then
         result, err = dbDisconnect()
         if not cleanupIfFailed(result, err) then
            return retval
         end
      end
   end
end

local function main() lw()
   dbObjInstantiate()
   local fromNum = string.gsub(message:getHeader('from'), '^(%d+)@.*$', '%1')
--   local fromNum = '1234567890'
   if applySQL(
      interpolate(
         'INSERT INTO %s (%s,%s) VALUES (%s,%s) RETURNING TRUE',
         db.st.object:escape_identifier('sms_replies'),
         db.st.object:escape_identifier('title'),
         db.st.object:escape_identifier('data'),
         db.st.object:escape_literal(freeswitch.API():getTime()),
--         db.st.object:escape_literal(12345678),
         db.st.object:escape_literal(
            json.encode(
               {
                  from = fromNum,
                  message = message:serialize(),
--                  message = 'hello there "you", \\ \'me\'; -- !',
               }
            )
         )
      )
   ) then
      fsl('NOTICE', sf("Message from %s submitted to DB\n", fromNum))
--      print('NOTICE', sf("Message from %s submitted to DB\n", fromNum))
      return true
   else
      error(sf("Failed submitting message from %s to DB\n", fromNum))
      return nil
   end
end

main()

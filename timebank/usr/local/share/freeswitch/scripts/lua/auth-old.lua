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

-- package.path = ';;/usr/local/share/luajit-2.1.0-beta2/?.lua;/usr/local/share/lua/5.1/?.lua;/usr/local/share/lua/5.1/?/init.lua'
-- package.cpath = ';;/usr/local/lib/lua/5.1/?.so;/usr/local/lib/lua/5.1/loadall.so'

-- local ls = require('luasql.postgres')
-- local pgmoon = require('pgmoon')
local dbh = freeswitch.Dbh(
  "pgsql://hostaddr=127.0.0.1 dbname=timebank user=timebank password='----------' options='-c client_min_messages=NOTICE' application_name='freeswitch' connect_timeout=10"
)
-- TODO: the below are needed when doing sha256 internally (it works when run inside resty, probably libssl is loaded there?)
-- local str = require('resty.string')
-- local sha256 = require('resty.sha256')
local sf = string.format

-- local db = {
--   host = '127.0.0.1',
--   port = 5432,
--   database = 'timebank',
--   user = 'timebank',
--   password = '--------',
-- }

local pg = {
--  ob = nil,
--  instantiate = function ()
--    pg.ob = assert(pgmoon.new(db))
--  end,
--  destroy = function ()
--    pg.ob = nil
--  end,
  connect = function ()
--    if pg.ob['sock'] == nil then
--      pg.instantiate()
--    end
--    assert(pg.ob:connect())
    assert(dbh:connected())
  end,
--  disconnect = function ()
--    if ob['sock'] ~= nil then
--      assert(ob:disconnect())
--    end
--  end,
  query = function (...)
--    local result, err = ob:query(...)
--    if result == nil then
--      error(err)
--    end
--    return result
    assert(dbh:query(...))
  end,
--  escape_identifier = function (...)
--    return ob:escape_identifier(...)
--  end,
--  escape_literal = function (...)
--    return ob:escape_literal(...)
--  end,
}

local function onHangup(s, status, arg)
  freeswitch.consoleLog("NOTICE", "pgHangup: " .. status .. "\n")
  dbc:close()
  error()
end

local env = assert(ls.postgres())
local dbc = assert(env:connect('----------', '----------', '----------', "127.0.0.1", 5432))
session:setHangupHook("onHangup")
session:setAutoHangup(false)
session:set_tts_params("flite", "kal")
session:answer()

local user_id
local remaining_attempts = 3
while remaining_attempts > 0 do
  user_id = session:playAndGetDigits(4, 4, 3, 10000, '#', 'tts://Enter your I.D.', '', '\\d+|#', 2000)
  if user_id == "" then
    session:speak("No I.D. specified.")
  else
--    local row
--    do
--      local cursor = assert(dbc:execute(string.format("SELECT pin FROM usr WHERE id = %d", user_id)))
--      row = cursor:fetch({}, "a")
--    end

    pg.connect()
    local storedPIN
    pg.query(sf(
--      "SELECT %s FROM %s WHERE %s = %s",
--      pg.escape_identifier('pin'),
--      pg.escape_identifier('usr'),
--      pg.escape_identifier('id'),
--      pg.escape_literal(user_id)
    ), function (val) { storedPIN = val[1]['pin']})
--    pg.disconnect()
    local pin = session:playAndGetDigits(4, 4, 3, 10000, '#', 'tts://Enter your pin', '', '\\d+|#', 2000)
    if pin == "" then
      session:speak("No pin specified.")
    else
--      local row
--      do
--        local cursor = assert(dbc:execute(string.format("SELECT digest(%s,'sha256'),pin FROM usr WHERE id = %d", pin, user_id)))
--        row = cursor:fetch({}, "a")
--      end
      pg.connect()
      local hashedPin
      pg.query(sf(
        "SELECT digest('%s', 'sha256')",
        pg.escape_identifier(pin)
      ), function (val) { hashedPIN = val[1][sf("digest('%s', 'sha256')", pin)] })[1]["digest(%s, 'sha256')"]
      pg.disconnect()
-- TODO: do sha256 internally instead (faster, less chance for unhashed pin to end up in DB's logfiles, etc)
--      hasher:update(pin)
--      if str.to_hex(hasher:final()) == row["pin"] then
--      if row["digest(%s,'sha256')", pin)] == row["pin"] then
      if hashedPin == storedPin then
        freeswitch.consoleLog("INFO", string.format("User ID %d login successful\n", user_id))
        session:speak("Successful.") -- for testing
        break
      else
        session:speak("Unsuccessful.") -- for testing
        freeswitch.consoleLog("INFO", string.format("User ID %d login unsuccessful\n", user_id))
        session:speak("Login Unsuccessful.")
      end
    end
  end
  remaining_attempts = remaining_attempts - 1
end
if remaining_attempts == 0 then
  session:speak("Too many failed attempts. Goodbye.")
  onHangup(nil, 'Server hangup')
  session:hangup()
end

-- dbc:close()
pg.destroy()

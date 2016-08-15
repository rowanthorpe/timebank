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

-- DEBUG
api = freeswitch.API();
local checkpoint_counter = 1
local function checkpoint()
  fsl("NOTICE", tostring(api:getTime()) .. ": " .. debug.getinfo(2).currentline .. ": checkpoint " .. tostring(checkpoint_counter) .. "\n")
  checkpoint_counter = checkpoint_counter + 1
end
-- DEBUG

local sf = string.format
local fsl = freeswitch.consoleLog
local function onHangup(s, status, arg)
  if dbh then
    dbh:release()
    dbh = nil
  end
  fsl("NOTICE", "onHangup: " .. status .. "\n")
  if session:ready() then
    session:hangup()
  end
  error()
end
session:setHangupHook("onHangup")
session:setAutoHangup(false)
--session:set_tts_params("flite", "kal")
session:set_tts_params("tts_commandline", "en1")
session:answer()
local dbh = freeswitch.Dbh("pgsql://hostaddr=127.0.0.1 dbname=timebank user=timebank password='----------' options='-c client_min_messages=NOTICE' application_name='timebank' connect_timeout=10")
assert(dbh:connected())

local user_id
local remaining_attempts = 3
while remaining_attempts > 0 do
checkpoint()
  user_id = session:playAndGetDigits(4, 4, 3, 10000, '#', 'tts://Enter your I.D.', '', '\\d+|#', 2000)
checkpoint()
  if user_id == "" then
    session:speak("No I.D. specified.")
  else
checkpoint()
    local storedPin
    dbh:query(sf("SELECT pin FROM usr WHERE id = %d LIMIT 1", user_id), function (row) storedPIN = row.pin; end)
checkpoint()
    local pin = session:playAndGetDigits(4, 4, 3, 10000, '#', 'tts://Enter your pin', '', '\\d+|#', 2000)
checkpoint()
    if pin == "" then
      session:speak("No pin specified.")
    else
checkpoint()
      local hashedPin
      do
        local sqlId = sf("digest('%s','sha256')", pin)
        dbh:query("SELECT" .. sqlId, function (row) hashedPIN = sqlId; end)
      end
checkpoint()
      if hashedPin == storedPin then
        freeswitch.consoleLog("INFO", string.format("User ID %d login successful\n", user_id))
        session:speak("Login successful.")
checkpoint()
        break
      else
        freeswitch.consoleLog("INFO", string.format("User ID %d login unsuccessful\n", user_id))
        session:speak("Login unsuccessful.")
checkpoint()
      end
    end
  end
checkpoint()
  remaining_attempts = remaining_attempts - 1
end
if remaining_attempts == 0 then
checkpoint()
  session:speak("Too many failed attempts. Goodbye.")
  onHangup(nil, 'Too many failed attempts')
end
checkpoint()
dbh:release()
dbh = nil

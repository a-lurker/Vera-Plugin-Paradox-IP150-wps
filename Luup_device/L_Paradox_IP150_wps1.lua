-- a-lurker, copyright, 17 August 2016
-- Last update: July 2020

-- Functionality based on work by Tertius Hyman
-- https://github.com/Tertiush/ParadoxIP150/blob/master/IP150-MQTT.py

-- Tested on openLuup with a Paradox: EVO192

--[[
    This program is free software; you can redistribute it and/or
    modify it under the terms of the GNU General Public License
    version 3 (GPLv3) as published by the Free Software Foundation;

    In addition to the GPLv3 License, this software is only for private
    or home usage. Commercial utilisation is not authorized.

    The above copyright notice and this permission notice shall be included
    in all copies or substantial portions of the Software.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
]]

local PLUGIN_NAME     = 'Paradox_IP150_wps'
local PLUGIN_SID      = 'urn:a-lurker-com:serviceId:'..PLUGIN_NAME..'1'
local PLUGIN_VERSION  = '0.56'
local THIS_LUL_DEVICE = nil

local m_IP150pw    = 'paradox'   -- IP150 defaults to 'paradox'
local m_keyPadCode = '1234'      -- alarm panel defaults to '1234'

local PLUGIN_URL_ID   = 'al_paradox_wps_info'
local m_busy          = false

local m_md5Pw           = ''
local m_ipAddress       = ''   -- the IP150 IP address
local m_PollEnable      = ''   -- set to either: '0' or '1'
local m_PollInterval    = 1    -- seconds
local m_TEST_POLL_COUNT = 0

-- info pertaining to the hardware and firmware
local m_panelInfo    = {}
local m_ipModuleInfo = {}

-- m_areas.areaName   eg typical default = 'Area 1', 'Area 2', 'Area 3' ...
-- m_areas.areaAlarmState
local m_areas = {}

-- number of areas (partitions) available:  EVO48 = 4, EVO192 = 8
local AREAS = 8

--[[
    index is zone number
    m_zones[i].zoneInUse  = true,         = boolean: true/false
    m_zones[i].zoneStatus = string: '0' to '5'
    m_zones[i].zoneOpen   = string: '0' or '1'
    m_zones[i].zoneName   = 'Front door', = string: 8 chars max
]]
local m_zones = {}

local m_AlarmStatesDef = {    --               Alternate possible interpretations ??:
    [0] = 'Area not in use',  -- checked OK    0 = In agreement
    [1] = 'Instant',          -- checked OK    1 = Disarmed
    [2] = 'Armed',            -- checked OK    2 = In agreement
    [3] = 'Alarm triggered',  -- checked OK    3 = In agreement
    [4] = '4',                --               4 = Armed in sleep (not applicable to EVO)
    [5] = 'Stay',             -- checked OK    5 = In agreement
    [6] = 'Entry Delay',      -- checked OK    6 = In agreement
    [7] = 'Exit delay',       -- checked OK    7 = In agreement
    [8] = '8',                --               8 = Ready to arm
    [9] = 'Disarmed'          -- checked OK    9 = Not ready to arm
-- [10] = '10'                --              10 = Instant  NOTE: code only handles one digit for the index, not two
    }

-- http://w3.impa.br/~diego/software/luasocket/reference.html
local socket = require('socket')

-- don't change this, it won't do anything. Use the DebugEnabled flag instead
local DEBUG_MODE = true

local function debug(textParm, logLevel)
    if DEBUG_MODE then
        local text = ''
        local theType = type(textParm)
        if (theType == 'string') then
            text = textParm
        else
            text = 'type = '..theType..', value = '..tostring(textParm)
        end
        luup.log(PLUGIN_NAME..' debug: '..text,50)

    elseif (logLevel) then
        local text = ''
        if (type(textParm) == 'string') then text = textParm end
        luup.log(PLUGIN_NAME..' debug: '..text, logLevel)
    end
end

-- If non existent, create the variable. Update
-- the variable, only if it needs to be updated
local function updateVariable(varK, varV, sid, id)
    if (sid == nil) then sid = PLUGIN_SID      end
    if (id  == nil) then  id = THIS_LUL_DEVICE end

    if ((varK == nil) or (varV == nil)) then
        luup.log(PLUGIN_NAME..' debug: '..'Error: updateVariable was supplied with a nil value', 1)
        return
    end

    local newValue = tostring(varV)
    --debug(varK..' = '..newValue)
    debug(newValue..' --> '..varK)

    local currentValue = luup.variable_get(sid, varK, id)
    if ((currentValue ~= newValue) or (currentValue == nil)) then
        luup.variable_set(sid, varK, newValue, id)
    end
end

-- Log the outcome (hex) - only used for testing
local function stringDump(userMsg, str)
    if (not DEBUG_MODE) then return end

    if (str == nil) then debug(userMsg..'is nil') return end
    local strLen = str:len()
    --debug('Length = '..tostring(strLen))

    local hex = ''
    local asc = ''
    local hexTab = {}
    local ascTab = {'   '}
    local dmpTab = {userMsg..'\n\n'}

    for i=1, strLen do
        local ord = str:byte(i)
        hex = string.format('%02X', ord)
        asc = '.'
        if ((ord >= 32) and (ord <= 126)) then asc = string.char(ord) end

        table.insert(hexTab, hex)
        table.insert(ascTab, asc)

        if ((i % 16 == 0) or (i == strLen))then
            table.insert(ascTab,'\n')
            table.insert(dmpTab,table.concat(hexTab, ' '))
            table.insert(dmpTab,table.concat(ascTab))
            hexTab = {}
            ascTab = {'   '}
        elseif (i % 8 == 0) then
            table.insert(hexTab, '')
            table.insert(ascTab, '')
        end
    end

    debug(table.concat(dmpTab))
end

-- Bitwise xor
-- https://stackoverflow.com/questions/5977654/how-do-i-use-the-bitwise-operator-xor-in-lua
local function bxor(a,b)
    local p,c=1,0
    while a>0 and b>0 do
        local ra,rb=a%2,b%2
        if ra~=rb then c=c+p end
        a,b,p=(a-ra)/2,(b-rb)/2,p*2
    end
    if a<b then a=b end
    while a>0 do
        local ra=a%2
        if ra>0 then c=c+p end
        a,p=(a-ra)/2,p*2
    end
    return c
end

-- If we're using openLuup this will get a table, otherwise nil
local function isOpenLuup()
    local openLuup = luup.attr_get('openLuup')
    return (openLuup ~= nil)
end

-- Returns a lower case sum or nil
local function md5(text)
    local md5Sum = nil
    local cmd = 'echo -n '..text..' | md5sum'
    local f = io.popen(cmd)
    if (f) then
        md5Sum = f:lines()()
        f:close()
    end
    -- trim off the stuff at the end
    md5Sum = md5Sum:match('([^ ]+)')
    return md5Sum
end

-- Test vectors:
-- Input: rc4Text = rc4('ThisIsTheKeyText', 'SomePlainTextToEncode')
-- Classic mode result: 05 95 77 E3 F2 9C 2C 6C 7B C0 33 CC C9 23 8E CC B4 AF 64 89 49   ..w...,l{.3..#....d.I
-- Paradox mode result: 97 CB 57 0A 47 F3 0A 42 3F 0B E5 79 B3 B6 DD 33 8D A2 E9 FE CA   ..W.G..B?..y...3.....
local function rc4(keyText, plainText)
    -- classic method:   http://rc4.online-domain-tools.com/
    local paradoxMethod = true
    local key   = {string.byte(keyText,   1, #keyText)}
    local chars = {string.byte(plainText, 1, #plainText)}

    local sV = {}
    local j  = 0
    local keylength = #key

    -- key scheduling algorithm (KSA) phase
    -- array index starts at zero, no fancy Lua library functions are applied to it
    for i = 0, 255 do sV[i] = i end

    if (paradoxMethod) then -- use paradox method
        for i = keylength-1, 0, -1 do
            j = (j + sV[i] + key[i+1]) % 256
            -- swap values
            sV[i], sV[j] = sV[j], sV[i]
        end
    else -- use classic method
        for i = 0, 255 do
            j = (j + sV[i] + key[i % keylength + 1]) % 256
            sV[i], sV[j] = sV[j], sV[i]
        end
    end

    -- pseudo random generation algorithm (PRGA) phase
    local i = 0
    j = 0
    if (paradoxMethod) then -- use paradox method
        for n = 1, #chars do
            i = (n-1) % 256     -- paradox version
            j = (j + sV[i]) % 256
            -- swap values
            sV[i], sV[j] = sV[j], sV[i]
            chars[n] = bxor(sV[(sV[i] + sV[j]) % 256], chars[n])
        end
    else -- use classic method
        for n = 1, #chars do
            i = (i + 1) % 256   -- classic version
            j = (j + sV[i]) % 256
            -- swap values
            sV[i], sV[j] = sV[j], sV[i]
            chars[n] = bxor(sV[(sV[i] + sV[j]) % 256], chars[n])
        end
    end
    return string.char(unpack(chars))
end

-- Load and extract the session ID from the page
local function getSessionID(html)
    -- if we haven't got the session ID page then get it
    if (not html) then
        local timeOut = 1
        local status, htmlResult = luup.inet.wget('http://'..m_ipAddress..'/login_page.html', timeOut)
        if (status ~= 0) then debug('Alarm panel inaccessible at point A - check IP address, etc') return nil end
        html = htmlResult
        -- WARNING: if things go wrong and this lot of HTML is found to be truncated then suspect http.lua
        -- It can send the GET and the headers in the wrong order, as they can end up in different packets
        debug('Warning: any truncation of the following html, may indicate http.lua needs to be upgraded.')
        debug(html)
    end

    -- skip the first 900 chars to speed things up a little - the exact starting
    -- point index will vary; depending on the length of the alarm name, etc
    local sessionID = html:match('loginaff%("(%x+)"', 900)
    if (not sessionID) then
        debug('Session ID not found - are you already connected to the alarm panel?')
        return nil
    end
    debug('Session ID: '..sessionID)
    return sessionID
end

-- Do the login
local function logIn(sessionID)
    local key = m_md5Pw..sessionID
    key = key:upper()

    local md5Sum = md5(key)
    if ((md5Sum == nil) or (md5Sum == '')) then debug ('md5sum call failure at point B') return false end
    local p = md5Sum:upper()

    -- we've got p, now do u
    local rc4Text = rc4(key, m_keyPadCode)
    local u = ''
    for i = 1, rc4Text:len() do
        local ord = rc4Text:byte(i)
        u = u..string.format('%02X', ord)
    end

    -- submit the login
    -- if the login fails you get this msg here; otherwise a gzip file is returned containing JavaScript:
    -- 'You must activate your javascript to use the IP module web page feature...'
    local timeOut = 1
    local url = 'http://'..m_ipAddress..'/default.html?u='..u..'&p='..p
    local status, html = luup.inet.wget(url, timeOut)
    if (status ~= 0) then debug('Alarm panel inaccessible at point B') return false end

    if (html:find('DOCTYPE HTML')) then -- got the error msg
        debug('Have you set the variables m_IP150pw and m_keyPadCode', 50)
        --debug(html)
        return false
    end

    -- At this point we get a gzip file in var html, which is not required or used by this prog.
    -- Log in to the IP150 itself was successful. However the panel login may
    -- not be successful: getSetUp() will finally determine if all is OK or not
    --stringDump('default.html', html)
    return true
end

-- Get the panel and IP adapter version info
local function getVersioningInfo()
    local timeOut = 1
    local status, html = luup.inet.wget('http://'..m_ipAddress..'/version.html', timeOut)
    if (status ~= 0) then debug('Alarm panel inaccessible at point C: keypad code is incorrect?') return false end
    debug('Logged on OK')
    --debug(html)

    -- don't bother searching through the first 400 characters
    local panelInfoStr = html:match('tbl_panel = new Array%((.-)%);', 400)
    debug(panelInfoStr)
    if (not panelInfoStr) then debug('Panel version info parse fail') return false end

    -- example input to match:  "EVO192","3.00",...
    local i = 1
    for panelInfo in panelInfoStr:gmatch('"(.-)"') do
        if     (i == 1) then m_panelInfo[i] = {'Model', panelInfo}
        elseif (i == 2) then if (panelInfo == '0.00') then panelInfo = '????' end m_panelInfo[i] = {'Firmware version', panelInfo}
        elseif (i == 3) then m_panelInfo[i] = {'Serial number', panelInfo} end
        i = i+1
    end

    -- don't bother searching through the first 500 characters
    local ipModuleInfoStr = html:match('tbl_ipmodule = new Array%((.-)%);', 500)
    debug(ipModuleInfoStr)
    if (not ipModuleInfoStr) then debug('IP module version info parse fail') return false end

    -- example input to match:  ""1.32.01","020","N009","N/A","2.12",...
    i = 1
    for ipModuleInfo in ipModuleInfoStr:gmatch('"(.-)"') do
        if     (i == 1) then m_ipModuleInfo[i] = {'Firmware version', ipModuleInfo}
        elseif (i == 2) then m_ipModuleInfo[i] = {'Hardware build',   ipModuleInfo}
        elseif (i == 3) then m_ipModuleInfo[i] = {'ECO',              ipModuleInfo}
        elseif (i == 4) then m_ipModuleInfo[i] = {'Serial boot',      ipModuleInfo}
        elseif (i == 5) then m_ipModuleInfo[i] = {'IP boot',          ipModuleInfo}
        elseif (i == 6) then m_ipModuleInfo[i] = {'Serial number',    ipModuleInfo}
        elseif (i == 7) then m_ipModuleInfo[i] = {'MAC address',      ipModuleInfo} end
        i = i+1
    end

--[[
    -- testing only
    local status, html = luup.inet.wget('http://'..m_ipAddress..'/version.js', timeOut)
    if (status ~= 0) then debug('version.js not read') return false end
    debug('Got Javascript')
    debug(html)  -- returned info may be zipped?
]]
    -- all OK
    debug('getVersioningInfo OK')
    return true
end

-- Get set up info
local function getSetUp()
    -- note the long timeout required -- the IP150 is busy getting
    -- all the info via the panel's slow serial interface
    local timeOut = 9

    -- get the web page that describes the panel layout
    local status, html = luup.inet.wget('http://'..m_ipAddress..'/index.html', timeOut)
    if (status ~= 0) then debug('Alarm panel inaccessible at point D: keypad code is incorrect?') return false end
    debug('Logged on OK')
    debug(html)
    --stringDump('index.html', html)

    -- extract the alarm name from the web page
    -- alarm panel defaults to 'Your Paradox System'
    -- skip the first 400 chars to speed things up a little - capture actually starts at 486
    local alarmName = html:match('top.document.title="(.-)";', 400)
    debug(alarmName)
    if (not alarmName) then debug('Alarm name parse fail') return false end
    updateVariable('AlarmName', alarmName)

    -- extract the area names from the web page
    local areaNamesStr = html:match('tbl_areanam = new Array%((.-)%);', 500)
    debug(areaNamesStr)
    if (not areaNamesStr) then debug('Areas parse fail') return false end

    local i = 0
    -- example input to match:  0," ",0," ",1,"Front Door", .....
    -- see the declaration of the variable 'zones' for more info
    for areaName in areaNamesStr:gmatch('"(.-)"') do
        i = i+1
        m_areas[i] = {
            ['areaName']       = areaName,
            ['areaAlarmState'] = '?'  -- force update of area state at start up
        }
        debug(tostring(i)..': '..m_areas[i].areaName)
    end
    updateVariable('AreasTotal', i)

    -- create the master zones table
    local zoneNamesStr = html:match('tbl_zone = new Array%((.-)%);', 500)
    debug(zoneNamesStr)
    if (not zoneNamesStr) then debug('Zones parse fail') return false end

    local ZonesInUse = 0
    local i = 0
    -- example input to match:  0," ",0," ",1,"Front Door", .....
    -- see the declaration of the variable 'm_zones' for more info
    for zoneInfo in zoneNamesStr:gmatch('([01],".-)"') do
        i = i+1

        local zoneInUseStr, zoneName = zoneInfo:match('([01])," ?(.*)')
        local zoneInUse = (zoneInUseStr == '1')
        m_zones[i] = {
            ['zoneInUse']  = zoneInUse,
            ['zoneStatus'] = '?',  -- force update of zone at start up
            ['zoneOpen']   = '?',
            ['zoneName']   = zoneName
        }
        -- debug(tostring(i)..': '..tostring(m_zones[i].zoneInUse)..','..m_zones[i].zoneStatus..','..m_zones[i].zoneOpen..','..m_zones[i].zoneName)

        if (zoneInUse) then ZonesInUse = ZonesInUse+1 end
    end
    updateVariable('ZonesTotal', i)
    updateVariable('ZonesInUse', ZonesInUse)

    -- extract the trouble names from the web page
    local troubleNamesStr = html:match('tbl_troublename = new Array%((.-)%);', 500)
    debug(troubleNamesStr)
    if (not troubleNamesStr) then debug('Trouble names parse fail') return false end

    local troubleNames = {}
    local i = 1
    for troubleName in troubleNamesStr:gmatch('"(.-)"') do
        troubleNames[i] = troubleName
        -- note the last idx is a blank string for some reason
        debug(troubleNames[i])
    end

    -- all OK
    debug('getSetUp OK')
    return true
end

--[[
Search for page redirections in the returned html code. Redirects are done using JavaScript as discussed below:

Couple of redirection examples used by Paradox:
   top.location.replace("login.html")
   window.location.replace("statuslive.html")

The prefix to 'location' ie 'window' is implied and is therefore optional; As an alternative to 'window',
'top' or 'self' can be used . The suffix to 'location' can be blank or 'href' or 'assign' or 'replace'.
The URL can be a full URL with http:// etc or just the page name eg xyz.html

We search for and capture the first string, delimited with single or double quotes,
found immediately after the keyword 'location', that contains '.htm' or '.html'
]]

local function checkForRedirects(html)
    local redirectedTo = html:match('location.-[\'"](.-%.html?)[\'"]')

    -- During normal operation, when using a browser, the web page JavaScript redirects to 'statuslive.html'
    -- every 2 seconds; effectively polling the alarm. We'll ignore this redirect.
    if ((not redirectedTo) or (redirectedTo == 'statuslive.html')) then return end

    -- Other redirects are of interest, as they may redirect to an error page.
    -- Get the contents of the redirect's target page for later examination.
    local timeOut = 1
    local status, html = luup.inet.wget('http://'..m_ipAddress..'/'..redirectedTo, timeOut)
    if ((status ~= 0) or (not html)) then debug('Call to redirect target failed.') return end

    -- For reasons unknown (possibly we were to slow to respond), we sometimes get redirected to the log in page: Check
    -- if the redirect target page is the login page. If so, it should contain a session ID. Use the ID to log back in.
    if (redirectedTo == 'login_page.html') then
        local sessionID = getSessionID(html)
        if (sessionID) then logIn(sessionID) end
    else -- OK something unexpected was returned - we will save it for later examination
        -- log the URL of the redirect target page and its contents
        updateVariable('LastRedirectURL', redirectedTo)
        updateVariable('LastRedirectLog', html)
        stringDump('Was redirected to: '..redirectedTo..' html follows:', html)
    end
end

-- Poll the status alarm. Poll interval: 7 secs is too long and the
-- connection will be terminated by the IP150; anything below 6 secs works
-- This is a time out target; function needs to be global
function pollParadoxAlarm()
    if (m_PollEnable ~= '1') then return end

    local startTime = socket.gettime()*1000

    -- get the alarm status web page
    local timeOut = 1
    local status, html = luup.inet.wget('http://'..m_ipAddress..'/statuslive.html', timeOut)
    if (status ~= 0) then
        debug('Alarm panel was inaccessible while polling', 50)
    else
        --debug(html)
        --stringDump('statuslive.html', html)

        -- Errors appear to result in a redirect embedded in the page to the error page
        -- We'll check for redirects and if found, record them.
        -- If the redirect is the log in page, we'll log in again.
        -- zoneStatusStr will be found to be nil but it should work OK next time around
        checkForRedirects(html)

        -- Update the master zone table with the current status of each zone.
        -- Skip the first 350 chars to speed things up a little - capture actually starts at 403.
        -- local zoneStatusStr = html:match('tbl_statuszone = new Array%((.-)%);', 370)
        local startIdx1, _, zoneStatusStr = html:find('tbl_statuszone = new Array%((.-)%);', 370)

        -- This can fail if the poll interval is too long (abt > 6 secs). The connection is then terminated by the IP150.
        -- This msg is returned: 'You must activate your javascript to use the IP module web page feature...'
        if (not zoneStatusStr) then
            debug('Zone status parse fail; possible intermediate log in occurred')
        else
            debug('tbl_statuszone startIdx = '..tonumber(startIdx1))

            --[[ zoneStatus =                                         Alternate possible interpretations ??:
            0   = Closed                                              0 = In agreement
            1   = Open                                                1 = In agreement
            2   = Open with alarm in memory & not an alarm trigger    2 = In alarm
            ??  = Trouble                                             3 = Closed with trouble
            ??  = Trouble                                             4 = Open   with trouble
            5   = Closed with alarm in memory                         5 = In agreement
            5   = Closed with alarm in memory & not an alarm trigger  ????
            6   = Open with alarm in memory                           6 = In agreement
            ??  = Bypass                                              7 = Bypassed
            ??  =                                                     8 = Closed with trouble (duplicate?)
            ??  =                                                     9 = Open   with trouble (duplicate?)
            ??  = In alarm
            ]]
            local i = 1
            for zoneStatus in zoneStatusStr:gmatch('(%d)') do
                -- All zones are forced to update at start up as zoneStatus initially equals '?'.
                -- After start up, only changed zones are updated.
                if (m_zones[i].zoneStatus ~= zoneStatus) then
                    m_zones[i].zoneStatus = zoneStatus
                    debug('zoneStatus: '..zoneStatus)
                    local zoneState = ''
                    if ((zoneStatus == '1') or (zoneStatus == '2') or (zoneStatus == '6')) then
                         zoneState = 'open'
                         m_zones[i].zoneOpen = '1'
                    else -- closed for status 0,3,4,5
                         zoneState = 'closed'
                         m_zones[i].zoneOpen = '0'
                    end

                    debug(string.format('Zone_%03i: %s is now %s', i, m_zones[i].zoneName, zoneState, 50))
                    luup.variable_set(PLUGIN_SID, string.format('Zone_%03i', i), m_zones[i].zoneOpen, THIS_LUL_DEVICE)
                end
                -- debug(tostring(i)..': '..tostring(m_zones[i].zoneInUse)..','..m_zones[i].zoneStatus..','..m_zones[i].zoneOpen..','..m_zones[i].zoneName)
                i = i+1
            end

            -- Get the alarm states from the web page.
            -- Skip the first 470 chars to speed things up a little - capture actually starts at 846 for
            -- an EVO 192 but less for EVO48, so we'll be start a lot eaarlier to allow both to work.
            -- local alarmStateStr = html:match('tbl_useraccess = new Array%((.-)%);')
            local startIdx2, _, alarmStateStr = html:find('tbl_useraccess = new Array%((.-)%);', 470)
            debug('tbl_useraccess startIdx = '..tonumber(startIdx2))

            local i = 1
            for areaAlarmState in alarmStateStr:gmatch('(%d)') do
                -- All areas are forced to update at start up as areaAlarmState initially equals '?'.
                -- After start up, only changed areas are updated.
                if (m_areas[i].areaAlarmState ~= areaAlarmState) then
                    m_areas[i].areaAlarmState = areaAlarmState

                    -- get a descriptive string for the alarm state of this area
                    local alarmState = 'Unknown'
                    local alarmStateNum = tonumber(areaAlarmState)
                    if (alarmStateNum) then alarmState = m_AlarmStatesDef[alarmStateNum] end
                    debug('areaAlarmState of '..m_areas[i].areaName..' = '..alarmState, 50)

                    luup.variable_set(PLUGIN_SID, 'AlarmStateOfArea_'..i, alarmState, THIS_LUL_DEVICE)
                end
                i = i+1
            end
        end
    end

    local endTime = socket.gettime()*1000
    debug(string.format('Elapsed time: %.2f msec\n', endTime - startTime))

--[[
    -- for test purposes only
    -- 9 hrs:  32400,  10 mins = 600
    m_TEST_POLL_COUNT = m_TEST_POLL_COUNT +1
    if (m_TEST_POLL_COUNT ~= 32400) then
        -- get the alarm info every poll interval
        luup.call_delay('pollParadoxAlarm', m_PollInterval)
    end
]]

    -- rinse and repeat
    luup.call_delay('pollParadoxAlarm', m_PollInterval)
end

-- This services two needs:
--   1) allows time for everything to settle down, after a Vera restart, before we start polling
--   2) ensures the IP150 terminates any existing connection before we login
-- This is a time out target; function needs to be global
function paradoxAlarmStartUpDelay()
    debug('Doing the delayed start up')

    local sessionID = getSessionID()

    if (not sessionID)           then return false, 'Session ID not found', PLUGIN_NAME end
    if (not logIn(sessionID))    then return false, 'Log in failed',        PLUGIN_NAME end
    if (not getVersioningInfo()) then return false, 'Get versions failed',  PLUGIN_NAME end
    if (not getSetUp())          then return false, 'Get setup failed',     PLUGIN_NAME end

    debug('Delayed start up complete')

    pollParadoxAlarm()
end

-- Polling on off
-- A variable accessible to the user. It has little use except for test purposes.
local function polling(pollEnable)
    if (not ((pollEnable == '0') or (pollEnable == '1'))) then return end
    m_PollEnable = pollEnable
    updateVariable('PollEnable', m_PollEnable)
end

--[[
a service in the implementation file
action:  control the panel arming for the selected area
mode (upper or lower case):
    r = Regular arm    All zones within the protected area must be closed.
    f = Force arm      Open zones will arm themselves if subsequently closed.
    s = Stay arm       Only perimeter zones are armed, allowing you stay inside.
    i = Instant arm    Same as Stay but all entry delays are set to instant (zero delay).
    d = Disarm         Disarms the panel.

    area:  optional - defaults to zero
]]
local function arming(mode, area)
    -- validate the passed in parms
    local areaNum = tonumber(area)   -- areas start at 0
    if ((areaNum == nil) or (areaNum < 0) or (areaNum >= AREAS)) then areaNum = 0 end

    local modes = 'rfsid'
    if ((mode:len() ~= 1) or (modes:find(mode:lower()) == nil)) then return end

    -- submit the arming command to the panel
    local timeOut = 2
    local status, html = luup.inet.wget('http://'..m_ipAddress..'/statuslive.html?area='..area..'&value='..mode, timeOut)
    if (status ~= 0) then debug('Arming problem') return end
    --stringDump('statuslive.html?area=x&value=y', html)
end

local function htmlHeader()
return [[<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"
    "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
<head>
<meta http-equiv="content-type" content="text/html; charset=utf-8"/>]]
end

-- Get info pertaining to the hardware and firmware for the web page
local function getVersionInfo()
    local strTab = {'Panel info:'}
    for _,v in ipairs(m_panelInfo) do
        table.insert(strTab, string.format('%-18s%s',v[1],v[2]))
    end

    table.insert(strTab,'\nIP module info:')
    for _,v in ipairs(m_ipModuleInfo) do
        table.insert(strTab, string.format('%-18s%s',v[1],v[2]))
    end

    table.insert(strTab, '\n')
    return table.concat(strTab, '\n')
end

-- Get the number of zones in use for the web page
local function getZonesInUseCount()
    local strTab = {[1] = 'Zones in use = '}
    local zonesInUse = luup.variable_get(PLUGIN_SID, 'ZonesInUse', THIS_LUL_DEVICE)
    if (zonesInUse) then
        table.insert(strTab, zonesInUse)
    else
        table.insert(strTab, 'unknown')
    end
    table.insert(strTab, '<br/>')
    return table.concat(strTab)
end

-- Get the list of zones for the web page
local function listZones()
    local strTab = {'Zone info:'}
    table.insert(strTab, 'Zone   #   Open  Label')
    for k,v in ipairs(m_zones) do
        if (v.zoneInUse) then
            table.insert(strTab, string.format('Zone_%03i    %-5s%-20s', k, v.zoneOpen, v.zoneName))
        else
            table.insert(strTab, string.format('Zone_%03i   ---', k))
        end
    end
    if (#strTab ~= 0) then return table.concat(strTab,'\n') end
    return 'Not ready - try again in a minute or so.'
end

-- A web page that will report the device status
local function htmlIntroPage()
    local title  = 'Paradox: EVOxyz'
    if (m_panelInfo[1]) then title = 'Paradox: '..m_panelInfo[1][2] end

    local header = PLUGIN_NAME..':&nbsp;&nbsp;plugin version:&nbsp;&nbsp;'..PLUGIN_VERSION

    local strTab = {
    htmlHeader(),
    '<title>'..title..'</title>',
    '</head>\n',
    '<body>',
    '<h3>'..header..'</h3>',
    '<div>',
    '<pre>',
    getVersionInfo(),
    getZonesInUseCount(),
    listZones(),
    '</pre>',
    '</div>',
    '</body>',
    '</html>\n'
    }

    return table.concat(strTab,'\n'), 'text/html'
end

-- Entry point for all html page requests and all ajax function calls
-- http://vera_ip_address/port_3480/data_request?id=lr_al_paradox_wps_info
function requestMain (lul_request, lul_parameters, lul_outputformat)
    debug('request is: '..tostring(lul_request))
    for k, v in pairs(lul_parameters) do debug ('parameters are: '..tostring(k)..'='..tostring(v)) end
    debug('outputformat is: '..tostring(lul_outputformat))

    if not (lul_request:lower() == PLUGIN_URL_ID) then return end

    -- set the parameters key and value to lower case
    local lcParameters = {}
    for k, v in pairs(lul_parameters) do lcParameters[k:lower()] = v:lower() end

    -- output the intro page?
    if not lcParameters.fnc then
        if (m_busy) then return '' else m_busy = true end
        local page = htmlIntroPage()
        m_busy = false
        return page
    end -- no 'fnc' parameter so do the intro

    return 'Error', 'text/html'
end

--[[

May need to handle ????:
keepalive.html
waitlive.html
logout.html

Errors:
https is in use

]]

-- Let's do it
-- Function must be global
function luaStartUp(lul_device)
    THIS_LUL_DEVICE = lul_device
    debug('Initialising plugin: '..PLUGIN_NAME)
    debug('Using: '.._VERSION)   -- returns the string: 'Lua x.y'

    -- set up some defaults:
    updateVariable('PluginVersion', PLUGIN_VERSION)

    local debugEnabled = luup.variable_get(PLUGIN_SID, 'DebugEnabled', THIS_LUL_DEVICE)
    if ((debugEnabled == nil) or (debugEnabled == '')) then
        debugEnabled = '0'
        updateVariable('DebugEnabled', debugEnabled)
    end
    DEBUG_MODE = (debugEnabled == '1')

    local pluginEnabled = luup.variable_get(PLUGIN_SID, 'PluginEnabled', THIS_LUL_DEVICE)
    local pollEnable    = luup.variable_get(PLUGIN_SID, 'PollEnable',    THIS_LUL_DEVICE)

    if ((pluginEnabled == nil) or (pluginEnabled == '')) then
        pluginEnabled = '1'
        updateVariable('PluginEnabled', pluginEnabled)
    end

    if ((pollEnable == nil) or (pollEnable == '')) then
        -- turn the polling on
        m_PollEnable = '1'
        polling(m_PollEnable)
    else
        m_PollEnable = pollEnable
    end

    -- required for UI7
    luup.set_failure(false)

    if (pluginEnabled ~= '1') then return true, 'All OK', PLUGIN_NAME end

    -- registers a handler for the plugins's web page
    luup.register_handler('requestMain', PLUGIN_URL_ID)

    -- set up the ip connection
    local ipa = luup.devices[THIS_LUL_DEVICE].ip
    local ipAddress = ipa:match('^(%d%d?%d?%.%d%d?%d?%.%d%d?%d?%.%d%d?%d?)')

    if ((ipAddress == nil) or (ipAddress == '')) then
        return false, 'Enter a valid IP address', PLUGIN_NAME
    end
    m_ipAddress = ipa
    debug('Using IP address: '..ipAddress)

    -- do this at start up; it only needs to be done once
    m_md5Pw = md5(m_IP150pw)
    if ((m_md5Pw == nil) or (m_md5Pw == ''))then
        debug('md5sum command probably not present')
        return false, 'md5sum call failure at point A', PLUGIN_NAME
    end

    -- Vera doesn't allow delay values less than one second or fractional values. openLuup does.
    if (isOpenLuup()) then m_PollInterval = 0.5 end

    local START_UP_DELAY_SECS = 45
    luup.call_delay('paradoxAlarmStartUpDelay', START_UP_DELAY_SECS)

    return true, 'All OK', PLUGIN_NAME
end

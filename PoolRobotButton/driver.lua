-- Pool Robot (iAquaLink / Zodiac) - Control4 DriverWorks driver
-- ---------------------------------------------------------------------
-- Controls a Zodiac/iAquaLink robotic pool cleaner over its
-- reverse-engineered cloud API (derived from a mitmproxy capture of the
-- official iAquaLink iOS app). Exposes two commands:
--   StartCleaning
--   StopCleaning
-- available both as direct device commands and as Actions-tab buttons
-- in Composer Pro programming.
--
-- Uses only confirmed Control4 DriverWorks APIs:
--   C4:urlGet / C4:urlPost + global ReceivedAsync()   (HTTP)
--   C4:CreateNetworkConnection / C4:NetConnect /
--     C4:SendToNetwork + global OnConnectionStatusChanged() /
--     ReceivedFromNetwork()                            (raw TCP/TLS)
--   C4:Base64Encode, C4:Hash                            (WS handshake)
--   C4:UpdateProperty, C4:ErrorLog
--
-- JSON handled by the bundled dkjson.lua (MIT licensed, David Kolf).
-- ---------------------------------------------------------------------

local json = require("dkjson")

-- ===================== Constants =====================
local LOGIN_URL  = "https://prod.zodiac-io.com/users/v1/login"
local WS_HOST    = "prod-socket.zodiac-io.com"
local WS_PORT    = 443
local WS_PATH    = "/devices"
local NET_BINDING = 6001

-- Device list endpoint (same one the iAquaLink app uses to list the
-- account's equipment). Needs the login's authentication_token + user id.
local DEVICES_URL = "https://r-api.iaqualink.net/devices.json"
local API_KEY     = "EOOEMOW4YR6QNB07"

-- Devices whose name (case-insensitive) is in this set are left out of
-- the "Robot" dropdown.
local EXCLUDED_DEVICE_NAMES = { ["vr"] = true }

local NO_ROBOTS_ITEM = "(no robots found - use Refresh Robot List)"

-- Behind an Imperva WAF that 403s requests without an app-like
-- User-Agent -- mirror what the real iAquaLink app sends.
local USER_AGENT = "iAqualink/956 CFNetwork/3860.600.12 Darwin/25.5.0"

-- ===================== Driver state =====================
gIdToken = nil        -- Cognito id_token from login, used as WS bearer
gUserId = nil         -- account user id
gLoginTicket = nil    -- C4:urlPost ticket for the in-flight login request
gPendingAction = nil  -- 1 (start) / 0 (stop) / nil - queued command
gWsSerial = nil       -- serial number the current/target ws session is for
gWsConnected = false  -- raw TCP/TLS connection up
gWsHandshakeDone = false -- WS upgrade handshake completed
gWsAuthorized = false -- seen the device's reported state since connecting
gWsBuffer = ""        -- inbound byte buffer for HTTP/WS parsing
gWsKey = nil          -- Sec-WebSocket-Key sent, needed to check the accept hash
gWsFragment = nil     -- accumulates a message split across continuation frames
gSentState = nil      -- state (0/1) most recently commanded, to match the server's ack
gCloseTimerId = nil   -- pending force-close timer, if any (see SendSetCleanerState)
gDebugMode = "Off"    -- mirrors the "Debug Mode" property ("Off" / "Print")
gPollTimerId = nil    -- repeating status-poll timer, if polling is enabled
gStatusTicket = nil   -- C4:urlGet ticket for the in-flight status-poll request
gPollAfterLogin = false -- a poll is waiting on an in-flight login to finish
gAuthToken = nil      -- legacy authentication_token from login, used for devices.json
gDevicesTicket = nil  -- C4:urlGet ticket for the in-flight device list request
gRefreshAfterLogin = false -- fetch the device list once the login completes
gDevicesRetried = false    -- already re-logged-in once after a 401 on devices.json
gRobotLabels = {}     -- dropdown label -> serial number
gCanisterFull = nil   -- last reported canister flag (true/false), nil = unknown

STATUS_URL = "https://prod.zodiac-io.com/devices/v1/%s/shadow"
MIN_POLL_INTERVAL_SECONDS = 15 -- floor to avoid hammering the API

-- ===================== Debug logging =====================
-- C4:ErrorLog always writes to the persistent driver_debug.log regardless
-- of this setting. print() only reaches the Composer Pro Lua tab's output
-- window if BOTH: (a) that tab is open, and (b) C4:AllowExecute(true) was
-- called -- the Lua console is locked by default, so print() silently
-- goes nowhere until that's set. See OnDriverInit.
function DebugPrint(msg)
	C4:ErrorLog(msg)
	if gDebugMode == "Print" then
		print(msg)
	end
end

-- ===================== Driver lifecycle =====================

function OnDriverInit()
	-- Unlocks the Lua execute/output window in Composer Pro's Lua tab so
	-- print() calls are actually visible there. Without this, print()
	-- output is silently dropped no matter what Debug Mode is set to.
	C4:AllowExecute(true)

	gDebugMode = Properties["Debug Mode"] or "Off"
	C4:UpdateProperty("Status", "Idle")
	C4:CreateNetworkConnection(NET_BINDING, WS_HOST, "SSL")
	C4:NetPortOptions(NET_BINDING, WS_PORT, "SSL", {})

	-- Restore the previously selected robot so the dropdown shows it
	-- before the device list has been fetched again. Falls back to the
	-- old free-text "Robot Serial" value when upgrading from v10.
	local serial = PersistData["RobotSerial"] or Properties["Robot Serial"]
	local label = PersistData["RobotLabel"] or serial
	if serial ~= nil and serial ~= "" then
		SetSelectedRobot(label, serial)
		C4:UpdatePropertyList("Robot", label, label)
	end

	-- Restore the last known canister state so a reboot doesn't re-fire
	-- the "Canister Full" event for a canister we already reported.
	if PersistData["CanisterFull"] ~= nil then
		gCanisterFull = PersistData["CanisterFull"]
		C4:UpdateProperty("Canister", gCanisterFull and "Full" or "OK")
	end

	DisplayState(false, DEFAULT_PROXY_BINDINGID, true)
	RestartPolling()
	DebugPrint("Pool Robot driver initialized")
end

function OnDriverLateInit()
	-- Populate the Robot dropdown if credentials are already entered.
	if HaveCredentials() then
		RefreshRobotList()
	end
	PollStatus()
end

function OnPropertyChanged(sProperty)
	if sProperty == "Debug Mode" then
		gDebugMode = Properties["Debug Mode"]
		DebugPrint("Pool Robot: Debug Mode set to " .. tostring(gDebugMode))
	end

	if sProperty == "Email" or sProperty == "Password" then
		-- force re-login next command if credentials change, and reload
		-- the robot list for the (possibly different) account
		gIdToken, gUserId, gAuthToken = nil, nil, nil
		if HaveCredentials() then
			RefreshRobotList()
		end
	end

	if sProperty == "Robot" then
		local label = Properties["Robot"]
		local serial = gRobotLabels[label] or SerialFromLabel(label)
		if serial ~= nil and serial ~= "" then
			local changed = serial ~= GetSelectedSerial()
			SetSelectedRobot(label, serial)
			DebugPrint("Pool Robot: selected robot " .. tostring(label))
			if changed then
				PollStatus()
			end
		end
	end

	if sProperty == "Poll Interval (Seconds)" then
		RestartPolling()
	end
end

-- (Re)starts the repeating status-poll timer based on the "Poll Interval
-- (Seconds)" property. An empty/zero/invalid value disables polling.
function RestartPolling()
	if gPollTimerId ~= nil then
		gPollTimerId = C4:KillTimer(gPollTimerId)
	end

	local interval = tonumber(Properties["Poll Interval (Seconds)"])
	if interval == nil or interval <= 0 then
		DebugPrint("Pool Robot: status polling disabled")
		return
	end
	if interval < MIN_POLL_INTERVAL_SECONDS then
		interval = MIN_POLL_INTERVAL_SECONDS
	end

	gPollTimerId = C4:AddTimer(interval, "SECONDS", true)
	DebugPrint("Pool Robot: status polling every " .. tostring(interval) .. "s")
end

-- ===================== Command dispatch =====================
-- StartCleaning/StopCleaning work both as direct commands (from the
-- <commands> list) and, via the ACTION parameter, as Actions-tab button
-- presses (from the <actions> list) -- Director sends command
-- "LUA_ACTION" with tParams.ACTION set to the action's mapped command
-- name in that case.

gCleaningActive = false -- tracks last commanded state, for the tap-to-toggle icon
DEFAULT_PROXY_BINDINGID = 5001

function ExecuteCommand(sCommand, tParams)
	DebugPrint("Pool Robot: ExecuteCommand(" .. tostring(sCommand) .. ")")
	if sCommand == "StartCleaning" then
		QueueCleanerState(1)
	elseif sCommand == "StopCleaning" then
		QueueCleanerState(0)
	elseif sCommand == "RefreshRobotList" then
		RefreshRobotList()
	elseif sCommand == "SELECT" then
		-- Fallback in case this proxy/OS version routes the button tap
		-- through ExecuteCommand rather than ReceivedFromProxy.
		HandleButtonSelect(DEFAULT_PROXY_BINDINGID)
	elseif sCommand == "LUA_ACTION" and tParams ~= nil then
		if tParams.ACTION == "StartCleaning" then
			QueueCleanerState(1)
		elseif tParams.ACTION == "StopCleaning" then
			QueueCleanerState(0)
		elseif tParams.ACTION == "RefreshRobotList" then
			RefreshRobotList()
		end
	end
end

-- Shared toggle handler for a button tap, regardless of which Director
-- callback delivered it.
function HandleButtonSelect(idBinding)
	local newState = not gCleaningActive
	QueueCleanerState(newState and 1 or 0)
	DisplayState(newState, idBinding)
end

-- Updates the icon/property/event for a cleaning-state change, whether
-- triggered by a tap or by syncing the robot's actual reported state.
-- Confirmed real mechanism (from a working uibutton driver example):
-- C4:SendToProxy(binding, "ICON_CHANGED", {icon=<state id>, icon_description=<label>})
-- plus C4:UpdateProperty("Current State", <label>) to match. State IDs
-- here ("Default"/"Selected") match driver.xml's <state id="..."> names.
function DisplayState(isCleaning, idBinding, initializing)
	gCleaningActive = isCleaning
	idBinding = idBinding or DEFAULT_PROXY_BINDINGID

	local label = isCleaning and "Cleaning" or "Idle"
	local iconState = isCleaning and "Selected" or "Default"

	C4:SendToProxy(idBinding, "ICON_CHANGED", { icon = iconState, icon_description = label })
	C4:UpdateProperty("Current State", label)
	if not initializing then
		C4:FireEvent(label)
	end
end

-- Called by Director when the bound UIButton proxy sends a message --
-- specifically the "SELECT" command when the user taps the icon in
-- Navigator. Each tap toggles between starting and stopping the robot.
--
-- NOTE: the exact notification Director expects to flip the icon's
-- visual "Selected" state (declared via <state id="Selected"> in
-- driver.xml) wasn't confirmed against a live example, so ICON_CHANGED
-- below is a best-effort guess at the real notification name/params --
-- check the Lua log (DebugPrint call below) to see what actually
-- happens when you tap the icon, and adjust this if the highlight
-- doesn't update.
function ReceivedFromProxy(idBinding, sCommand, tParams)
	DebugPrint("Pool Robot: ReceivedFromProxy(" .. tostring(sCommand) .. ") on binding " .. tostring(idBinding))

	if sCommand == "SELECT" then
		HandleButtonSelect(idBinding)
	else
		-- Control4 doesn't document a specific "the icon is about to be
		-- displayed" event for a plain uibutton proxy the way it does
		-- for SELECT, so this treats any OTHER message the proxy sends
		-- as a cue to refresh status (the icon then updates via
		-- DisplayState inside HandleStatusResponse once the poll
		-- returns). If the Lua log shows a specific command name
		-- firing reliably on render, switch this to check for that
		-- command by name instead of "any command".
		PollStatus()
	end
end

-- ===================== Login =====================

function GetSelectedSerial()
	local serial = PersistData["RobotSerial"]
	if serial == nil or serial == "" then
		serial = Properties["Robot Serial"]
	end
	return serial
end

function QueueCleanerState(state)
	local serial = GetSelectedSerial()
	if serial == nil or serial == "" then
		C4:UpdateProperty("Status", "Error: no robot selected")
		return
	end

	gPendingAction = state

	if gIdToken ~= nil and gUserId ~= nil then
		ConnectAndSend(serial, state)
	else
		Login()
	end
end

function HaveCredentials()
	local email = Properties["Email"]
	local password = Properties["Password"]
	return email ~= nil and email ~= "" and password ~= nil and password ~= ""
end

function Login()
	if gLoginTicket ~= nil then
		return -- a login is already in flight; its result will be used
	end

	local email = Properties["Email"]
	local password = Properties["Password"]
	if email == nil or email == "" or password == nil or password == "" then
		C4:UpdateProperty("Status", "Error: Email/Password not set")
		return
	end

	local headers = {
		["User-Agent"] = USER_AGENT,
		["Accept"] = "*/*",
		["Content-Type"] = "application/json",
	}
	local body = json.encode({ email = email, password = password })

	C4:UpdateProperty("Status", "Logging in...")
	gLoginTicket = C4:urlPost(LOGIN_URL, body, headers)
	DebugPrint("Pool Robot: login request sent, ticket=" .. tostring(gLoginTicket))
end

-- Fetches the robot's current reported status (independent of the
-- start/stop websocket flow -- a plain HTTPS GET, no persistent
-- connection held open). Called on a timer (see RestartPolling) and
-- logs in first if needed.
function PollStatus()
	local serial = GetSelectedSerial()
	if serial == nil or serial == "" then
		DebugPrint("Pool Robot: skipping status poll, no robot selected")
		return
	end

	if gIdToken == nil or gUserId == nil then
		gPollAfterLogin = true
		Login()
		return
	end

	local headers = {
		["User-Agent"] = USER_AGENT,
		["Accept"] = "*/*",
		["Authorization"] = "Bearer " .. gIdToken,
	}
	local url = string.format(STATUS_URL, serial)
	gStatusTicket = C4:urlGet(url, headers)
	DebugPrint("Pool Robot: status poll sent, ticket=" .. tostring(gStatusTicket))
end

-- Global callback Director invokes when a C4:urlGet/C4:urlPost request
-- completes. Confirmed real signature (verified against actual driver
-- logs): (idTicket, strData, responseCode, tHeaders, errMsg) -- NOT the
-- (idTicket, strData, errMsg, responseCode, tHeaders) order some other
-- driver templates use for this same callback name.
function ReceivedAsync(idTicket, strData, responseCode, tHeaders, errMsg)
	if idTicket == gLoginTicket then
		HandleLoginResponse(strData, responseCode, errMsg)
	elseif idTicket == gStatusTicket then
		HandleStatusResponse(strData, responseCode, errMsg)
	elseif idTicket == gDevicesTicket then
		gDevicesTicket = nil
		OnDevicesResponse(strData, responseCode, errMsg)
	end
end

function HandleLoginResponse(strData, responseCode, errMsg)
	gLoginTicket = nil

	if tonumber(responseCode) ~= 200 then
		C4:UpdateProperty("Status", "Login failed (" .. tostring(responseCode) .. ")")
		DebugPrint("Pool Robot: login failed, response code: " .. tostring(responseCode) ..
			" err: " .. tostring(errMsg) .. " body: " .. tostring(strData))
		gPollAfterLogin = false
		gRefreshAfterLogin = false
		return
	end

	local auth, _, decodeErr = json.decode(strData)
	if auth == nil then
		C4:UpdateProperty("Status", "Login response parse error")
		DebugPrint("Pool Robot: could not parse login response (" ..
			tostring(decodeErr) .. "): " .. tostring(strData))
		gPollAfterLogin = false
		gRefreshAfterLogin = false
		return
	end

	-- Confirmed real response shape: user id is top-level "id", and the
	-- Cognito id token is nested at userPoolOAuth.IdToken.
	local poolOAuth = auth.userPoolOAuth or auth.user_pool_oauth or {}
	gIdToken = poolOAuth.IdToken or poolOAuth.id_token
		or auth.id_token or auth.IdToken
		or auth.authentication_token
	gUserId = auth.id or auth.userID or auth.user_id or auth.userId
	gAuthToken = auth.authentication_token or auth.authenticationToken

	if gIdToken == nil or gUserId == nil then
		C4:UpdateProperty("Status", "Login response missing fields")
		DebugPrint("Pool Robot: login response missing expected fields, raw body: " ..
			tostring(strData))
		gPollAfterLogin = false
		gRefreshAfterLogin = false
		return
	end

	C4:UpdateProperty("Status", "Logged in")

	if gRefreshAfterLogin then
		gRefreshAfterLogin = false
		FetchDevices()
	end

	if gPendingAction ~= nil then
		ConnectAndSend(GetSelectedSerial(), gPendingAction)
	end

	if gPollAfterLogin then
		gPollAfterLogin = false
		PollStatus()
	end
end

-- Parses a GET .../shadow response and syncs the Status property, the
-- Current State property, and the button icon from the robot's actual
-- reported state -- independent of whatever the websocket flow is doing.
function HandleStatusResponse(strData, responseCode, errMsg)
	gStatusTicket = nil

	if tonumber(responseCode) == 401 or tonumber(responseCode) == 403 then
		-- token likely expired -- force a fresh login on the next poll
		gIdToken, gUserId, gAuthToken = nil, nil, nil
	end

	if tonumber(responseCode) ~= 200 then
		DebugPrint("Pool Robot: status poll failed, response code: " .. tostring(responseCode) ..
			" err: " .. tostring(errMsg) .. " body: " .. tostring(strData))
		return
	end

	local shadow, _, decodeErr = json.decode(strData)
	if shadow == nil then
		DebugPrint("Pool Robot: could not parse status response (" ..
			tostring(decodeErr) .. "): " .. tostring(strData))
		return
	end

	local reported = shadow.state ~= nil and shadow.state.reported
	local robot = reported ~= false and reported ~= nil and reported.equipment ~= nil
		and reported.equipment.robot
	local robotState = robot ~= false and robot ~= nil and robot.state

	if robot ~= false and robot ~= nil then
		UpdateCanister(robot.canister)
	end

	if robotState == nil or robotState == false then
		DebugPrint("Pool Robot: status response missing equipment.robot.state, raw body: " ..
			tostring(strData))
		return
	end

	DisplayState(robotState == 1)
	C4:UpdateProperty("Status", (robotState == 1) and "Cleaning" or "Idle")
	DebugPrint("Pool Robot: polled status, robot.state=" .. tostring(robotState))
end

-- ===================== Canister =====================

-- equipment.robot.canister: 0 = OK, 1 = needs emptying (per community
-- reverse-engineering of VR/Vortex robots; not confirmed against every
-- model). Fires "Canister Full" / "Canister Emptied" only on a change.
function UpdateCanister(value)
	local n = tonumber(value)
	if n == nil then
		return -- field not present for this robot/message
	end
	local isFull = n ~= 0
	C4:UpdateProperty("Canister", isFull and "Full" or "OK")
	DebugPrint("Pool Robot: canister=" .. tostring(value))

	if isFull == gCanisterFull then
		return
	end
	local wasKnown = gCanisterFull ~= nil
	gCanisterFull = isFull
	PersistData["CanisterFull"] = isFull

	if isFull then
		C4:FireEvent("Canister Full")
	elseif wasKnown then
		C4:FireEvent("Canister Emptied")
	end
end

-- ===================== Robot list (dropdown) =====================

-- Builds the dropdown label for a device: "Name (SERIAL)", or just the
-- serial when the device has no name. Commas are stripped because the
-- property list is comma-separated.
function MakeRobotLabel(name, serial)
	name = tostring(name or ""):gsub(",", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
	if name == "" or name == serial then
		return serial
	end
	return name .. " (" .. serial .. ")"
end

function SerialFromLabel(label)
	if label == nil or label == "" or label == NO_ROBOTS_ITEM then
		return nil
	end
	return string.match(label, "%(([^%(%)]+)%)%s*$") or label
end

function SetSelectedRobot(label, serial)
	gRobotLabels[label] = serial
	PersistData["RobotSerial"] = serial
	PersistData["RobotLabel"] = label
	C4:UpdateProperty("Robot Serial", serial)
	if serial ~= gWsSerial then
		gWsSerial = nil -- next command authorizes against the new robot
	end
end

function RefreshRobotList()
	if not HaveCredentials() then
		C4:UpdateProperty("Status", "Error: Email/Password not set")
		return
	end
	if gAuthToken ~= nil and gUserId ~= nil then
		FetchDevices()
	else
		gRefreshAfterLogin = true
		Login()
	end
end

function FetchDevices()
	if gDevicesTicket ~= nil then
		return
	end
	local url = DEVICES_URL ..
		"?api_key=" .. API_KEY ..
		"&authentication_token=" .. tostring(gAuthToken) ..
		"&user_id=" .. tostring(gUserId)
	local headers = {
		["User-Agent"] = USER_AGENT,
		["Accept"] = "application/json",
	}
	C4:UpdateProperty("Status", "Loading robot list...")
	gDevicesTicket = C4:urlGet(url, headers)
	DebugPrint("Pool Robot: device list request sent, ticket=" .. tostring(gDevicesTicket))
end

function OnDevicesResponse(strData, responseCode, errMsg)
	local code = tonumber(responseCode)

	if (code == 401 or code == 403) and not gDevicesRetried then
		-- token expired: log in again once and retry
		DebugPrint("Pool Robot: device list returned " .. tostring(code) .. ", re-logging in")
		gDevicesRetried = true
		gIdToken, gUserId, gAuthToken = nil, nil, nil
		gRefreshAfterLogin = true
		Login()
		return
	end
	gDevicesRetried = false

	if code ~= 200 then
		C4:UpdateProperty("Status", "Robot list failed (" .. tostring(responseCode) .. ")")
		DebugPrint("Pool Robot: device list failed, code=" .. tostring(responseCode) ..
			" err=" .. tostring(errMsg) .. " body=" .. tostring(strData))
		return
	end

	local data = json.decode(strData)
	if type(data) == "table" and data[1] == nil and type(data.devices) == "table" then
		data = data.devices
	end
	if type(data) ~= "table" then
		C4:UpdateProperty("Status", "Robot list parse error")
		DebugPrint("Pool Robot: could not parse device list: " .. tostring(strData))
		return
	end

	gRobotLabels = {}
	local labels = {}
	for _, dev in ipairs(data) do
		local serial = dev.serial_number or dev.serialNumber or dev.serial
		local name = dev.name or ""
		DebugPrint("Pool Robot: device name=" .. tostring(name) ..
			" type=" .. tostring(dev.device_type) .. " serial=" .. tostring(serial))
		local nameKey = string.lower(tostring(name)):gsub("^%s+", ""):gsub("%s+$", "")
		if serial ~= nil and serial ~= "" and not EXCLUDED_DEVICE_NAMES[nameKey] then
			serial = tostring(serial)
			local label = MakeRobotLabel(name, serial)
			gRobotLabels[label] = serial
			table.insert(labels, label)
		end
	end

	if #labels == 0 then
		C4:UpdatePropertyList("Robot", NO_ROBOTS_ITEM, NO_ROBOTS_ITEM)
		C4:UpdateProperty("Status", "No robots found on account")
		return
	end

	-- Keep the current selection if it's still on the account; otherwise
	-- pick the first robot (common case: only one robot on the account).
	local current = GetSelectedSerial()
	local selected = labels[1]
	for _, label in ipairs(labels) do
		if gRobotLabels[label] == current then
			selected = label
		end
	end

	C4:UpdatePropertyList("Robot", table.concat(labels, ","), selected)
	C4:UpdateProperty("Robot", selected)
	SetSelectedRobot(selected, gRobotLabels[selected])
	C4:UpdateProperty("Status", "Found " .. tostring(#labels) .. " robot(s)")
	if gRobotLabels[selected] ~= current then
		PollStatus()
	end
end

-- ===================== WebSocket session =====================

function ConnectAndSend(serial, state)
	gWsSerial = serial
	gPendingAction = state

	DebugPrint("Pool Robot: ConnectAndSend serial=" .. tostring(serial) ..
		" state=" .. tostring(state) ..
		" gWsConnected=" .. tostring(gWsConnected) ..
		" gWsHandshakeDone=" .. tostring(gWsHandshakeDone))

	if gWsConnected and gWsHandshakeDone then
		gWsAuthorized = false
		SendAuthorize(serial)
	else
		C4:UpdateProperty("Status", "Connecting...")
		C4:NetConnect(NET_BINDING, WS_PORT)
		DebugPrint("Pool Robot: C4:NetConnect called for " .. WS_HOST .. ":" .. tostring(WS_PORT))
	end
end

-- Global callback for TCP/TLS connection state changes.
function OnConnectionStatusChanged(idBinding, nPort, strStatus)
	DebugPrint("Pool Robot: OnConnectionStatusChanged idBinding=" .. tostring(idBinding) ..
		" nPort=" .. tostring(nPort) .. " strStatus=" .. tostring(strStatus))

	if idBinding ~= NET_BINDING then
		return
	end

	gWsConnected = (strStatus == "ONLINE")

	if gWsConnected then
		gWsHandshakeDone = false
		gWsAuthorized = false
		gWsBuffer = ""
		SendWsHandshake()
	else
		gWsHandshakeDone = false
		gWsAuthorized = false
		gWsFragment = nil
		gSentState = nil
		if gCloseTimerId ~= nil then
			gCloseTimerId = C4:KillTimer(gCloseTimerId)
		end
		C4:UpdateProperty("Status", "Disconnected")
	end
end

function SendWsHandshake()
	local keyBytes = ""
	for i = 1, 16 do
		keyBytes = keyBytes .. string.char(math.random(0, 255))
	end
	gWsKey = C4:Base64Encode(keyBytes)

	local reqLines = {
		"GET " .. WS_PATH .. " HTTP/1.1",
		"Host: " .. WS_HOST,
		"Upgrade: websocket",
		"Connection: Upgrade",
		"Sec-WebSocket-Key: " .. gWsKey,
		"Sec-WebSocket-Version: 13",
		"Authorization: Bearer " .. tostring(gIdToken),
		"User-Agent: " .. USER_AGENT,
	}
	local reqStr = table.concat(reqLines, "\r\n") .. "\r\n\r\n"
	DebugPrint("Pool Robot: sending WS handshake, key=" .. tostring(gWsKey))
	C4:SendToNetwork(NET_BINDING, WS_PORT, reqStr)
end

-- Global callback for inbound bytes on the raw TCP/TLS connection.
function ReceivedFromNetwork(idBinding, nPort, strData)
	if idBinding ~= NET_BINDING then
		return
	end

	DebugPrint("Pool Robot: ReceivedFromNetwork " .. tostring(string.len(strData)) .. " bytes, handshakeDone=" .. tostring(gWsHandshakeDone))

	gWsBuffer = gWsBuffer .. strData

	if not gWsHandshakeDone then
		ParseHandshakeResponse()
	else
		ParseWsFrames()
	end
end

function ParseHandshakeResponse()
	local headerEnd = string.find(gWsBuffer, "\r\n\r\n", 1, true)
	if headerEnd == nil then
		return -- wait for more data
	end

	local headerBlock = string.sub(gWsBuffer, 1, headerEnd - 1)
	gWsBuffer = string.sub(gWsBuffer, headerEnd + 4)

	local acceptKey = nil
	for line in string.gmatch(headerBlock, "([^\r\n]+)") do
		local k, v = string.match(line, "^([%w%-]+):%s*(.+)$")
		if k ~= nil and string.lower(k) == "sec-websocket-accept" then
			acceptKey = v
		end
	end

	local expected = C4:Hash("sha1", gWsKey .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11",
		{ ["return_encoding"] = "BASE64" })

	DebugPrint("Pool Robot: WS handshake response, acceptKey=" .. tostring(acceptKey) ..
		" expected=" .. tostring(expected))

	if acceptKey ~= nil and acceptKey == expected then
		gWsHandshakeDone = true
		C4:UpdateProperty("Status", "Connected")
		gWsAuthorized = false
		DebugPrint("Pool Robot: WS handshake OK, sending authorize for " .. tostring(gWsSerial))
		SendAuthorize(gWsSerial)
		if string.len(gWsBuffer) > 0 then
			ParseWsFrames()
		end
	else
		DebugPrint("Pool Robot: websocket handshake failed, headers: " .. headerBlock)
		C4:UpdateProperty("Status", "Handshake failed")
	end
end

function SendAuthorize(serial)
	SendWsMessage(json.encode({
		action = "authorize",
		version = 1,
		namespace = "authorization",
		payload = { userId = gUserId },
		service = "Authorization",
		target = serial,
	}))
end

function MakeClientToken()
	local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
	local function rand22()
		local out = {}
		for i = 1, 22 do
			local n = math.random(1, string.len(chars))
			table.insert(out, string.sub(chars, n, n))
		end
		return table.concat(out)
	end
	return tostring(gUserId) .. "|" .. rand22() .. "|" .. rand22()
end

function SendSetCleanerState(serial, state)
	SendWsMessage(json.encode({
		action = "setCleanerState",
		version = 1,
		namespace = "vr",
		payload = {
			state = { desired = { equipment = { robot = { state = state } } } },
			clientToken = MakeClientToken(),
		},
		service = "StateController",
		target = serial,
	}))
	C4:UpdateProperty("Status", (state == 1 and "Start" or "Stop") .. " command sent")

	gSentState = state

	-- The websocket only needs to stay open long enough to see the
	-- server echo our desired state back. Rather than leave the TLS
	-- connection sitting open indefinitely, force-close it a few
	-- seconds after sending in case that confirmation is slow or never
	-- arrives (OnWsMessage below closes it immediately on confirmation).
	if gCloseTimerId ~= nil then
		gCloseTimerId = C4:KillTimer(gCloseTimerId)
	end
	gCloseTimerId = C4:AddTimer(8, "SECONDS", false)
end

-- Global callback for Control4 timers (C4:AddTimer).
function OnTimerExpired(idTimer)
	if idTimer == gCloseTimerId then
		gCloseTimerId = nil
		DebugPrint("Pool Robot: closing websocket (timed out waiting for ack)")
		CloseWebSocket()
	elseif idTimer == gPollTimerId then
		DebugPrint("Pool Robot: polling status (timer)")
		PollStatus()
	end
end

-- Sends a WS close frame as a courtesy, then tears down the underlying
-- TCP/TLS connection and resets session state so it's fully closed
-- rather than left open and idle.
function CloseWebSocket()
	if gWsConnected then
		local mask = { math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255) }
		local pkt = string.char(0x88, BOr(0, 0x80)) ..
			string.char(mask[1], mask[2], mask[3], mask[4])
		C4:SendToNetwork(NET_BINDING, WS_PORT, pkt)
	end

	C4:NetDisconnect(NET_BINDING, WS_PORT)

	gWsConnected = false
	gWsHandshakeDone = false
	gWsAuthorized = false
	gWsFragment = nil
	gWsBuffer = ""
	gSentState = nil

	if gCloseTimerId ~= nil then
		gCloseTimerId = C4:KillTimer(gCloseTimerId)
	end

	C4:UpdateProperty("Status", "Idle")
end

-- Handles every text frame on the websocket: the first payload for our
-- target serial after "authorize" triggers the queued state command
-- (mirroring the app waiting for the device's current reported state
-- before issuing any command); later messages are checked for the
-- server echoing our desired state back, confirming it was accepted --
-- at which point the websocket is closed rather than left open.
function OnWsMessage(strData)
	DebugPrint("Pool Robot: WS message (" .. tostring(string.len(strData)) .. " bytes): " ..
		string.sub(strData, 1, 300))
	local msg = json.decode(strData)
	if msg == nil or msg.target ~= gWsSerial then
		return
	end

	if not gWsAuthorized and msg.payload ~= nil then
		gWsAuthorized = true

		-- Sync our toggle state from the robot's actual reported state
		-- (not just what we last commanded) so the icon reflects reality
		-- after a driver reload or a change made from the iAquaLink app.
		local robot = msg.payload.robot
		local reportedState = robot ~= nil and robot.state ~= nil and robot.state.reported
		local reportedRobotState = reportedState ~= false and reportedState ~= nil
			and reportedState.equipment ~= nil and reportedState.equipment.robot ~= nil
			and reportedState.equipment.robot.state
		if reportedRobotState ~= nil and reportedRobotState ~= false then
			DisplayState(reportedRobotState == 1)
		end
		if reportedState ~= false and reportedState ~= nil
			and reportedState.equipment ~= nil and reportedState.equipment.robot ~= nil then
			UpdateCanister(reportedState.equipment.robot.canister)
		end

		if gPendingAction ~= nil then
			local state = gPendingAction
			gPendingAction = nil
			SendSetCleanerState(gWsSerial, state)
		end
		return
	end

	local desired = msg.payload ~= nil and msg.payload.state ~= nil and msg.payload.state.desired
	local robotState = desired ~= false and desired ~= nil and desired.equipment ~= nil
		and desired.equipment.robot ~= nil and desired.equipment.robot.state
	if robotState ~= nil and robotState ~= false then
		C4:UpdateProperty("Status", "Robot state = " .. tostring(robotState))
		if gSentState ~= nil and robotState == gSentState then
			DisplayState(robotState == 1)
			DebugPrint("Pool Robot: command confirmed, closing websocket")
			CloseWebSocket()
		end
	end
end

-- ===================== Minimal RFC 6455 client framing =====================
-- Client->server frames must be masked; server->client frames are not.
--
-- Portable bitwise helpers: some Control4 drivers run under plain PUC Lua
-- (no "bit" library, which is a LuaJIT-only feature) rather than LuaJIT,
-- so these avoid depending on a global "bit" table that may not exist.

function BAnd(a, b)
	local result, bitval = 0, 1
	while a > 0 and b > 0 do
		if a % 2 == 1 and b % 2 == 1 then
			result = result + bitval
		end
		a = math.floor(a / 2)
		b = math.floor(b / 2)
		bitval = bitval * 2
	end
	return result
end

function BOr(a, b)
	local result, bitval = 0, 1
	while a > 0 or b > 0 do
		if a % 2 == 1 or b % 2 == 1 then
			result = result + bitval
		end
		a = math.floor(a / 2)
		b = math.floor(b / 2)
		bitval = bitval * 2
	end
	return result
end

function BXor(a, b)
	local result, bitval = 0, 1
	while a > 0 or b > 0 do
		if (a % 2 == 1) ~= (b % 2 == 1) then
			result = result + bitval
		end
		a = math.floor(a / 2)
		b = math.floor(b / 2)
		bitval = bitval * 2
	end
	return result
end

local Unpack = table.unpack or unpack

function MaskData(s, mask)
	local out = {}
	local mlen = #mask
	for i = 1, string.len(s) do
		local b = string.byte(s, i)
		local m = mask[((i - 1) % mlen) + 1]
		table.insert(out, string.char(BXor(b, m)))
	end
	return table.concat(out)
end

function SendWsMessage(strPayload)
	local len = string.len(strPayload)
	local pkt = {}

	if len <= 125 then
		table.insert(pkt, string.char(0x81, BOr(len, 0x80)))
	elseif len <= 65535 then
		table.insert(pkt, string.char(0x81, BOr(126, 0x80),
			math.floor(len / 256) % 256, len % 256))
	else
		local bytes = {}
		local remaining = len
		for i = 8, 1, -1 do
			bytes[i] = remaining % 256
			remaining = math.floor(remaining / 256)
		end
		table.insert(pkt, string.char(0x81, BOr(127, 0x80)))
		table.insert(pkt, string.char(Unpack(bytes)))
	end

	local mask = { math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255) }
	table.insert(pkt, string.char(mask[1], mask[2], mask[3], mask[4]))
	table.insert(pkt, MaskData(strPayload, mask))

	C4:SendToNetwork(NET_BINDING, WS_PORT, table.concat(pkt))
end

function SendPong(payload)
	payload = payload or ""
	local mask = { math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255) }
	local header = string.char(0x8A, BOr(string.len(payload), 0x80))
	local pkt = header .. string.char(mask[1], mask[2], mask[3], mask[4]) .. MaskData(payload, mask)
	C4:SendToNetwork(NET_BINDING, WS_PORT, pkt)
end

function ParseWsFrames()
	local ok, err = pcall(ParseWsFramesInner)
	if not ok then
		DebugPrint("Pool Robot: ParseWsFrames ERROR: " .. tostring(err))
	end
end

function ParseWsFramesInner()
	while true do
		local buflen = string.len(gWsBuffer)
		DebugPrint("Pool Robot: ParseWsFrames buflen=" .. tostring(buflen))
		if buflen < 2 then
			return
		end

		local b1 = string.byte(gWsBuffer, 1)
		local b2 = string.byte(gWsBuffer, 2)
		local final = BAnd(b1, 0x80) == 0x80
		local opcode = BAnd(b1, 0x0F)
		local masked = BAnd(b2, 0x80) == 0x80
		local lenField = BAnd(b2, 0x7F)

		local headerLen = 2
		local payloadLen = lenField

		if lenField == 126 then
			if buflen < 4 then return end
			payloadLen = string.byte(gWsBuffer, 3) * 256 + string.byte(gWsBuffer, 4)
			headerLen = 4
		elseif lenField == 127 then
			if buflen < 10 then return end
			payloadLen = 0
			for i = 3, 10 do
				payloadLen = payloadLen * 256 + string.byte(gWsBuffer, i)
			end
			headerLen = 10
		end

		local maskBytes = nil
		if masked then
			if buflen < headerLen + 4 then return end
			maskBytes = {
				string.byte(gWsBuffer, headerLen + 1),
				string.byte(gWsBuffer, headerLen + 2),
				string.byte(gWsBuffer, headerLen + 3),
				string.byte(gWsBuffer, headerLen + 4),
			}
			headerLen = headerLen + 4
		end

		DebugPrint("Pool Robot: frame final=" .. tostring(final) ..
			" opcode=" .. tostring(opcode) ..
			" masked=" .. tostring(masked) ..
			" payloadLen=" .. tostring(payloadLen) ..
			" headerLen=" .. tostring(headerLen) ..
			" have=" .. tostring(buflen))

		if buflen < headerLen + payloadLen then
			return -- wait for the rest of this frame
		end

		local payload = string.sub(gWsBuffer, headerLen + 1, headerLen + payloadLen)
		if masked and maskBytes ~= nil then
			payload = MaskData(payload, maskBytes)
		end

		gWsBuffer = string.sub(gWsBuffer, headerLen + payloadLen + 1)

		if opcode == 0x08 then
			C4:UpdateProperty("Status", "Closed by server")
		elseif opcode == 0x09 then
			SendPong(payload)
		elseif opcode == 0x00 then
			-- continuation frame: append to whatever fragment is in progress
			gWsFragment = (gWsFragment or "") .. payload
		elseif opcode == 0x01 or opcode == 0x02 then
			-- first frame of a (possibly fragmented) text/binary message
			gWsFragment = payload
		end

		if final and (opcode == 0x00 or opcode == 0x01 or opcode == 0x02) then
			local fullMessage = gWsFragment
			gWsFragment = nil
			if fullMessage ~= nil then
				OnWsMessage(fullMessage)
			end
		end
		-- loop again in case another full frame is already buffered
	end
end

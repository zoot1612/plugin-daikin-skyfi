local http = require("socket.http")
local ltn12 = require("ltn12")
http.TIMEOUT = 10

local DEBUG_MODE = 1
local RETRY = 15
local VERSION = "0.118"

local skyfi_device = nil

local SKYFI_SID  = "urn:zoot-org:serviceId:SkyFi1"
local DEFAULT_SETPOINT = 24
local DEFAULT_POLL = "1m"
local DEVICETYPE_ZONE = "urn:zoot-com:device:Damper:1"
local DEVICEFILE_ZONE = "D_Damper1.xml"

local SWP_SID = "urn:upnp-org:serviceId:SwitchPower1"
local SWP_STATUS = "Status"
local SWP_TARGET = "Target"
local SWP_SET_TARGET = "SetTarget"
local FAN_STATUS = "FanStatus" 

local TEMP_SID  = "urn:upnp-org:serviceId:TemperatureSensor1"
local FAN_SID  = "urn:upnp-org:serviceId:FanSpeed1"
local HVACO_SID = "urn:upnp-org:serviceId:HVAC_UserOperatingMode1"
local HVACF_SID  = "urn:upnp-org:serviceId:HVAC_FanOperatingMode1"
local HVACS_SID  = "urn:micasaverde-com:serviceId:HVAC_OperatingState1"
local HVACSET_SID= "urn:upnp-org:serviceId:TemperatureSetpoint1"
local HADEVICE_SID = "urn:micasaverde-com:serviceId:HaDevice1"

local HAD_POLL = "Poll"
local HAD_SET_POLL_FREQUENCY = "SetPollFrequency"
local HAD_LAST_UPDATE = "LastUpdate"
local HAD_COMM_FAILURE = "CommFailure"

local g_modes = {
  ['0'] = "Off",		--0000 0000 =  0 = Off
  ['2'] = "HeatOn",		--0000 0010 =  2 = HeatOn
  ['3'] = "AutoChangeOver",     --0000 0011 =  3 = Autochangeover on, HeatOn
  ['4'] = "Dry",		--0000 0100 =  4 = Dry 
  ['8'] = "CoolOn",		--0000 1000 =  8 = CoolOn
  ['9'] = "AutoChangeOver",	--0000 1001 =  9 = Autochangeover on, CoolOn
  ['16'] = "Fan"		--0001 0000 = 16 = Fan                  
}

local g_queue = {}
local g_config = {}
local g_param = {}
local g_settings = {}
local g_fan = {fanflags = 0, fanspeed = 0}

----------------------------------------------------------------------------------------------
local function decode(s)
  s = (s == nil) and "" or s:gsub("^%s*(.-)%s*$", "%1")
  return (string.gsub (string.gsub (s, "+", " "),"%%(%x%x)", function (str)
  return string.char (tonumber (str, 16)) end ))
end
----------------------------------------------------------------------------------------------
function log (text,level)
  luup.log("SkyFiPlugin::" .. (text or ""),level or 50)
end
----------------------------------------------------------------------------------------------
function debug (text,level)
  if (DEBUG_MODE == 1) then
    log(text,level or 1)
  end
end
----------------------------------------------------------------------------------------------
local function debug_mode()
  local debug = luup.variable_get(SKYFI_SID, "DebugMode", skyfi_device) or ""
  if (debug == "") then
    luup.variable_set(SKYFI_SID, "DebugMode", DEBUG_MODE, skyfi_device)
  else
    DEBUG_MODE = tonumber(debug)
  end
  log("Debug mode: "..(DEBUG_MODE == 1 and "enabled" or "disabled")..".")
end
----------------------------------------------------------------------------------------------
local function checkVersion()
  local ui7Check = luup.variable_get(SKYFI_SID, "UI7Check", skyfi_device) or ""
  if ui7Check == "" then
    luup.variable_set(ServiceId, "UI7Check", "false", skyfi_device)
    ui7Check = "false"
  end
  if( luup.version_branch == 1 and luup.version_major == 7 and ui7Check == "false") then
    luup.variable_set(SKYFI_SID, "UI7Check", "true", skyfi_device)
    luup.reload()
  end
end
----------------------------------------------------------------------------------------------
local function hex_2_bin(s)
  local h2b_table = {
    ["0"] = "0000",
    ["1"] = "0001",
    ["2"] = "0010",
    ["3"] = "0011",
    ["4"] = "0100",
    ["5"] = "0101",
    ["6"] = "0110",
    ["7"] = "0111",
    ["8"] = "1000",
    ["9"] = "1001",
    ["a"] = "1010",
    ["b"] = "1011",
    ["c"] = "1100",
    ["d"] = "1101",
    ["e"] = "1110",
    ["f"] = "1111"
  }
  local binary = ""
  local i = 0
  for i in string.gfind(s, ".") do
    i = string.lower(i)
    binary = binary .. h2b_table[i]
  end
  return binary
end
----------------------------------------------------------------------------------------------
local function find_child(parent_dev, label)
  for k, v in pairs(luup.devices) do
    if (tostring(v.device_num_parent) == tostring(parent_dev) and tostring(v.id) == label) then
      return k
    end
  end
  return false
end
----------------------------------------------------------------------------------------------
local function get_mode_number(label)
  for k, v in pairs(g_modes) do
    if (tostring(v) == label) then
      return k
    end
  end
  return false
end
----------------------------------------------------------------------------------------------
local function device_code()
  local code = luup.attr_get('altid', skyfi_device) or ""
  if (code == "") then
    return false
  else
    g_config[1] = {pass = code}
  end
  return true
end
----------------------------------------------------------------------------------------------
local function command_retry()
  local retry = luup.variable_get(SKYFI_SID, "Retry", skyfi_device) or ""
  if (retry ~= "") then
    RETRY = retry
  else
    luup.variable_set(SKYFI_SID, "Retry", RETRY, skyfi_device)
  end
  log("command_retry: " .. "Number of command retries: ".. retry .. ".")
end
----------------------------------------------------------------------------------------------
local function parse_body(body, function_table)
  if(body == nil or body == false) then return false end
    for pair in body:gmatch"[^&]+" do
      local key, value = pair:match"([^=]*)=(.*)"
      key = decode(key)
      value = decode(value)
      debug("parseBody: key=" .. (key or "") .. " value=" .. (value or "") .. ".")

      local response = function_table[key]
      if (response == nil or type(response.handler_func) ~= "function") then
        debug("parseBody: ERROR: Not handled parameter type:" .. (key or "") .. " value=" .. (value or "") .. ".")
      else
        response:handler_func(value, body)
      end
    
    end
    return true
end
----------------------------------------------------------------------------------------------
local function auto_config()
  local broadcast_ip = '255.255.255.255'
  local port = 55222
  local udp = socket.udp()
  assert(udp:settimeout(45),'Unable to set udp timeout')
  assert(udp:setsockname(broadcast_ip, port), 'Unable to set sockname')
  response, ip, port = udp:receivefrom()
  
  if(response) then
    response = (response:sub(33))
    debug("auto_config: Response " .. response)
    if(response:match("^wifly")) then
      luup.attr_set('model', response:match'(.+),', skyfi_device)
      return ip, port
    end
    return false
  end
end
----------------------------------------------------------------------------------------------
local function zone_create(params)
  if(params == "" or params == nil) then return false end
  child_device = luup.chdev.start(skyfi_device);
  for pair in params:gmatch"[^&]+" do
    local zone, name = pair:match"([^=]*)=(.*)"
    zone = decode(zone)
    name = decode(name)
    if(zone:match("^zone(%d+)")) then
      local zone_name = "DaikinAC_" .. name
      local hvac = "hvac_".. zone
      debug("Creating child " .. hvac .. " (" .. zone_name .. ") as " .. DEVICETYPE_ZONE)
      luup.chdev.append(skyfi_device,child_device,hvac,zone_name,DEVICETYPE_ZONE,DEVICEFILE_ZONE,"","",false)
    end
  end

  luup.chdev.sync(skyfi_device,child_device)
  for k, v in pairs(luup.devices) do
    if (tostring(v.device_num_parent) == tostring(skyfi_device)) then
      luup.attr_set("category_num", "5", k)
    end
  end
  return true
end
----------------------------------------------------------------------------------------------
local function configuration_update(key,config)
  if type(config) ~= "table" then return false end
  if(g_config[key]) then
    g_config[key]=config
  else
   table.insert(g_config, key, config)
  end
end
----------------------------------------------------------------------------------------------
local function fan_configuration_update()
  local fanflags = (tonumber(g_param["fanflags"]) == 3) and 4 or 0
  configuration_update(4,{f =  (g_param["fanspeed"] or 0) + fanflags})
end
----------------------------------------------------------------------------------------------
local function zone_status(zones)
  local number_zones = zones:len()
  for i = 1,number_zones do
    local status = zones:sub(i,i)
    local device = find_child(skyfi_device,"hvac_zone" .. i)
    if device == false then
      debug("zone_status: No device found")
      return false
    end
    debug("zone_status: Zone Status:" .. (status == "1" and "Open" or "Closed") .. " Device Number:" .. device .. ".")
    luup.variable_set(SWP_SID,SWP_STATUS,status,device)
    luup.variable_set (HADEVICE_SID, HAD_LAST_UPDATE, os.time(), device)
  end
end
----------------------------------------------------------------------------------------------
local g_identify = {
  ["identify"] = {
    description = "Air Coditioner Identification",
    handler_func = function (self, value)
      debug(self.description .. ": " .. value)
      luup.attr_set("manufacturer", value, skyfi_device)
      return true
    end
  },
  ["serial"] = {
    description = "Serial Number",
    handler_func = function (self, value)
      debug(self.description .. ": " .. value)
      luup.variable_set(SKYFI_SID, "SerialNumber", value, skyfi_device)
      return true
    end
  },
  ["fw"] = {
    description = "Current Firmware Version",
    handler_func = function (self, value)
      debug(self.description .. ": " .. value)
      luup.variable_set(SKYFI_SID, "FirmwareVersion", value, skyfi_device)
      return true
    end
  },
  ["wl"] = {
    description = "(wl) Unknown Function",
    handler_func = function (self, value)
      debug(self.description .. ": " .. value)
      g_param["wl"]  = value
      return true
    end
  },
  ["ver"] = {
    description = "Hardware Version",
    handler_func = function (self, value)
      debug(self.description .. ": " .. value)
      luup.variable_set(SKYFI_SID,  "Version", value, skyfi_device)
      return true
    end
  },
  ["zc"] = {
    description = "Zone Controller Available",
    handler_func = function (self, value)
      debug(self.description .. ": " .. (tonumber(value) == 1 and "yes" or "no"))
      luup.variable_set(SKYFI_SID,  "zc", value, skyfi_device)
      return true
    end
  },
  ["lc"] = {
    description = "(lc) Unknown Function",
    handler_func = function (self, value)
      debug(self.description .. ": " .. value)
      g_param["lc"]  = value
      return true
    end
  },
  ["ls"] = {
    description = "(ls) Unknown Function",
    handler_func = function (self, value)
      debug(self.description .. ": " .. value)
      g_param["ls"]  = value
      return true
    end
  },
  ["af"] = {
    description = "(af) Unknown Function",
    handler_func = function (self, value)
      debug(self.description .. ": " .. value)
      g_param["af"]  = value
      return true
    end
  }
}
----------------------------------------------------------------------------------------------
local g_status = {
   ["opmode"] = {
    description = "Air Coditioner Power Mode",
    handler_func = function (self, value)
      debug(self.description .. ": " .. (value == '1' and 'On' or 'Off'))
      luup.variable_set(SWP_SID, SWP_STATUS, value, skyfi_device)
      --luup.variable_set(HVACF_SID, FAN_STATUS, value, skyfi_device)
      configuration_update(2,{p=value})
      if (value == '0') then
        luup.variable_set(HVACO_SID, "ModeStatus", "Off", skyfi_device)
      else
        debug("AC is on, opmode: " .. value .. ".")
      end
      return true
    end
  },
  ["units"] = {
    description = "Units Connected",
    handler_func = function (self, value)
      debug(self.description .. ": " .. (value=="." and "yes" or "no"))
      g_param["units"] =  value
      luup.variable_set(SKYFI_SID,  "UnitsConnected", value, skyfi_device)
      return true
    end
  },
  ["settemp"] = {
    description = "AC Temperature Set Point",
    handler_func = function (self, value)
      debug(self.description .. ": " .. value)
      luup.variable_set(HVACSET_SID, "CurrentSetpoint", tonumber(string.format("%.f", value)), skyfi_device)
      value = string.format("%.6f",value,10)
      configuration_update(3,{t=value})
      return true
    end
  },
  ["fanspeed"] = {
    description = "Fan Speed",
    handler_func = function (self, value)
      debug(self.description .. ": " .. value)
      local speeds = {
        ['1'] = "35",
        ['2'] = "65",
        ['3'] = "100",       
      }
      luup.variable_set(FAN_SID, "FanSpeedStatus", (speeds[value] or "Unknown"), skyfi_device)
      g_param["fanspeed"] =  tonumber(value)
      fan_configuration_update ()
      return true
    end
  },
  ["fanflags"] = {
    description = "Fan Operational Mode",
    handler_func = function (self, value)
      debug(self.description .. ": " .. value)
      local modes = {
        ['1'] = "ContinuousOn",
        ['3'] = "Auto",       
      }
      luup.variable_set(HVACF_SID, "Mode", (modes[value] or "Unknown"), skyfi_device)
      g_param["fanflags"] =  tonumber(value)
      fan_configuration_update ()
      return true
    end
  },
  ["acmode"] = {
    description = "Air Coditioner Operational Mode",
    handler_func = function (self, value)
      debug(self.description .. ": " .. value)
      luup.variable_set(SKYFI_SID, "ModeStatusNo", value, skyfi_device)
      configuration_update(5,{m=value})
      if g_config[2].p ~= '0' then
        local ModeStatus = g_modes[value] or "Off"
        luup.variable_set(HVACO_SID, "ModeStatus", ModeStatus, skyfi_device)
      else
        debug("AC is off, opmode: " .. (g_modes[value] or '0') .. ".")
      end
      return true
    end
  },
  ["tonact"] = {
    description = "Time On Active",
    handler_func = function (self, value)
      debug(self.description .. ": " .. value)
      g_param["tonact"] =  value
      luup.variable_set(SKYFI_SID, "TimeOnActive", value, skyfi_device)
      return true
    end
  },
  ["toffact"] = {
    description = "Time Off Active",
    handler_func = function (self, value)
      debug(self.description .. ": " .. value)
      g_param["toffact"] =  value
      luup.variable_set(SKYFI_SID, "TimeOffActive", value, skyfi_device)
      return true
    end
  },
  ["prog"] = {
    description = "Program",
    handler_func = function (self, value)
      debug(self.description .. ": " .. value)
      g_param["prog"] =  value
      luup.variable_set(SKYFI_SID, "Program", value, skyfi_device)
      return true
    end
  },
  ["time"] = {
    description = "Time",
    handler_func = function (self, value)
      debug(self.description .. ": " .. value)
      g_param["time"] =  value
      luup.variable_set(SKYFI_SID, "ACTime", value, skyfi_device)
      return true
    end
  },
  ["day"] = {
    description = "Day",
    handler_func = function (self, value)
      debug(self.description .. ": " .. value)
      g_param["day"] =  value
      luup.variable_set(SKYFI_SID,  "ACDay", value, skyfi_device)
      return true
    end
  },
  ["roomtemp"] = {
    description = "Current Room Temperature",
    handler_func = function (self, value)
      debug(self.description .. ": " .. value)
      g_param["roomtemp"] =  value
      luup.variable_set(TEMP_SID,  "CurrentTemperature", (tonumber(value, 10)), skyfi_device)
      return true
    end
  },
  ["outsidetemp"] = {
    description = "Current Outside Temperature",
    handler_func = function (self, value)
      debug(self.description .. ": " .. value)
      g_param["outsidetemp"] =  value
      local sensor = luup.variable_get(SKYFI_SID,  "Sensors", skyfi_device)
      value = (tonumber(sensor,10) == 1) and 'na' or tonumber(value, 10)
      luup.variable_set(TEMP_SID,  "OutsideTemperature", value, skyfi_device)
      return true
    end
  },
  ["louvre"] = {
    description = "Louvre",
    handler_func = function (self, value)
      debug(self.description .. ": " .. value)
      luup.variable_set(SKYFI_SID, "Louvre", value, skyfi_device)
      configuration_update(6,{lv = value})
      return true
    end
  },
  ["zone"] = {
    description = "Zone",
    handler_func = function (self, value)
      debug(self.description .. ": " .. value)
      g_settings["zone"] =  value
      local zones = hex_2_bin(string.format("%x", tonumber(value,10)))
      luup.variable_set(SKYFI_SID,  "Zones", zones, skyfi_device)
      if ((luup.variable_get(SKYFI_SID,  "zc", skyfi_device)) == "1") then zone_status(zones) end
      return true
    end
  },
  ["flt"] = {
    description = "Filter",
    handler_func = function (self, value)
      debug(self.description .. ": " .. value)
      g_param["flt"] =  value
      luup.variable_set(SKYFI_SID,  "Filter", value, skyfi_device)
      return true
    end
  },
  ["test"] = {
    description = "Test",
    handler_func = function (self, value)
      debug(self.description .. ": " .. value)
      g_param["test"] =  value
      luup.variable_set(SKYFI_SID,  "Test", value, skyfi_device)
      return true
    end
  },
  ["errdata"] = {
    description = "Error Data",
    handler_func = function (self, value)
      debug(self.description .. ": " .. value)
      g_param["errdata"] =  value
      luup.variable_set(SKYFI_SID,  "ErrorData", value, skyfi_device)
      return true
    end
  },
  ["sensors"] = {
    description = "Sensors",
    handler_func = function (self, value)
      debug(self.description .. ": " .. value)
      g_param["sensors"] =  value
      luup.variable_set(SKYFI_SID,  "Sensors", value, skyfi_device)
      return true
    end
  }
}
----------------------------------------------------------------------------------------------
function http_request(args, retry)
  retry = retry or RETRY
  local resp = {}
  base_url = 'http://' .. luup.attr_get('ip', skyfi_device) .. ':2000'
  
  if args.endpoint then
    local params = ""
    if args.method == nil or args.method == "GET" then
      if args.params then
        for k, v in ipairs(args.params) do
          for i, v in pairs(v) do
            params = params .. i .. "=" .. v .. "&"
          end
        end
      else
        for i, v in pairs(g_config[1]) do
          params = params .. i .. "=" .. v .. "&"
        end
      end
    end
    params = (string.sub(params, 1, -2))
    args.headers={["connection"] = "close",["content-Type"] = "text/html",["Content-Length"] = string.len(params)}
    local url = ""
  
    if params then
      url = base_url .. args.endpoint .. "?" .. params
    else
      url = base_url .. args.endpoint
    end
  
    debug("http_request: request: " .. url)
    socket.sleep(5)
    client, code, headers, status = http.request {
      url=url, 
      sink=ltn12.sink.table(resp),
      method=args.method or "GET",
      headers=args.headers,
      source=args.source
    }
  else
    debug("http_request: endpoint is missing")
  end
  
  resp = table.concat(resp)
  local resp_match = args.resp_match
  debug("http_request: Client: " .. (client or "none") .. ". Code: " .. (code or "none") .. ". Status: " .. (status or "none") .. ".")  
  log("http_request: Response: " .. resp, retry)
  
  if (code == 200 and resp:match("^" .. resp_match .. "")) then return resp end
  
  retry = retry - 1
  if retry == 0 then 
    debug("http_request: Number of command retries exceeded")
    return false
  else
    http_request(args, retry)
  end
end
----------------------------------------------------------------------------------------------
function ac_update()
  local poll_interval = luup.variable_get(HADEVICE_SID,HAD_POLL,skyfi_device) or ""
  if (poll_interval == "") then
    poll_interval = DEFAULT_POLL
    luup.variable_set(HADEVICE_SID,HAD_POLL,poll_interval,skyfi_device)
  end
  luup.call_timer("ac_update", 1, poll_interval, "", "")
  luup.variable_set(HADEVICE_SID, "LastUpdate", tostring(os.time()), skyfi_device)
  
  local config_state = luup.variable_get(HADEVICE_SID,"Configured", skyfi_device) or ""
  if (config_state ~= "1") then
    return configure()
  else
    local response = http_request({endpoint="/ac.cgi", resp_match = "opmode"})
    return parse_body(response, g_status)
  end
 end
----------------------------------------------------------------------------------------------
function set_fan_mode(lul_device, new_mode)
  local fanspeed = (tonumber(g_param["fanspeed"])) 
  local fanflags = new_mode == 'Auto' and 4 or 0 
  if(fanspeed >= 0 and fanspeed <= 3 ) then
    g_config[4].f =  fanspeed + fanflags
  else
    debug("set_fan_mode: Unknown mode:" .. new_mode)
    return false
  end
  local response = http_request({endpoint="/set.cgi", params = g_config, resp_match = "opmode"})
  return parse_body(response, g_status)
end
----------------------------------------------------------------------------------------------
local function set_fan_speed(lul_device, FanSpeedTarget)
  local target = tonumber(FanSpeedTarget,10)
  local fanflags = (tonumber(g_param["fanflags"]) == 3) and 4 or 0
  if(target >= 0 and target <= 3 ) then
    g_config[4].f =  target + fanflags
  else
    debug("set_fan_speed: Unknown speed:" .. FanSpeedTarget)
    return false
  end

  local response = http_request({endpoint="/set.cgi", params = g_config, resp_match = "opmode"})
  return parse_body(response, g_status)
end
----------------------------------------------------------------------------------------------
local function set_mode_target(lul_device, NewModeTarget)
  g_config[2].p = (NewModeTarget == "Off") and 0 or 1
  g_config[5].m = get_mode_number(NewModeTarget) or "0"
  local response = http_request({endpoint="/set.cgi", params = g_config, resp_match = "opmode"})
  return parse_body(response, g_status)
end
----------------------------------------------------------------------------------------------
local function set_target(lul_device, new_target_value)
  local zone_no = (tostring(luup.devices[lul_device].id)):match("^hvac_zone(%d+)")
  local param = {g_config[1], {z= zone_no}, {s= new_target_value}}
  local response = http_request({endpoint="/setzone.cgi", params = param, resp_match = "opmode"})
  return parse_body(response, g_status)
end
  ----------------------------------------------------------------------------------------------
local function set_point(device, new_current_setpoint)
  local current_set_point = luup.variable_get(HVACSET_SID, "CurrentSetpoint", skyfi_device) or ""
  local value = tonumber(new_current_setpoint) or current_set_point
  g_config[3].t = string.format("%.6f",value,10)
  local response = http_request({endpoint="/set.cgi", params = g_config, resp_match = "opmode"})
  return parse_body(response, g_status)
end
----------------------------------------------------------------------------------------------
local function concat_table()
  local str=""
  for k, v in pairs(g_param) do
    str = str .. k .. '=' .. v .. ','
  end
  return str
end
----------------------------------------------------------------------------------------------
function get_identity()
  local response = http_request({endpoint="/identify.cgi", resp_match = "identify"})
  debug("DaikinSkyStartup:identify query:" .. (response or "none"))
  return parse_body(response, g_identify)
end
----------------------------------------------------------------------------------------------
function get_status()
  response = http_request({endpoint="/ac.cgi", resp_match = "opmode"})
  debug("DaikinSkyStartup:status query:" .. (response or "none"))
  return parse_body(response, g_status)
end
----------------------------------------------------------------------------------------------
function get_zones()
  response = http_request({endpoint="/zones.cgi", resp_match = "nz"})
  debug("DaikinSkyStartup:zone query:" .. (response or "none"))
  if(response) then
    return zone_create(response)
  else
    return false
  end
end
----------------------------------------------------------------------------------------------
function configure()
  log("Configuring plugin ...")

  local status = luup.variable_get(SWP_SID, SWP_STATUS, skyfi_device) or ""
  if status == "" then
    luup.variable_set(SWP_SID, SWP_STATUS, 0, skyfi_device)
  end
  configuration_update(2,{p=status})

  local current_set_point = luup.variable_get(HVACSET_SID, "CurrentSetpoint", skyfi_device) or ""
  if current_set_point == "" then
    current_set_point = DEFAULT_SETPOINT
    luup.variable_set(HVACSET_SID, "CurrentSetpoint", current_set_point, skyfi_device)
  end
  current_set_point = string.format("%.6f", current_set_point, 10)
  configuration_update(3,{t=current_set_point})

  local fan_speed_status = luup.variable_get(FAN_SID, "FanSpeedStatus", skyfi_device) or ""
  local mode = luup.variable_get(HVACF_SID, "Mode", skyfi_device) or ""
  if fan_speed_status == "" then
    luup.variable_set(FAN_SID, "FanSpeedStatus", 0, skyfi_device)
  end
  if mode == "" then
    luup.variable_set(HVACF_SID, "Mode", 0, skyfi_device)
  end
  g_param["fanflags"] =  tonumber(fan_speed_status)
  fan_configuration_update ()

  local mode_status = luup.variable_get(HVACO_SID, "ModeStatus", skyfi_device) or ""
  if mode_status == "" then
    luup.variable_set(HVACO_SID, "ModeStatus", "Off", skyfi_device)
  end
  configuration_update(5,{m=0})

  local louvre = luup.variable_get(SKYFI_SID, "Louvre", skyfi_device) or ""
  if louvre == "" then
    luup.variable_set(SKYFI_SID, "Louvre", 0, skyfi_device)
  end
  configuration_update(6,{lv = louvre})
  
  local ident_configured = luup.variable_get(SKYFI_SID,"IdentConfigured", skyfi_device) or ""
  if (ident_configured == "") then
    luup.variable_set(SKYFI_SID,"IdentConfigured", 0 ,skyfi_device)
  end
  ident_configured = tonumber(ident_configured,10)

  local zone_configured = luup.variable_get(SKYFI_SID,"ZoneConfigured", skyfi_device) or ""
  if (zone_configured == "") then
    luup.variable_set(SKYFI_SID,"ZoneConfigured", 0 ,skyfi_device)
  end
  zone_configured = tonumber(zone_configured,10)

  if(ident_configured ~= 1) then
    debug("Configuring unit identity ...")
    luup.variable_set(SKYFI_SID, "IdentConfigured", -2 ,skyfi_device)
    if(get_identity() == true) then
      luup.variable_set(SKYFI_SID, "IdentConfigured", 1 ,skyfi_device)
      luup.variable_set(SKYFI_SID,"Parameters", concat_table() or "", skyfi_device)
    end
  end
  local zone_controller = luup.variable_get(SKYFI_SID,  "zc", skyfi_device) or ""

  if(zone_configured ~= 1) then
    debug("Configuring zone controller ...")
    if(tonumber(zone_controller,10) == 1) then
      luup.variable_set(SKYFI_SID,"ZoneConfigured", -2 ,skyfi_device)
      if (get_zones() == true) then 
        luup.variable_set(SKYFI_SID,"ZoneConfigured", 1 ,skyfi_device)
      end
    end
    --luup.variable_set(SKYFI_SID,"ZoneConfigured", 1 ,skyfi_device)
  end

  debug("Getting controller status ...")
  if(zone_configured == 1 and ident_configured == 1) then
    if (get_status() == true) then 
      luup.variable_set(HADEVICE_SID,"Configured", 1, skyfi_device)
    end
  end

  return true
end
----------------------------------------------------------------------------------------------
function daikin_sky_startup(lul_device)
  skyfi_device = lul_device
  log(":Daikin SkyFi Plugin version " .. VERSION .. ".")
  luup.variable_set(SKYFI_SID, "PluginVersion", VERSION, skyfi_device)
  
  checkVersion()
  
  debug_mode()
  
  command_retry()

  local config_state = luup.variable_get(HADEVICE_SID,"Configured", skyfi_device) or ""
  if (config_state == "") then
    luup.variable_set(HADEVICE_SID,"Configured","0", skyfi_device)
  end

  log(":Starting SKYFi Plugin version " .. VERSION .. ".")
  
  if (device_code() == false) then
    return false, "No Device Code, please enter device code", "Daikin SKYFi"
  end
  
  local ip = luup.attr_get('ip', skyfi_device) or ""
  
  if (ip == "") then
    local ip_address, port = auto_config()
    if(ip_address) then
      luup.attr_set('ip', ip , skyfi_device)
    else
      return false, "Cannot auto configure, please try entering IP address and port.", "Daikin SKYFi"
    end
  else
    luup.set_failure(false, skyfi_device)
    luup.call_delay("configure", 10, "")
    luup.call_delay("ac_update", 30, "")
  end

  log("SkyFi Plugin Startup SUCCESS: Startup successful.")
  return true, "Startup successful.", "Daikin SkyFi"
end


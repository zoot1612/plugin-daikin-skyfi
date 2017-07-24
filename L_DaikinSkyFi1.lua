local socket = require("socket")
local http = require("socket.http")
local ltn12 = require("ltn12")
http.TIMEOUT = 10

local DEBUG_MODE = 1
local RETRY = 15
local VERSION = "0.15"

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
    luup.variable_set(SKYFI_SID, "UI7Check", "false", skyfi_device)
    ui7Check = "false"
  end
  if( luup.version_branch == 1 and luup.version_major == 7 and ui7Check == "false") then
    luup.variable_set(SKYFI_SID, "UI7Check", "true", skyfi_device)
    luup.attr_set("device_json", "D_DaikinSkyFi1_UI7.json", skyfi_device)
    luup.reload()
  end
end
----------------------------------------------------------------------------------------------
function registerWithAltUI()
   -- Register with ALTUI once it is ready
   for k, v in pairs(luup.devices) do
      if (v.device_type == "urn:schemas-upnp-org:device:altui:1") then
         if luup.is_ready(k) then
                 luup.log("Found ALTUI device "..k.." registering devices.")
            local arguments_main = {}
            arguments_main["newDeviceType"] = "urn:zoot-com:device:DaikinSkyFi:1"   
            arguments_main["newScriptFile"] = "J_ALTUI_daikin.js"
            arguments_main["newDeviceDrawFunc"] = "ALTUI_PluginDaikin.drawZoneThermostat"   
            arguments_main["newStyleFunc"] = ""   
            arguments_main["newDeviceIconFunc"] = ""   
            arguments_main["newControlPanelFunc"] = ""   
						luup.call_action("urn:upnp-org:serviceId:altui1", "RegisterPlugin", arguments_main, k)  

						local arguments_zone = {}
            arguments_zone["newDeviceType"] = "urn:zoot-com:device:Damper:1"
   					arguments_zone["newScriptFile"] = "J_ALTUI_plugins.js" 
            arguments_zone["newDeviceDrawFunc"] = "ALTUI_PluginDisplays.drawBinaryLight"   
            arguments_zone["newStyleFunc"] = "ALTUI_PluginDisplays.getStyle"
            arguments_zone["newDeviceIconFunc"] = ""   
            arguments_zone["newControlPanelFunc"] = ""   
						luup.call_action("urn:upnp-org:serviceId:altui1", "RegisterPlugin", arguments_zone, k)   

         else
            luup.log("ALTUI plugin is not yet ready, retry in a bit..")
            luup.call_delay("registerWithAltUI", 10, "", false)
         end
         break
      end
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
  local ui7Check = luup.variable_get(SKYFI_SID, "UI7Check", skyfi_device)
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
      if ui7Check == "true" then
	      luup.attr_set("device_json", "D_Damper1_UI7.json", k)
	      debug("Setting damper " .. k .. " with static json file for UI7.")
      end
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
      local etable = d_err[(value or nil)] 
      local err_desc
      local err_cat
      local d_error		
      if (etable and etable) then
        d_error = ("Alarm catagory: " .. d_err_cat[etable.cat] or 'no catagory' .. ". Description:" .. etable.desc .. ".")
        debug(self.description .. ": " .. d_error)
      elseif (value == '0') then
        debug(self.description .. ": " .. "No air conditioning alarms")
      else
        debug(self.description .. ": " .. "Error code not listed, contact your nearest Daikin technical support service.")
      end
      luup.variable_set(SKYFI_SID,  "ErrorData", value, skyfi_device)
      luup.variable_set(SKYFI_SID,  "Error", d_error, skyfi_device)
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
local function get_point(device, new_current_setpoint)
  local current_set_point = luup.variable_get(HVACSET_SID, "CurrentSetpoint", skyfi_device) or ""
  return current_set_point
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
      luup.attr_set('ip', ip_address , skyfi_device)
    else
      return false, "Cannot auto configure, please try entering IP address and port.", "Daikin SKYFi"
    end
  else
    luup.set_failure(false, skyfi_device)
    luup.call_delay("configure", 5, "")
    luup.call_delay("ac_update", 10, "")
    luup.call_delay("registerWithAltUI", 15, "")

  end

  log("SkyFi Plugin Startup SUCCESS: Startup successful.")
  return true, "Startup successful.", "Daikin SkyFi"
end

d_err_cat = {
	["1"] =	"Indoor Unit",
	["2"] =	"Outdoor Unit ",
	["3"] =	"System",
	["3"] =	"Others",
	["4"] =	"stc_daikin",
}

d_err = {
	["17"] =	{error  =  "A0",  cat = "1",  desc = "Indoor Unit External protection devices activated."},
	["18"] =	{error  =  "A1",  cat = "1",  desc = "Indoor unit PCB assembly failure."},
	["19"] =	{error  =  "A2",  cat = "1",  desc = "Interlock error for fan."},
	["20"] =	{error  =  "A3",  cat = "1",  desc = "Drain level system error."},
	["21"] =	{error  =  "A4",  cat = "1",  desc = "Temperature of heat exchanger (1) error."},
	["22"] =	{error  =  "A5",  cat = "1",  desc = "Temperature of heat exchanger (2) error."},
	["23"] =	{error  =  "A6",  cat = "1",  desc = "Fan motor locked, overload, over current."},
	["24"] =	{error  =  "A7",  cat = "1",  desc = "Swing flap motor error."},
	["25"] =	{error  =  "A8",  cat = "1",  desc = "Overcurrent of AC input."},
	["26"] =	{error  =  "A9",  cat = "1",  desc = "Electronic expansion valve drive error."},
	["27"] =	{error  =  "AA",  cat = "1",  desc = "Heater overheat."},
	["28"] =	{error  =  "AH",  cat = "1",  desc = "Dust collector error / No-maintenance filter error."},
	["30"] =	{error  =  "AJ",  cat = "1",  desc = "Capacity setting error (indoor)."},
	["31"] =	{error  =  "AE",  cat = "1",  desc = "Shortage of water supply."},
	["32"] =	{error  =  "AF",  cat = "1",  desc = "Malfunctions of a humidifier system (water leaking)."},
	["33"] =	{error  =  "C0",  cat = "1",  desc = "Malfunctions in a sensor system."},
	["36"] =	{error  =  "C3",  cat = "1",  desc = "Sensor system of drain water error."},
	["37"] =	{error  =  "C4",  cat = "1",  desc = "Heat exchanger (1) (Liquid pipe) thermistor system error."},
	["38"] =	{error  =  "C5",  cat = "1",  desc = "Heat exchanger (1) (Gas pipe) thermistor system error."},
	["39"] =	{error  =  "C6",  cat = "1",  desc = "Sensor system error of fan motor locked, overload."},
	["40"] =	{error  =  "C7",  cat = "1",  desc = "Sensor system of swing flag motor error."},
	["41"] =	{error  =  "C8",  cat = "1",  desc = "Sensor system of over-current of AC input."},
	["42"] =	{error  =  "C9",  cat = "1",  desc = "Suction air thermistor error."},
	["43"] =	{error  =  "CA",  cat = "1",  desc = "Discharge air thermistor system error."},
	["44"] =	{error  =  "CH",  cat = "1",  desc = "Contamination sensor error."},
	["45"] =	{error  =  "CC",  cat = "1",  desc = "Humidity sensor error."},
	["46"] =	{error  =  "CJ",  cat = "1",  desc = "Remote control thermistor error."},
	["47"] =	{error  =  "CE",  cat = "1",  desc = "Radiation sensor error."},
	["48"] =	{error  =  "CF",  cat = "1",  desc = "High pressure switch sensor."},
	["49"] =	{error  =  "E0",  cat = "2",  desc = "Protection devices activated."},
	["50"] =	{error  =  "E1",  cat = "2",  desc = "Outdoor uni9t PCB assembly failure."},
	["52"] =	{error  =  "E3",  cat = "2",  desc = "High pressure switch (HPS) activated."},
	["53"] =	{error  =  "E4",  cat = "2",  desc = "Low pressure switch (LPS) activated."},
	["54"] =	{error  =  "E5",  cat = "2",  desc = "Overload of inverter compressor motor."},
	["55"] =	{error  =  "E6",  cat = "2",  desc = "Over current of STD compressor motor."},
	["56"] =	{error  =  "E7",  cat = "2",  desc = "Overload of fan motor / Over current of fan motor."},
	["57"] =	{error  =  "E8",  cat = "2",  desc = "Over current of AC input."},
	["58"] =	{error  =  "E9",  cat = "2",  desc = "Electronic expansion valve drive error."},
	["59"] =	{error  =  "EA",  cat = "2",  desc = "Four-way valve error."},
	["60"] =	{error  =  "EH",  cat = "2",  desc = "Pump motor over current."},
	["61"] =	{error  =  "EC",  cat = "2",  desc = "Water temperature abnormal."},
	["62"] =	{error  =  "EJ",  cat = "2",  desc = "(Site installed) Protection device activated."},
	["63"] =	{error  =  "EE",  cat = "2",  desc = "Malfunctions in a drain water."},
	["64"] =	{error  =  "EF",  cat = "2",  desc = "Ice thermal storage unit error."},
	["65"] =	{error  =  "H0",  cat = "2",  desc = "Malfunctions in a sensor system."},
	["66"] =	{error  =  "H1",  cat = "2",  desc = "Air temperature thermistor error."},
	["67"] =	{error  =  "H2",  cat = "2",  desc = "Sensor system of power supply error."},
	["68"] =	{error  =  "H3",  cat = "2",  desc = "High Pressure switch is faulty."},
	["69"] =	{error  =  "H4",  cat = "2",  desc = "Low pressure switch is faulty."},
	["70"] =	{error  =  "H5",  cat = "2",  desc = "Compressor motor overload sensor is abnormal."},
	["71"] =	{error  =  "H6",  cat = "2",  desc = "Compressor motor over current sensor is abnormal."},
	["72"] =	{error  =  "H7",  cat = "2",  desc = "Overload or over current sensor of fan motor is abnormal."},
	["73"] =	{error  =  "H8",  cat = "2",  desc = "Sensor system of over-current of AC input."},
	["74"] =	{error  =  "H9",  cat = "2",  desc = "Outdoor air thermistor system error."},
	["75"] =	{error  =  "HA",  cat = "2",  desc = "Discharge air thermistor system error."},
	["76"] =	{error  =  "HH",  cat = "2",  desc = "Pump motor sensor system of over current is abnormal."},
	["77"] =	{error  =  "HC",  cat = "2",  desc = "Water temperature sensor system error."},
	["79"] =	{error  =  "HE",  cat = "2",  desc = "Sensor system of drain water is abnormal."},
	["80"] =	{error  =  "HF",  cat = "2",  desc = "Ice thermal storage unit error (alarm)."},
	["81"] =	{error  =  "F0",  cat = "2",  desc = "No.1 and No.2 common protection device operates."},
	["82"] =	{error  =  "F1",  cat = "2",  desc = "No.1 protection device operates."},
	["83"] =	{error  =  "F2",  cat = "2",  desc = "No.2 protection device operates."},
	["84"] =	{error  =  "F3",  cat = "2",  desc = "Discharge pipe temperature is abnormal."},
	["87"] =	{error  =  "F6",  cat = "2",  desc = "Temperature of heat exchanger(1) abnormal."},
	["91"] =	{error  =  "FA",  cat = "2",  desc = "Discharge pressure abnormal."},
	["92"] =	{error  =  "FH",  cat = "2",  desc = "Oil temperature is abnormally high."},
	["93"] =	{error  =  "FC",  cat = "2",  desc = "Suction pressure abnormal."},
	["95"] =	{error  =  "FE",  cat = "2",  desc = "Oil pressure abnormal."},
	["96"] =	{error  =  "FF",  cat = "2",  desc = "Oil level abnormal."},
	["97"] =	{error  =  "J0",  cat = "2",  desc = "Sensor system error of refrigerant temperature."},
	["98"] =	{error  =  "J1",  cat = "2",  desc = "Pressure sensor error."},
	["99"] =	{error  =  "J2",  cat = "2",  desc = "Current sensor error."},
	["100"] =	{error  =  "J3",  cat = "2",  desc = "Discharge pipe thermistor system error."},
	["101"] =	{error  =  "J4",  cat = "2",  desc = "Low pressure equivalent saturated temperature sensor system error."},
	["102"] =	{error  =  "J5",  cat = "2",  desc = "Suction pipe thermistor system error."},
	["103"] =	{error  =  "J6",  cat = "2",  desc = "Heat exchanger(1) thermistor system error."},
	["104"] =	{error  =  "J7",  cat = "2",  desc = "Heat exchanger(2) thermistor system error."},
	["105"] =	{error  =  "J8",  cat = "2",  desc = "Oil equalizer pipe or liquid pipe thermistor system error."},
	["106"] =	{error  =  "J9",  cat = "2",  desc = "Double tube heat exchanger outlet or gas pipe thermistor system error."},
	["107"] =	{error  =  "JA",  cat = "2",  desc = "Discharge pipe pressure sensor error."},
	["108"] =	{error  =  "JH",  cat = "2",  desc = "Oil temperature sensor error."},
	["109"] =	{error  =  "JC",  cat = "2",  desc = "Suction pipe pressure sensor error."},
	["111"] =	{error  =  "JE",  cat = "2",  desc = "Oil pressure sensor error."},
	["112"] =	{error  =  "JF",  cat = "2",  desc = "Oil level sensor error."},
	["113"] =	{error  =  "L0",  cat = "2",  desc = "Inverter system error."},
	["116"] =	{error  =  "L3",  cat = "2",  desc = "Temperature rise in a switch box."},
	["117"] =	{error  =  "L4",  cat = "2",  desc = "Radiation fin (power transistor) temperature is too high."},
	["118"] =	{error  =  "L5",  cat = "2",  desc = "Compressor motor grounded or short circuit, inverter PCB fault."},
	["119"] =	{error  =  "L6",  cat = "2",  desc = "Compressor motor grounded or short circuit, inverter PCB fault."},
	["120"] =	{error  =  "L7",  cat = "2",  desc = "Over current of all inputs."},
	["121"] =	{error  =  "L8",  cat = "2",  desc = "Compressor over current, compressor motor wire cut."},
	["122"] =	{error  =  "L9",  cat = "2",  desc = "Stall prevention error (start-up error) Compressor locked, etc."},
	["123"] =	{error  =  "LA",  cat = "2",  desc = "Power transistor error."},
	["125"] =	{error  =  "LC",  cat = "2",  desc = "Communication error between inverter and outdoor control unit."},
	["129"] =	{error  =  "P0",  cat = "2",  desc = "Shortage of refrigerant (thermal storage unit)."},
	["130"] =	{error  =  "P1",  cat = "2",  desc = "Power voltage imbalance, open phase."},
	["132"] =	{error  =  "P3",  cat = "2",  desc = "Sensor error of temperature rise in a switch box."},
	["133"] =	{error  =  "P4",  cat = "2",  desc = "Radiation fin temperature sensor error."},
	["134"] =	{error  =  "P5",  cat = "2",  desc = "DC current sensor system error."},
	["135"] =	{error  =  "P6",  cat = "2",  desc = "AC or DC output current sensor system error."},
	["136"] =	{error  =  "P7",  cat = "2",  desc = "Total input current sensor error."},
	["142"] =	{error  =  "PJ",  cat = "2",  desc = "Capacity setting error (outdoor)."},
	["145"] =	{error  =  "U0",  cat = "3",  desc = "Low pressure drop due to insufficient refrigerant or electronic expansion valve error, etc."},
	["146"] =	{error  =  "U1",  cat = "3",  desc = "Reverse phase, Open phase."},
	["147"] =	{error  =  "U2",  cat = "3",  desc = "Power voltage failure / Instantaneous power failure."},
	["148"] =	{error  =  "U3",  cat = "3",  desc = "Failure to carry out check operation, transmission error."},
	["149"] =	{error  =  "U4",  cat = "3",  desc = "Communication error between indoor unit and outdoor unit, communication error between outdoor unit and BS unit."},
	["150"] =	{error  =  "U5",  cat = "3",  desc = "Communication error between remote control and indoor unit / Remote control board failure or setting error for remote control."},
	["151"] =	{error  =  "U6",  cat = "3",  desc = "Communication error between indoor units."},
	["152"] =	{error  =  "U7",  cat = "3",  desc = "Communication error between outdoor units / Communication error between outdoor unit and ice thermal storage unit."},
	["153"] =	{error  =  "U8",  cat = "3",  desc = "Communication error between main and sub remote controllers (sub remote control error) / Combination error of other indoor unit / remote control in the same system (model)."},
	["154"] =	{error  =  "U9",  cat = "3",  desc = "Communication error between other indoor unit and outdoor unit in the same system / Communication error between other BS unit and indoor/outdoor unit."},
	["155"] =	{error  =  "UA",  cat = "3",  desc = "Combination error of indoor/BS/outdoor unit (model, quantity, etc.), setting error of spare parts PCB when replaced."},
	["156"] =	{error  =  "UH",  cat = "3",  desc = "Improper connection of transmission wiring between outdoor and outdoor unit outside control adaptor."},
	["157"] =	{error  =  "UC",  cat = "3",  desc = "Centralized address duplicated."},
	["158"] =	{error  =  "UJ",  cat = "3",  desc = "Attached equipment transmission error."},
	["159"] =	{error  =  "UE",  cat = "3",  desc = "Communication error between indoor unit and centralized control device."},
	["160"] =	{error  =  "UF",  cat = "3",  desc = "Failure to carrey out check operation Indoor-outdoor, outdoor-outdoor communication error, etc."},
	["209"] =	{error  =  "60",  cat = "3",  desc = "All system error."},
	["210"] =	{error  =  "61",  cat = "3",  desc = "PC board error."},
	["211"] =	{error  =  "62",  cat = "3",  desc = "Ozone density abnormal."},
	["212"] =	{error  =  "63",  cat = "3",  desc = "Contamination sensor error."},
	["213"] =	{error  =  "64",  cat = "3",  desc = "Indoor air thermistor system error."},
	["214"] =	{error  =  "65",  cat = "3",  desc = "Outdoor air thermistor system error."},
	["217"] =	{error  =  "68",  cat = "3",  desc = "HVU error (Ventiair dust-collecting unit)."},
	["219"] =	{error  =  "6A",  cat = "3",  desc = "Dumper system error."},
	["220"] =	{error  =  "6H",  cat = "3",  desc = "Door switch error."},
	["221"] =	{error  =  "6C",  cat = "3",  desc = "Replace the humidity element."},
	["222"] =	{error  =  "6J",  cat = "3",  desc = "Replace the high efficiency filter."},
	["223"] =	{error  =  "6E",  cat = "3",  desc = "Replace the deodorization catalyst."},
	["224"] =	{error  =  "6F",  cat = "3",  desc = "Simplified remote controller error."},
	["226"] =	{error  =  "51",  cat = "3",  desc = "Fan motor of supply air over current or overload."},
	["227"] =	{error  =  "52",  cat = "3",  desc = "Fan motor of return air over current / Fan motor of return air overload."},
	["228"] =	{error  =  "53",  cat = "3",  desc = "Inverter system error (supply air side)."},
	["229"] =	{error  =  "54",  cat = "3",  desc = "Inverter system error (return air side)."},
	["241"] =	{error  =  "40",  cat = "3",  desc = "Humidifying valve error."},
	["242"] =	{error  =  "41",  cat = "3",  desc = "Chilled water valve error."},
	["243"] =	{error  =  "42",  cat = "3",  desc = "Hot water valve error."},
	["244"] =	{error  =  "43",  cat = "3",  desc = "Heat exchanger of chilled water error."},
	["245"] =	{error  =  "44",  cat = "3",  desc = "Heat exchanger of hot water error."},
	["258"] =	{error  =  "31",  cat = "3",  desc = "The humidity sensor of return air sensor."},
	["259"] =	{error  =  "32",  cat = "3",  desc = "Outdoor air humidity sensor error."},
	["260"] =	{error  =  "33",  cat = "3",  desc = "Supply air temperature sensor error."},
	["261"] =	{error  =  "34",  cat = "3",  desc = "Return air temperature sensor error."},
	["262"] =	{error  =  "35",  cat = "3",  desc = "Outdoor air temperature sensor error."},
	["263"] =	{error  =  "36",  cat = "3",  desc = "Remote controller temperature sensor error."},
	["267"] =	{error  =  "3A",  cat = "3",  desc = "Water leakage sensor 1 error."},
	["268"] =	{error  =  "3H",  cat = "3",  desc = "Water leakage sensor 2 error."},
	["269"] =	{error  =  "3C",  cat = "3",  desc = "Dew condensation error."},
	["339"] =	{error  =  "M2",  cat = "3",  desc = "Centralized remote controller PCB error."},
	["345"] =	{error  =  "M8",  cat = "3",  desc = "Communication error between centralized remote control devices."},
	["347"] =	{error  =  "MA",  cat = "3",  desc = "Centralized remote control devices inappropriate combination."},
	["349"] =	{error  =  "MC",  cat = "3",  desc = "Centralized remote controller address setting error."},
	["65535"] =	{error  =  "N/A",  cat = "4",  desc = " Comunication error with the A.C."}
}

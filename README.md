# plugin-daikin-skyfi
SkyFi Vera plugin

Plugin for Vera (Currently UI5 only)

Service: -
urn:upnp-org:serviceId:HVAC_UserOperatingMode1
Name: -
SetModeTarget
Parameters (NewModeTarget): -
Off, HeatOn, AutoChangeOver, Dry, CoolOn, Fan.  


service: -
urn:upnp-org:serviceId:HVAC_FanOperatingMode1
Name: -
SetMode
SetModeTarget
Parameters (NewMode): -
ContinuousOn, Auto.

Service: -
urn:upnp-org:serviceId:FanSpeed1
Name: -
SetFanSpeed
SetModeTarget
Parameters (NewFanSpeedTarget): -
1, 2, 3. --Note Selecting 2 does not stick (no Medium) this returns value of 3 (High)

Service: -
urn:upnp-org:serviceId:TemperatureSetpoint1
Name: -
SetCurrentSetpoint
SetModeTarget
Parameters (NewCurrentSetpoint): -
LowerSetPoint? - UpperSetPoint? Limits not tested as yet 

Used for zones only.
Service: -
urn:upnp-org:serviceId:SwitchPower1
Name: -
SetTarget
SetModeTarget
Parameters (newTargetValue): -
0, 1.

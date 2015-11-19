# plugin-daikin-skyfi
SkyFi Vera plugin

Plugin for Vera (Currently UI5 only)

service: urn:upnp-org:serviceId:HVAC_UserOperatingMode1
Name: SetModeTarget

Parameters: Off, HeatOn, AutoChangeOver, Dry, CoolOn, Fan.  


service: urn:upnp-org:serviceId:HVAC_FanOperatingMode1
Name: SetMode

Parameters: ContinuousOn, Auto.


Service: urn:upnp-org:serviceId:FanSpeed1
Name: SetFanSpeed

Parameters : 1, 2, 3. --Note Selecting 2 does not stick (no Medium) this returns value of 3 (High)


Service: urn:upnp-org:serviceId:TemperatureSetpoint1
Name: SetCurrentSetpoint

Parameters : LowerSetPoint? - UpperSetPoint? Limits not tested as yet 


Used for zones only.

Service: urn:upnp-org:serviceId:SwitchPower1
Name: SetTarget

Parameters : 0, 1.


Triggers:-

Thermostat Mode Changes.

Ambient temperature goes above.

Ambient temperature goes above or Below.

Thermostat set temperature goes over.

Thermostat set temperature goes below.

Ambient Temperature goes below.

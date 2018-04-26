# fhem_security


This FHEM modules is an attempt for a JSON based alarm system based on standard notifies and AT devices.
Main features:
- separate armwait, arm and disarm actions
- built-in default state when fhem starts (configuration: on-load)
- built-in action if arming is not possible (configuration: on-fail)
- built-in arm and disarm times (via AT creation), supporting event regex or key-value mapping
- supports name and level ids for arm/disarm commands
- optional, JSON Validator
- optional, gather used devices in a given room
- optinoal, can be configured through DEF instead of a plain JSON file (attr: secNoFile)


Example:
- put myalarm.json and 98_SECURITY.pm to your fhem/FHEM folder.
- put fhem.SECURITY.cfg to your fhem folder.
- execute like: perl fhem.pl fhem.SECURITY.cfg
- use alarmctl to arm/disarm hole system
- use home device to arm/disarm single level
- window level will be armed immediately
- door level will be armed with delay
- door will provide a disarm-period of 15 seconds
- window will alert immediately
- both levels are disarmed on start/initialize and needs the window to be closed while arming
- both levels will disarm at 08:00 if some are present and arm at 22:00

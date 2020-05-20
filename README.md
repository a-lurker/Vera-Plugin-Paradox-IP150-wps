# <img align="left" src="https://a-lurker.github.io/icons/Paradox_TM50_50_50.png"> Vera-Plugin-Paradox-IP150-wps

Monitor you Paradox EVO alarm panel. Use its sensors to trigger scenes.

More information here:
- http://www.paradox.com/Products/default.asp?PID=185
- https://community.getvera.com/t/paradox-ip150-web-page-scraper-plugin/193415

WARNING: do not update to IP150 firmware version 4.0 or later (see below for more detail). Paradox have moved to a subscription model that apparently disables the web page to be scraped by this plugin.

This plugin was tested using an IP module with firmware version: 1.32.01 Later version may or not work, depending on the version. The following firmware versions are all untested:

- May work??       version < 4.x - Local connection
- May NOT work??   4.x <= version < 4.40.004 - SWAN (Paradox cloud) connection.
- May work??       version >= 4.40.004 - Local connection, SWAN (Paradox cloud) connection

This plugin uses a bit library. The latest Vera firmwares have a bit library already installed but openLuup needs one to be installed.

Some versions of http.Lua can result in the plugin being non operational. The log file can indicate this possible outcome.

Before installing the plugin you need to set up these variables in the file 'L_Paradox_IP150_wps1.lua' to suit your alarm before uploading the file to Vera. Make sure to use a text editor, such as Notepad++ or similar:

- m_IP150pw
- m_keyPadCode

WARNING: the codes are unlikely to be secure. Some hacker could potentially get hold of you alarm codes. They will also probably end up on the mios servers.

local targetDirectory = os.getenv("HOME") .. "/Library/Mobile Documents/com~apple~CloudDocs/Dev/scripts/hammerspoon"
package.path = targetDirectory .. "/?.lua;" .. package.path
dofile(targetDirectory .. "/main.lua")

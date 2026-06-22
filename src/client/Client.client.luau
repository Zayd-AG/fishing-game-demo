local ClientModules = script.Parent:WaitForChild("ClientModules")

-- Requiring the controller initializes build mode input, HUD, and client event listeners.
require(ClientModules:WaitForChild("StoreBuilderController"))

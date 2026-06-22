local ServerScriptService = game:GetService("ServerScriptService")

local ServerModules = ServerScriptService:WaitForChild("ServerModules")

-- Requiring these modules initializes them; this keeps the bootstrap script flat and obvious.
require(ServerModules:WaitForChild("PlayerProfileStore"))
require(ServerModules:WaitForChild("FishingEcosystemService"))
require(ServerModules:WaitForChild("CustomerAIService"))

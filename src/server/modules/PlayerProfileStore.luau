local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local ProfileStore = require(ServerScriptService.ServerPackages.ProfileStore)
local DataManager = require(script.Parent.DataManager)
local ProfileTemplate = require(script.Parent.ProfileTemplate)

local PlayerProfileStore = {}

local function storeName(): string
	return if RunService:IsStudio() then "Studio" else "Live"
end

local PlayerStore = ProfileStore.New(storeName(), ProfileTemplate)

local function createLeaderstatsForPlayer(player: Player, coins: number)
	-- Leaderstats are created after the profile loads so the visible value starts from saved data.
	local leaderstatsFolder = Instance.new("Folder")
	leaderstatsFolder.Name = "leaderstats"
	leaderstatsFolder.Parent = player

	local coinsValue = Instance.new("IntValue")
	coinsValue.Name = "Coins"
	coinsValue.Value = coins
	coinsValue.Parent = leaderstatsFolder
end

local function PlayerAdded(player: Player)
	-- Start one ProfileStore session for this player's saved data.
	if DataManager.Profiles[player] ~= nil then
		return
	end

	local profile = PlayerStore:StartSessionAsync(`{player.UserId}`, {
		Cancel = function()
			return player.Parent ~= Players
		end,
	})

	if profile ~= nil then
		profile:AddUserId(player.UserId)
		profile:Reconcile()

		profile.OnSessionEnd:Connect(function()
			DataManager.Profiles[player] = nil
			player:Kick("Profile session end - Please rejoin")
		end)

		if player.Parent == Players then
			DataManager.Profiles[player] = profile
			createLeaderstatsForPlayer(player, profile.Data.Coins)
			DataManager.SyncPlayer(player)
			print(`Profile loaded for {player.DisplayName}!`)
		else
			-- The player left before the profile session started, so we release the lock immediately.
			profile:EndSession()
		end
	else
		-- This should only happen when the Roblox server is shutting down or the load was cancelled.
		player:Kick("Profile load fail - Please rejoin")
	end
end

for _, player in Players:GetPlayers() do
	-- Existing players are handled because Studio can create the test player before this module is required.
	task.spawn(PlayerAdded, player)
end

Players.PlayerAdded:Connect(PlayerAdded)

Players.PlayerRemoving:Connect(function(player: Player)
	local profile = DataManager.Profiles[player]

	if not profile then
		return
	end

	profile:EndSession()
	DataManager.Profiles[player] = nil
end)

return PlayerProfileStore

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local ProfileStore = require(ServerScriptService.ServerPackages.ProfileStore)
local DataManager = require(script.Parent.DataManager)
local ProfileTemplate = require(script.Parent.ProfileTemplate)

local PlayerProfileStore = {}

local ProfileStoreName = if RunService:IsStudio() then "Studio" else "Live"
local PlayerStore = ProfileStore.New(ProfileStoreName, ProfileTemplate)
local Profiles = DataManager.Profiles
local LoadingProfiles: { [Player]: boolean } = {}

local function createLeaderstatsForPlayer(player: Player): IntValue
	-- Leaderstats are created once the profile is safe so visible coins always mirror saved data.
	local leaderstatsFolder = player:FindFirstChild("leaderstats")

	if not leaderstatsFolder then
		leaderstatsFolder = Instance.new("Folder")
		leaderstatsFolder.Name = "leaderstats"
		leaderstatsFolder.Parent = player
	end

	local coinsValue = leaderstatsFolder:FindFirstChild("Coins")

	if coinsValue and coinsValue:IsA("IntValue") then
		return coinsValue
	end

	local newCoinsValue = Instance.new("IntValue")
	newCoinsValue.Name = "Coins"
	newCoinsValue.Value = 0
	newCoinsValue.Parent = leaderstatsFolder

	return newCoinsValue
end

local function PlayerAdded(player: Player)
	-- Start one ProfileStore session for this player's saved data.
	if Profiles[player] ~= nil or LoadingProfiles[player] then
		return
	end

	LoadingProfiles[player] = true

	local profile = PlayerStore:StartSessionAsync(`{player.UserId}`, {
		Cancel = function()
			return player.Parent ~= Players
		end,
	})

	if profile ~= nil then
		profile:AddUserId(player.UserId)
		profile:Reconcile()

		profile.OnSessionEnd:Connect(function()
			Profiles[player] = nil
			LoadingProfiles[player] = nil
			DataManager.RemoveProfileForPlayer(player)
			player:Kick("Profile session end - Please rejoin")
		end)

		if player.Parent == Players then
			createLeaderstatsForPlayer(player)
			LoadingProfiles[player] = nil
			DataManager.SetProfileForPlayer(player, profile)
			print(`Profile loaded for {player.DisplayName}!`)
		else
			-- The player left before the profile session started, so we release the lock immediately.
			LoadingProfiles[player] = nil
			profile:EndSession()
		end
	else
		-- This should only happen when the Roblox server is shutting down or the load was cancelled.
		LoadingProfiles[player] = nil
		player:Kick("Profile load fail - Please rejoin")
	end
end

for _, player in Players:GetPlayers() do
	-- Existing players are handled because Studio can create the test player before this module is required.
	task.spawn(PlayerAdded, player)
end

Players.PlayerAdded:Connect(PlayerAdded)

task.spawn(function()
	-- Studio sometimes creates the test player during script startup; this scan catches that without a Start method.
	for _ = 1, 15 do
		for _, player in Players:GetPlayers() do
			if Profiles[player] == nil and not LoadingProfiles[player] then
				task.spawn(PlayerAdded, player)
			end
		end

		task.wait(1)
	end
end)

Players.PlayerRemoving:Connect(function(player: Player)
	local profile = Profiles[player]
	LoadingProfiles[player] = nil

	if profile ~= nil then
		profile:EndSession()
	end
end)

return PlayerProfileStore

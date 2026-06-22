local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local ProfileStore = require(ServerScriptService.ServerPackages.ProfileStore)
local DataManager = require(script.Parent.DataManager)
local ProfileTemplate = require(script.Parent.ProfileTemplate)

local PlayerProfileStore = {}

local ProfileStoreName = if RunService:IsStudio() then "Studio" else "Live"
local PlayerDataProfileStore = ProfileStore.New(ProfileStoreName, ProfileTemplate)
local ActiveSessionProfilesByPlayer: { [Player]: any } = {}

local function createLeaderstatsForPlayer(player: Player): IntValue
	-- Leaderstats are created before the profile loads so the player always sees a stable Coins counter.
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

local function getProfileKeyForPlayer(player: Player): string
	-- Prefixing the user id makes saved keys easy to inspect while debugging DataStore data.
	return `Player_{player.UserId}`
end

local function shouldCancelSessionStart(player: Player): boolean
	-- ProfileStore asks this while waiting on session locks; true means this player no longer needs a profile.
	return player.Parent ~= Players or ProfileStore.IsClosing
end

local function startProfileSessionForPlayer(player: Player)
	-- This follows the standard ProfileStore pattern: keep trying until a profile loads or the player leaves.
	createLeaderstatsForPlayer(player)

	local profile = nil

	while player.Parent == Players and not ProfileStore.IsClosing and not profile do
		profile = PlayerDataProfileStore:StartSessionAsync(getProfileKeyForPlayer(player), {
			Cancel = function()
				return shouldCancelSessionStart(player)
			end,
		})

		if not profile then
			-- A nil profile usually means a temporary session conflict, so we wait and try again.
			task.wait(1)
		end
	end

	if not profile then
		return
	end

	profile:AddUserId(player.UserId)
	profile:Reconcile()

	profile.OnSessionEnd:Connect(function()
		-- Once the session ends, this server must stop touching the profile immediately.
		ActiveSessionProfilesByPlayer[player] = nil
		DataManager.RemoveProfileForPlayer(player)

		if player.Parent == Players then
			player:Kick("Your save data session ended. Please rejoin to keep your progress safe.")
		end
	end)

	if player.Parent ~= Players then
		profile:EndSession()
		return
	end

	ActiveSessionProfilesByPlayer[player] = profile
	DataManager.SetProfileForPlayer(player, profile)
end

local function endProfileSessionForPlayer(player: Player)
	-- Ending the ProfileStore session saves one final time and releases the session lock.
	local profile = ActiveSessionProfilesByPlayer[player]

	if not profile then
		return
	end

	ActiveSessionProfilesByPlayer[player] = nil
	DataManager.RemoveProfileForPlayer(player)
	profile:EndSession()
end

local function handlePlayerAdded(player: Player)
	-- Loading in a task keeps PlayerAdded from blocking while DataStore work yields.
	task.spawn(startProfileSessionForPlayer, player)
end

local function initializePlayerProfileStore()
	-- Existing players are handled first because Studio can create the test player before this module is required.
	for _, player in Players:GetPlayers() do
		handlePlayerAdded(player)
	end

	Players.PlayerAdded:Connect(handlePlayerAdded)
	Players.PlayerRemoving:Connect(endProfileSessionForPlayer)
end

initializePlayerProfileStore()

return PlayerProfileStore

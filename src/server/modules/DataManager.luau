export type SavedVector3 = {
	X: number,
	Y: number,
	Z: number,
}

export type SavedPlacedStoreItem = {
	ItemName: string,
	Position: SavedVector3,
	RotationYDegrees: number,
}

export type PlayerData = {
	Coins: number,
	NetLevel: number,
	LuckUpgradeLevel: number,
	StoreLevel: number,
	StoreWidthInCells: number,
	StoreDepthInCells: number,
	MessCount: number,
	CoinsWaitingToCollect: number,
	PlacedStoreItems: { SavedPlacedStoreItem },
}

export type LoadedProfile = {
	Data: PlayerData,
	EndSession: (LoadedProfile) -> (),
}

local Players = game:GetService("Players")

local DataManager = {}

local ActiveProfilesByPlayer: { [Player]: LoadedProfile } = {}
local ProfileLoadedBindable = Instance.new("BindableEvent")
local ProfileReleasedBindable = Instance.new("BindableEvent")
local HasRequestedPlayerProfileStore = false

DataManager.ProfileLoaded = ProfileLoadedBindable.Event
DataManager.ProfileReleased = ProfileReleasedBindable.Event

local function getProfileForPlayer(player: Player): LoadedProfile?
	-- Every data function goes through this lookup so unloaded players never mutate a missing profile.
	return ActiveProfilesByPlayer[player]
end

local function getDataForPlayer(player: Player): PlayerData?
	-- Returning nil instead of erroring lets gameplay ignore requests from players whose data is still loading.
	local profile = getProfileForPlayer(player)

	if not profile then
		return nil
	end

	return profile.Data
end

local function updateLeaderstatsCoins(player: Player, coins: number)
	-- Leaderstats mirrors saved data so the visible counter always matches the profile.
	local leaderstatsFolder = player:FindFirstChild("leaderstats")

	if not leaderstatsFolder then
		return
	end

	local coinsValue = leaderstatsFolder:FindFirstChild("Coins")

	if coinsValue and coinsValue:IsA("IntValue") then
		coinsValue.Value = coins
	end
end

local function ensurePlayerProfileStoreHasBeenRequired()
	-- If Studio startup order is awkward, the first data wait still pulls in the profile loader module.
	if HasRequestedPlayerProfileStore then
		return
	end

	HasRequestedPlayerProfileStore = true

	task.defer(function()
		require(script.Parent.PlayerProfileStore)
	end)
end

function DataManager.SetProfileForPlayer(player: Player, profile: LoadedProfile)
	-- PlayerProfileStore calls this only after AddUserId and Reconcile have made the data safe to use.
	ActiveProfilesByPlayer[player] = profile
	updateLeaderstatsCoins(player, profile.Data.Coins)
	ProfileLoadedBindable:Fire(player, profile.Data)
end

function DataManager.RemoveProfileForPlayer(player: Player)
	-- Removing the profile blocks late remotes from changing data after the session has ended.
	ActiveProfilesByPlayer[player] = nil
	ProfileReleasedBindable:Fire(player)
end

function DataManager.WaitForProfile(player: Player, timeoutSeconds: number?): boolean
	-- A short wait lets startup code handle normal load timing without hanging forever.
	if getProfileForPlayer(player) then
		return true
	end

	ensurePlayerProfileStoreHasBeenRequired()

	local startedWaitingAt = os.clock()
	local maximumWaitSeconds = timeoutSeconds or 10

	while player.Parent == Players and not getProfileForPlayer(player) do
		if os.clock() - startedWaitingAt > maximumWaitSeconds then
			return false
		end

		task.wait()
	end

	return getProfileForPlayer(player) ~= nil
end

function DataManager.GetCoins(player: Player): number
	local data = getDataForPlayer(player)

	return if data then data.Coins else 0
end

function DataManager.AddCoins(player: Player, coinsToAdd: number): number
	-- The server owns coin changes, and math.max prevents accidental negative rewards.
	local data = getDataForPlayer(player)

	if not data then
		return 0
	end

	data.Coins += math.max(0, coinsToAdd)
	updateLeaderstatsCoins(player, data.Coins)

	return data.Coins
end

function DataManager.GetNetLevel(player: Player): number
	local data = getDataForPlayer(player)

	return if data then data.NetLevel else 1
end

function DataManager.GetLuckUpgradeLevel(player: Player): number
	local data = getDataForPlayer(player)

	return if data then data.LuckUpgradeLevel else 0
end

function DataManager.GetStoreStatus(player: Player): PlayerData?
	return getDataForPlayer(player)
end

function DataManager.AddCoinsWaitingToCollect(player: Player, coinsToAdd: number): number
	local data = getDataForPlayer(player)

	if not data then
		return 0
	end

	data.CoinsWaitingToCollect += math.max(0, coinsToAdd)

	return data.CoinsWaitingToCollect
end

function DataManager.AddMess(player: Player): number
	local data = getDataForPlayer(player)

	if not data then
		return 0
	end

	data.MessCount += 1

	return data.MessCount
end

function DataManager.CleanOneMess(player: Player): number
	local data = getDataForPlayer(player)

	if not data then
		return 0
	end

	data.MessCount = math.max(0, data.MessCount - 1)

	return data.MessCount
end

function DataManager.UpgradeStoreSpace(player: Player): (number, number)
	local data = getDataForPlayer(player)

	if not data then
		return 8, 8
	end

	data.StoreLevel += 1
	data.StoreWidthInCells = 8 + ((data.StoreLevel - 1) * 2)
	data.StoreDepthInCells = 8 + ((data.StoreLevel - 1) * 2)

	return data.StoreWidthInCells, data.StoreDepthInCells
end

function DataManager.AddPlacedStoreItem(player: Player, itemName: string, itemWorldCFrame: CFrame): SavedPlacedStoreItem?
	-- CFrame is converted into plain numbers because DataStores cannot save Roblox datatypes safely.
	local data = getDataForPlayer(player)

	if not data then
		return nil
	end

	local _, rotationYRadians = itemWorldCFrame:ToEulerAnglesYXZ()
	local savedPlacedStoreItem: SavedPlacedStoreItem = {
		ItemName = itemName,
		Position = {
			X = itemWorldCFrame.Position.X,
			Y = itemWorldCFrame.Position.Y,
			Z = itemWorldCFrame.Position.Z,
		},
		RotationYDegrees = math.deg(rotationYRadians),
	}

	table.insert(data.PlacedStoreItems, savedPlacedStoreItem)

	return savedPlacedStoreItem
end

function DataManager.GetPlacedStoreItems(player: Player): { SavedPlacedStoreItem }
	local data = getDataForPlayer(player)

	if not data then
		return {}
	end

	return data.PlacedStoreItems
end

return DataManager

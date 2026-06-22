export type FishLootEntry = {
	Name: string,
	RarityName: string,
	RarityRank: number,
	BaseWeight: number,
	SellValue: number,
}

export type PlayerFishingProgress = {
	NetLevel: number,
	LuckUpgradeLevel: number,
	Coins: number,
}

export type CastNetResult = {
	FishCaught: { FishLootEntry },
	RarestFishCaught: FishLootEntry?,
	TotalSellValue: number,
}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FishingEcosystemService = {}

local RemoteFolderName = "GameRemotes"
local CastNetRequestRemoteName = "CastNetRequested"
local FishCaughtRemoteName = "FishCaught"
local ShipMovementRequestRemoteName = "ShipMovementRequested"

local MaximumAllowedShipMoveDistance = 18
local BaseFishPerNetCast = 1
local ShipPromptPartName = "ShipCastNetPromptPart"

local FishLootTable: { FishLootEntry } = {
	{
		Name = "Tiny Sardine",
		RarityName = "Common",
		RarityRank = 1,
		BaseWeight = 70,
		SellValue = 3,
	},
	{
		Name = "Blue Mackerel",
		RarityName = "Uncommon",
		RarityRank = 2,
		BaseWeight = 24,
		SellValue = 9,
	},
	{
		Name = "Golden Tuna",
		RarityName = "Rare",
		RarityRank = 3,
		BaseWeight = 5,
		SellValue = 35,
	},
	{
		Name = "Ancient Moonfish",
		RarityName = "Legendary",
		RarityRank = 4,
		BaseWeight = 1,
		SellValue = 180,
	},
}

local PlayerFishingProgressByUserId: { [number]: PlayerFishingProgress } = {}
local LastAcceptedShipCFrameByUserId: { [number]: CFrame } = {}

local function getOrCreateRemoteFolder(): Folder
	-- We create remotes from the server so every client sees one consistent networking surface.
	local existingRemoteFolder = ReplicatedStorage:FindFirstChild(RemoteFolderName)

	if existingRemoteFolder and existingRemoteFolder:IsA("Folder") then
		return existingRemoteFolder
	end

	local newRemoteFolder = Instance.new("Folder")
	newRemoteFolder.Name = RemoteFolderName
	newRemoteFolder.Parent = ReplicatedStorage

	return newRemoteFolder
end

local function getOrCreateRemoteEvent(remoteEventName: string): RemoteEvent
	-- A tiny helper keeps the file flat while avoiding repeated Instance creation code.
	local remoteFolder = getOrCreateRemoteFolder()
	local existingRemoteEvent = remoteFolder:FindFirstChild(remoteEventName)

	if existingRemoteEvent and existingRemoteEvent:IsA("RemoteEvent") then
		return existingRemoteEvent
	end

	local newRemoteEvent = Instance.new("RemoteEvent")
	newRemoteEvent.Name = remoteEventName
	newRemoteEvent.Parent = remoteFolder

	return newRemoteEvent
end

local CastNetRequestedRemote = getOrCreateRemoteEvent(CastNetRequestRemoteName)
local FishCaughtRemote = getOrCreateRemoteEvent(FishCaughtRemoteName)
local ShipMovementRequestedRemote = getOrCreateRemoteEvent(ShipMovementRequestRemoteName)

local function getFishingProgressForPlayer(player: Player): PlayerFishingProgress
	-- The prototype stores progress in memory so the gameplay loop is readable before persistence is added.
	local existingProgress = PlayerFishingProgressByUserId[player.UserId]

	if existingProgress then
		return existingProgress
	end

	local newProgress: PlayerFishingProgress = {
		NetLevel = 1,
		LuckUpgradeLevel = 0,
		Coins = 0,
	}

	PlayerFishingProgressByUserId[player.UserId] = newProgress

	return newProgress
end

local function getOrCreateLeaderstatsCoins(player: Player): IntValue
	-- Leaderstats make the prototype reward loop visible without adding a custom economy UI yet.
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
	newCoinsValue.Parent = leaderstatsFolder

	return newCoinsValue
end

local function calculateLuckMultiplier(playerFishingProgress: PlayerFishingProgress): number
	-- Each luck upgrade gives rare fish more weight without making common fish disappear.
	return 1 + (playerFishingProgress.LuckUpgradeLevel * 0.15)
end

local function calculateFishCountForNetCast(playerFishingProgress: PlayerFishingProgress): number
	-- Better nets catch more fish, which makes upgrades feel valuable even when rarity rolls are unlucky.
	return BaseFishPerNetCast + math.floor(playerFishingProgress.NetLevel / 2)
end

local function calculateAdjustedFishWeight(fishLootEntry: FishLootEntry, luckMultiplier: number): number
	-- Higher rarity ranks receive more of the luck multiplier so upgrades mostly help exciting catches.
	local rarityBonusMultiplier = 1 + ((fishLootEntry.RarityRank - 1) * (luckMultiplier - 1))

	return fishLootEntry.BaseWeight * rarityBonusMultiplier
end

local function rollOneFishFromLootTable(playerFishingProgress: PlayerFishingProgress): FishLootEntry
	-- Weighted random is done in two passes: first total the ticket count, then find the winning ticket.
	local luckMultiplier = calculateLuckMultiplier(playerFishingProgress)
	local totalAdjustedWeight = 0

	for _, fishLootEntry in FishLootTable do
		totalAdjustedWeight += calculateAdjustedFishWeight(fishLootEntry, luckMultiplier)
	end

	-- Multiplying math.random() by the total creates a number somewhere inside the ticket range.
	local winningTicket = math.random() * totalAdjustedWeight
	local runningWeight = 0

	for _, fishLootEntry in FishLootTable do
		runningWeight += calculateAdjustedFishWeight(fishLootEntry, luckMultiplier)

		if winningTicket <= runningWeight then
			return fishLootEntry
		end
	end

	-- This fallback only protects against floating point edge cases at the end of the weight range.
	return FishLootTable[#FishLootTable]
end

local function findRarestFishCaught(fishCaught: { FishLootEntry }): FishLootEntry?
	-- The client only needs one highlight fish, so the server chooses the highest rarity from the result.
	local rarestFishCaught: FishLootEntry? = nil

	for _, fishLootEntry in fishCaught do
		if not rarestFishCaught or fishLootEntry.RarityRank > rarestFishCaught.RarityRank then
			rarestFishCaught = fishLootEntry
		end
	end

	return rarestFishCaught
end

local function castNetForPlayer(player: Player): CastNetResult
	-- All reward math lives on the server so clients cannot fake rare catches or coin payouts.
	local playerFishingProgress = getFishingProgressForPlayer(player)
	local fishCaught: { FishLootEntry } = {}
	local totalSellValue = 0

	for _ = 1, calculateFishCountForNetCast(playerFishingProgress) do
		local rolledFish = rollOneFishFromLootTable(playerFishingProgress)

		table.insert(fishCaught, rolledFish)
		totalSellValue += rolledFish.SellValue
	end

	playerFishingProgress.Coins += totalSellValue
	getOrCreateLeaderstatsCoins(player).Value = playerFishingProgress.Coins

	return {
		FishCaught = fishCaught,
		RarestFishCaught = findRarestFishCaught(fishCaught),
		TotalSellValue = totalSellValue,
	}
end

local function isRequestedShipMoveReasonable(player: Player, requestedShipCFrame: CFrame): boolean
	-- Distance checks make the ship responsive while rejecting huge teleports from exploited clients.
	local lastAcceptedShipCFrame = LastAcceptedShipCFrameByUserId[player.UserId]

	if not lastAcceptedShipCFrame then
		LastAcceptedShipCFrameByUserId[player.UserId] = requestedShipCFrame
		return true
	end

	-- Subtracting positions gives the movement vector; Magnitude is the actual studs moved.
	local requestedMoveDistance = (requestedShipCFrame.Position - lastAcceptedShipCFrame.Position).Magnitude

	if requestedMoveDistance > MaximumAllowedShipMoveDistance then
		return false
	end

	LastAcceptedShipCFrameByUserId[player.UserId] = requestedShipCFrame

	return true
end

local function handleCastNetRequested(player: Player)
	-- One remote call performs one complete server-authoritative fishing roll.
	local castNetResult = castNetForPlayer(player)

	FishCaughtRemote:FireClient(player, castNetResult)
end

local function connectShipCastNetPrompt()
	-- A Studio-built ship can expose a normal ProximityPrompt, which makes fishing discoverable in-world.
	local shipPromptPart = workspace:FindFirstChild(ShipPromptPartName, true)

	if not shipPromptPart or not shipPromptPart:IsA("BasePart") then
		return
	end

	local castNetPrompt = shipPromptPart:FindFirstChildOfClass("ProximityPrompt")

	if not castNetPrompt then
		return
	end

	castNetPrompt.Triggered:Connect(handleCastNetRequested)
end

local function handleShipMovementRequested(player: Player, requestedShipCFrame: CFrame)
	-- The prototype trusts Studio placeholder ships by name, but still validates movement size.
	if typeof(requestedShipCFrame) ~= "CFrame" then
		return
	end

	if not isRequestedShipMoveReasonable(player, requestedShipCFrame) then
		return
	end

	local playerShipName = `{player.Name}_Ship`
	local playerShip = workspace:FindFirstChild(playerShipName)

	if playerShip and playerShip:IsA("Model") then
		playerShip:PivotTo(requestedShipCFrame)
	end
end

local function handlePlayerRemoving(player: Player)
	-- Clearing memory prevents test sessions from keeping stale prototype data forever.
	PlayerFishingProgressByUserId[player.UserId] = nil
	LastAcceptedShipCFrameByUserId[player.UserId] = nil
end

function FishingEcosystemService.Start()
	-- Start wires remotes once; the service stays simple because each handler is small and named.
	CastNetRequestedRemote.OnServerEvent:Connect(handleCastNetRequested)
	ShipMovementRequestedRemote.OnServerEvent:Connect(handleShipMovementRequested)
	Players.PlayerAdded:Connect(function(player)
		-- Creating the visible counter on join helps testers immediately see fishing rewards.
		getOrCreateLeaderstatsCoins(player)
	end)
	Players.PlayerRemoving:Connect(handlePlayerRemoving)
	connectShipCastNetPrompt()
end

return FishingEcosystemService

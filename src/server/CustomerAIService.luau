export type CustomerStateName =
	"Spawning"
	| "WalkingToStore"
	| "Browsing"
	| "Buying"
	| "Leaving"
	| "Despawning"

export type StoreManagementData = {
	StoreLevel: number,
	StoreWidthInCells: number,
	StoreDepthInCells: number,
	MessCount: number,
	CoinsWaitingToCollect: number,
}

export type CustomerState = {
	Model: Model,
	StateName: CustomerStateName,
	StateStartedAt: number,
	TargetPosition: Vector3,
}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CustomerAIService = {}

local RemoteFolderName = "GameRemotes"
local PlaceStoreItemRequestRemoteName = "PlaceStoreItemRequested"
local StoreStatusChangedRemoteName = "StoreStatusChanged"
local PlacementCollisionFolderName = "PlacedStoreItems"

local GridCellSize = 4
local StoreBoundsPartName = "StorePlacementBounds"
local CustomerSpawnIntervalSeconds = 6
local CustomerWalkSpeedStudsPerSecond = 8
local BrowseDurationSeconds = 5
local DespawnDistanceStuds = 60
local MessChanceAfterCustomerLeaves = 0.25

local ActiveCustomerStates: { CustomerState } = {}
local StoreManagementDataByUserId: { [number]: StoreManagementData } = {}
local SecondsSinceLastCustomerSpawn = CustomerSpawnIntervalSeconds

local function getOrCreateRemoteFolder(): Folder
	-- All prototype remotes share one folder so networking stays easy to inspect in ReplicatedStorage.
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
	-- Creating remotes in code keeps Rojo script sync simple while still giving Studio a visible folder.
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

local PlaceStoreItemRequestedRemote = getOrCreateRemoteEvent(PlaceStoreItemRequestRemoteName)
local StoreStatusChangedRemote = getOrCreateRemoteEvent(StoreStatusChangedRemoteName)

local function getStoreDataForPlayer(player: Player): StoreManagementData
	-- Store data is intentionally small so the tycoon loop can be understood in one file.
	local existingStoreData = StoreManagementDataByUserId[player.UserId]

	if existingStoreData then
		return existingStoreData
	end

	local newStoreData: StoreManagementData = {
		StoreLevel = 1,
		StoreWidthInCells = 8,
		StoreDepthInCells = 8,
		MessCount = 0,
		CoinsWaitingToCollect = 0,
	}

	StoreManagementDataByUserId[player.UserId] = newStoreData

	return newStoreData
end

local function sendStoreStatusToPlayer(player: Player)
	-- The client gets one small data packet whenever the store changes so the UI stays honest.
	StoreStatusChangedRemote:FireClient(player, getStoreDataForPlayer(player))
end

local function calculateStoreSizeForLevel(storeLevel: number): (number, number)
	-- Each level adds two cells in both directions so upgrades expand the buildable footprint predictably.
	local storeWidthInCells = 8 + ((storeLevel - 1) * 2)
	local storeDepthInCells = 8 + ((storeLevel - 1) * 2)

	return storeWidthInCells, storeDepthInCells
end

local function upgradeStoreSpaceForPlayer(player: Player)
	-- Upgrading only changes data here; the client builder reads bounds from Studio placeholder parts.
	local storeData = getStoreDataForPlayer(player)

	storeData.StoreLevel += 1

	local storeWidthInCells, storeDepthInCells = calculateStoreSizeForLevel(storeData.StoreLevel)

	storeData.StoreWidthInCells = storeWidthInCells
	storeData.StoreDepthInCells = storeDepthInCells
end

local function addMessToStore(player: Player)
	-- Mess is a simple counter first, and later can become real spill/trash parts placed in Studio.
	local storeData = getStoreDataForPlayer(player)

	storeData.MessCount += 1
	sendStoreStatusToPlayer(player)
end

local function cleanOneMessFromStore(player: Player)
	-- Clamping at zero keeps cleanup buttons from accidentally creating negative mess.
	local storeData = getStoreDataForPlayer(player)

	storeData.MessCount = math.max(0, storeData.MessCount - 1)
	sendStoreStatusToPlayer(player)
end

local function createPlaceholderCustomerModel(customerSpawnPosition: Vector3): Model
	-- The placeholder is built from obvious body parts so it reads as a customer before final Blender rigs exist.
	local customerModel = Instance.new("Model")
	customerModel.Name = "PrototypeCustomer"

	local bodyPart = Instance.new("Part")
	bodyPart.Name = "Body"
	bodyPart.Anchored = true
	bodyPart.Size = Vector3.new(2, 4, 2)
	bodyPart.Position = customerSpawnPosition
	bodyPart.Color = Color3.fromRGB(70, 120, 255)
	bodyPart.Parent = customerModel

	local headPart = Instance.new("Part")
	headPart.Name = "Head"
	headPart.Anchored = true
	headPart.Shape = Enum.PartType.Ball
	headPart.Size = Vector3.new(1.5, 1.5, 1.5)
	headPart.Position = customerSpawnPosition + Vector3.new(0, 2.75, 0)
	headPart.Color = Color3.fromRGB(255, 220, 170)
	headPart.Parent = customerModel

	local stateBillboard = Instance.new("BillboardGui")
	stateBillboard.Name = "StateBillboard"
	stateBillboard.Size = UDim2.fromOffset(180, 40)
	stateBillboard.StudsOffset = Vector3.new(0, 4, 0)
	stateBillboard.AlwaysOnTop = true
	stateBillboard.Parent = headPart

	local stateLabel = Instance.new("TextLabel")
	stateLabel.Name = "StateLabel"
	stateLabel.BackgroundTransparency = 0.25
	stateLabel.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	stateLabel.Size = UDim2.fromScale(1, 1)
	stateLabel.Font = Enum.Font.GothamBold
	stateLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	stateLabel.TextScaled = true
	stateLabel.Text = "Spawning"
	stateLabel.Parent = stateBillboard

	customerModel.PrimaryPart = bodyPart
	customerModel.Parent = workspace

	return customerModel
end

local function updateCustomerStateBillboard(customerState: CustomerState)
	-- The label makes the state machine visible while we tune the customer loop.
	local headPart = customerState.Model:FindFirstChild("Head")

	if not headPart then
		return
	end

	local stateBillboard = headPart:FindFirstChild("StateBillboard")

	if not stateBillboard then
		return
	end

	local stateLabel = stateBillboard:FindFirstChild("StateLabel")

	if stateLabel and stateLabel:IsA("TextLabel") then
		stateLabel.Text = customerState.StateName
	end
end

local function setCustomerState(customerState: CustomerState, nextStateName: CustomerStateName, targetPosition: Vector3?)
	-- Every state transition refreshes the timer so each state can use simple elapsed-time checks.
	customerState.StateName = nextStateName
	customerState.StateStartedAt = os.clock()

	if targetPosition then
		customerState.TargetPosition = targetPosition
	end

	updateCustomerStateBillboard(customerState)
end

local function getStoreEntrancePosition(): Vector3
	-- A Studio part named StoreEntrance can override this once the map is built.
	local storeEntrance = workspace:FindFirstChild("StoreEntrance")

	if storeEntrance and storeEntrance:IsA("BasePart") then
		return storeEntrance.Position
	end

	return Vector3.new(0, 2, -20)
end

local function getBrowsingSpotPosition(): Vector3
	-- A browsing point keeps customers moving into the shop instead of stopping at the door.
	local browsingSpot = workspace:FindFirstChild("BrowsingSpot")

	if browsingSpot and browsingSpot:IsA("BasePart") then
		return browsingSpot.Position
	end

	return Vector3.new(0, 2, 28)
end

local function getCheckoutPosition(): Vector3
	-- The checkout point gives the buying state a real destination near the counter.
	local checkoutSpot = workspace:FindFirstChild("CheckoutSpot")

	if checkoutSpot and checkoutSpot:IsA("BasePart") then
		return checkoutSpot.Position
	end

	return Vector3.new(-10, 2, 18)
end

local function getCustomerSpawnPosition(): Vector3
	-- A Studio part named CustomerSpawn can override this placeholder spawn point.
	local customerSpawn = workspace:FindFirstChild("CustomerSpawn")

	if customerSpawn and customerSpawn:IsA("BasePart") then
		return customerSpawn.Position
	end

	return Vector3.new(0, 2, -60)
end

local function getCustomerExitPosition(): Vector3
	-- The exit sits behind the spawn so customers visibly leave the store area.
	return getCustomerSpawnPosition() + Vector3.new(0, 0, -DespawnDistanceStuds)
end

local function moveCustomerTowardTarget(customerState: CustomerState, deltaTime: number): boolean
	-- We move by distance-per-frame so customer speed stays stable at different frame rates.
	local customerModel = customerState.Model
	local primaryPart = customerModel.PrimaryPart

	if not primaryPart then
		return true
	end

	local currentPosition = primaryPart.Position
	local targetPosition = customerState.TargetPosition
	local vectorToTarget = targetPosition - currentPosition
	local distanceToTarget = vectorToTarget.Magnitude
	local distanceThisFrame = CustomerWalkSpeedStudsPerSecond * deltaTime

	if distanceToTarget <= distanceThisFrame then
		customerModel:PivotTo(CFrame.new(targetPosition))
		return true
	end

	-- Unit gives direction only; multiplying by frame distance gives the exact step to take.
	local nextPosition = currentPosition + (vectorToTarget.Unit * distanceThisFrame)

	customerModel:PivotTo(CFrame.new(nextPosition, targetPosition))

	return false
end

local function chooseCustomerOwner(): Player?
	-- Phase one assigns customers to any online player so the loop runs in solo and multiplayer tests.
	local onlinePlayers = Players:GetPlayers()

	if #onlinePlayers == 0 then
		return nil
	end

	return onlinePlayers[math.random(1, #onlinePlayers)]
end

local function spawnCustomer()
	-- Spawning creates one state table that carries the whole customer lifecycle.
	local customerSpawnPosition = getCustomerSpawnPosition()
	local customerModel = createPlaceholderCustomerModel(customerSpawnPosition)
	local customerState: CustomerState = {
		Model = customerModel,
		StateName = "Spawning",
		StateStartedAt = os.clock(),
		TargetPosition = getStoreEntrancePosition(),
	}

	table.insert(ActiveCustomerStates, customerState)
	setCustomerState(customerState, "WalkingToStore", getStoreEntrancePosition())
end

local function updateWalkingToStoreState(customerState: CustomerState, deltaTime: number)
	-- Reaching the entrance means the customer can start browsing tanks and shelves.
	local reachedStore = moveCustomerTowardTarget(customerState, deltaTime)

	if reachedStore then
		setCustomerState(customerState, "Browsing", getBrowsingSpotPosition())
	end
end

local function updateBrowsingState(customerState: CustomerState, deltaTime: number)
	-- Customers walk to the browsing spot first, then wait so the shop feels active.
	moveCustomerTowardTarget(customerState, deltaTime)

	local secondsSpentBrowsing = os.clock() - customerState.StateStartedAt

	if secondsSpentBrowsing >= BrowseDurationSeconds then
		setCustomerState(customerState, "Buying", getCheckoutPosition())
	end
end

local function updateBuyingState(customerState: CustomerState, deltaTime: number)
	-- Buying rewards a store owner, then immediately transitions into leaving.
	local reachedCheckout = moveCustomerTowardTarget(customerState, deltaTime)

	if not reachedCheckout then
		return
	end

	local customerOwner = chooseCustomerOwner()

	if customerOwner then
		local storeData = getStoreDataForPlayer(customerOwner)

		storeData.CoinsWaitingToCollect += 12
		sendStoreStatusToPlayer(customerOwner)

		if math.random() < MessChanceAfterCustomerLeaves then
			addMessToStore(customerOwner)
		end
	end

	setCustomerState(customerState, "Leaving", getCustomerExitPosition())
end

local function updateLeavingState(customerState: CustomerState, deltaTime: number)
	-- Once the customer reaches the exit, the model can be safely destroyed.
	local reachedExit = moveCustomerTowardTarget(customerState, deltaTime)

	if reachedExit then
		setCustomerState(customerState, "Despawning")
	end
end

local function updateOneCustomer(customerState: CustomerState, deltaTime: number)
	-- A plain if-chain keeps the state machine easy to trace for a junior teammate.
	if customerState.StateName == "WalkingToStore" then
		updateWalkingToStoreState(customerState, deltaTime)
	elseif customerState.StateName == "Browsing" then
		updateBrowsingState(customerState, deltaTime)
	elseif customerState.StateName == "Buying" then
		updateBuyingState(customerState, deltaTime)
	elseif customerState.StateName == "Leaving" then
		updateLeavingState(customerState, deltaTime)
	end
end

local function getPlacementCollisionFolder(): Folder
	-- The folder is the single source of truth for placed shop objects and overlap checks.
	local existingFolder = workspace:FindFirstChild(PlacementCollisionFolderName)

	if existingFolder and existingFolder:IsA("Folder") then
		return existingFolder
	end

	local newFolder = Instance.new("Folder")
	newFolder.Name = PlacementCollisionFolderName
	newFolder.Parent = workspace

	return newFolder
end

local function isPlacementInsideStoreBounds(itemWorldCFrame: CFrame, itemWorldSize: Vector3): boolean
	-- Object-space math lets the build area be moved or rotated in Studio without rewriting code.
	local storeBoundsPart = workspace:FindFirstChild(StoreBoundsPartName)

	if not storeBoundsPart or not storeBoundsPart:IsA("BasePart") then
		return false
	end

	local localPositionInsideStore = storeBoundsPart.CFrame:PointToObjectSpace(itemWorldCFrame.Position)
	local halfStoreWidth = storeBoundsPart.Size.X / 2
	local halfStoreDepth = storeBoundsPart.Size.Z / 2
	local halfItemWidth = itemWorldSize.X / 2
	local halfItemDepth = itemWorldSize.Z / 2

	return localPositionInsideStore.X - halfItemWidth >= -halfStoreWidth
		and localPositionInsideStore.X + halfItemWidth <= halfStoreWidth
		and localPositionInsideStore.Z - halfItemDepth >= -halfStoreDepth
		and localPositionInsideStore.Z + halfItemDepth <= halfStoreDepth
end

local function doesPlacementOverlapExistingItems(itemWorldCFrame: CFrame, itemWorldSize: Vector3): boolean
	-- The server repeats the client overlap check because clients should never be trusted with placement truth.
	local overlapParameters = OverlapParams.new()
	overlapParameters.FilterType = Enum.RaycastFilterType.Include
	overlapParameters.FilterDescendantsInstances = { getPlacementCollisionFolder() }

	local overlappingParts = workspace:GetPartBoundsInBox(itemWorldCFrame, itemWorldSize, overlapParameters)

	return #overlappingParts > 0
end

local function createFishTankAtCFrame(itemWorldCFrame: CFrame)
	-- The tank is a simple part model today, and each named part can later be replaced by a mesh.
	local fishTankModel = Instance.new("Model")
	fishTankModel.Name = "FishTank"

	local tankStand = Instance.new("Part")
	tankStand.Name = "Stand"
	tankStand.Anchored = true
	tankStand.Size = Vector3.new(GridCellSize * 2, 1, GridCellSize)
	tankStand.CFrame = itemWorldCFrame * CFrame.new(0, -0.5, 0)
	tankStand.Color = Color3.fromRGB(60, 45, 35)
	tankStand.Parent = fishTankModel

	local waterPart = Instance.new("Part")
	waterPart.Name = "Water"
	waterPart.Anchored = true
	waterPart.Size = Vector3.new((GridCellSize * 2) - 0.5, 2, GridCellSize - 0.5)
	waterPart.CFrame = itemWorldCFrame * CFrame.new(0, 1, 0)
	waterPart.Color = Color3.fromRGB(70, 180, 255)
	waterPart.Transparency = 0.35
	waterPart.Material = Enum.Material.Glass
	waterPart.Parent = fishTankModel

	local fishPart = Instance.new("Part")
	fishPart.Name = "DisplayFish"
	fishPart.Anchored = true
	fishPart.Shape = Enum.PartType.Ball
	fishPart.Size = Vector3.new(0.8, 0.4, 0.4)
	fishPart.CFrame = itemWorldCFrame * CFrame.new(0, 1.2, 0)
	fishPart.Color = Color3.fromRGB(255, 210, 70)
	fishPart.Parent = fishTankModel

	fishTankModel.PrimaryPart = tankStand
	fishTankModel.Parent = getPlacementCollisionFolder()
end

local function handlePlaceStoreItemRequested(player: Player, itemName: string, itemWorldCFrame: CFrame)
	-- This is the server authority point for build mode: clients request placement, but the server decides.
	if itemName ~= "FishTank" then
		return
	end

	if typeof(itemWorldCFrame) ~= "CFrame" then
		return
	end

	local itemWorldSize = Vector3.new(GridCellSize * 2, 3, GridCellSize)

	if not isPlacementInsideStoreBounds(itemWorldCFrame, itemWorldSize) then
		return
	end

	if doesPlacementOverlapExistingItems(itemWorldCFrame, itemWorldSize) then
		return
	end

	createFishTankAtCFrame(itemWorldCFrame)
	sendStoreStatusToPlayer(player)
end

local function removeDespawnedCustomers()
	-- Reverse iteration allows removals without skipping the next customer in the array.
	for customerIndex = #ActiveCustomerStates, 1, -1 do
		local customerState = ActiveCustomerStates[customerIndex]

		if customerState.StateName == "Despawning" then
			customerState.Model:Destroy()
			table.remove(ActiveCustomerStates, customerIndex)
		end
	end
end

local function updateCustomerSpawning(deltaTime: number)
	-- Accumulating delta time gives predictable spawn timing without a separate while loop.
	SecondsSinceLastCustomerSpawn += deltaTime

	if SecondsSinceLastCustomerSpawn < CustomerSpawnIntervalSeconds then
		return
	end

	SecondsSinceLastCustomerSpawn = 0
	spawnCustomer()
end

local function updateAllCustomers(deltaTime: number)
	-- Updating every customer from one loop keeps the AI behavior centralized and inspectable.
	updateCustomerSpawning(deltaTime)

	for _, customerState in ActiveCustomerStates do
		updateOneCustomer(customerState, deltaTime)
	end

	removeDespawnedCustomers()
end

local function handlePlayerRemoving(player: Player)
	-- Prototype data is cleaned with the player because persistence is intentionally not wired yet.
	StoreManagementDataByUserId[player.UserId] = nil
end

function CustomerAIService.Start()
	-- Heartbeat is enough for prototype AI because movement is simple and server-owned.
	RunService.Heartbeat:Connect(updateAllCustomers)
	PlaceStoreItemRequestedRemote.OnServerEvent:Connect(handlePlaceStoreItemRequested)
	Players.PlayerAdded:Connect(sendStoreStatusToPlayer)
	Players.PlayerRemoving:Connect(handlePlayerRemoving)
end

CustomerAIService.UpgradeStoreSpaceForPlayer = upgradeStoreSpaceForPlayer
CustomerAIService.CleanOneMessFromStore = cleanOneMessFromStore

return CustomerAIService

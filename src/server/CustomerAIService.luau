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
local RunService = game:GetService("RunService")

local CustomerAIService = {}

local CustomerSpawnIntervalSeconds = 8
local CustomerWalkSpeedStudsPerSecond = 8
local BrowseDurationSeconds = 5
local DespawnDistanceStuds = 60
local MessChanceAfterCustomerLeaves = 0.25

local ActiveCustomerStates: { CustomerState } = {}
local StoreManagementDataByUserId: { [number]: StoreManagementData } = {}
local SecondsSinceLastCustomerSpawn = 0

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
end

local function cleanOneMessFromStore(player: Player)
	-- Clamping at zero keeps cleanup buttons from accidentally creating negative mess.
	local storeData = getStoreDataForPlayer(player)

	storeData.MessCount = math.max(0, storeData.MessCount - 1)
end

local function createPlaceholderCustomerModel(customerSpawnPosition: Vector3): Model
	-- The placeholder is made from one Part so it can be swapped for a Blender rig later without changing AI flow.
	local customerModel = Instance.new("Model")
	customerModel.Name = "PrototypeCustomer"

	local bodyPart = Instance.new("Part")
	bodyPart.Name = "Body"
	bodyPart.Anchored = true
	bodyPart.Size = Vector3.new(2, 4, 2)
	bodyPart.Position = customerSpawnPosition
	bodyPart.Color = Color3.fromRGB(255, 230, 160)
	bodyPart.Parent = customerModel

	customerModel.PrimaryPart = bodyPart
	customerModel.Parent = workspace

	return customerModel
end

local function setCustomerState(customerState: CustomerState, nextStateName: CustomerStateName, targetPosition: Vector3?)
	-- Every state transition refreshes the timer so each state can use simple elapsed-time checks.
	customerState.StateName = nextStateName
	customerState.StateStartedAt = os.clock()

	if targetPosition then
		customerState.TargetPosition = targetPosition
	end
end

local function getStoreEntrancePosition(): Vector3
	-- A Studio part named StoreEntrance can override this once the map is built.
	local storeEntrance = workspace:FindFirstChild("StoreEntrance")

	if storeEntrance and storeEntrance:IsA("BasePart") then
		return storeEntrance.Position
	end

	return Vector3.new(0, 2, -20)
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
		setCustomerState(customerState, "Browsing")
	end
end

local function updateBrowsingState(customerState: CustomerState)
	-- Browsing waits a few seconds so buying feels like a decision instead of an instant event.
	local secondsSpentBrowsing = os.clock() - customerState.StateStartedAt

	if secondsSpentBrowsing >= BrowseDurationSeconds then
		setCustomerState(customerState, "Buying")
	end
end

local function updateBuyingState(customerState: CustomerState)
	-- Buying rewards a store owner, then immediately transitions into leaving.
	local customerOwner = chooseCustomerOwner()

	if customerOwner then
		local storeData = getStoreDataForPlayer(customerOwner)

		storeData.CoinsWaitingToCollect += 12

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
		updateBrowsingState(customerState)
	elseif customerState.StateName == "Buying" then
		updateBuyingState(customerState)
	elseif customerState.StateName == "Leaving" then
		updateLeavingState(customerState, deltaTime)
	end
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
	Players.PlayerRemoving:Connect(handlePlayerRemoving)
end

CustomerAIService.UpgradeStoreSpaceForPlayer = upgradeStoreSpaceForPlayer
CustomerAIService.CleanOneMessFromStore = cleanOneMessFromStore

return CustomerAIService

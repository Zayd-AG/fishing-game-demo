export type BuildableItemDefinition = {
	Name: string,
	GridWidthInCells: number,
	GridDepthInCells: number,
	PreviewColor: Color3,
}

export type GridPlacementResult = {
	IsValid: boolean,
	WorldCFrame: CFrame,
	GridX: number,
	GridZ: number,
	FailureReason: string?,
}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local StoreBuilderController = {}

local LocalPlayer = Players.LocalPlayer
local Mouse = LocalPlayer:GetMouse()

local RemoteFolderName = "GameRemotes"
local FishCaughtRemoteName = "FishCaught"
local PlaceStoreItemRequestRemoteName = "PlaceStoreItemRequested"
local StoreStatusChangedRemoteName = "StoreStatusChanged"

local GridCellSize = 4
local StoreBoundsPartName = "StorePlacementBounds"
local PlacementCollisionFolderName = "PlacedStoreItems"
local GhostBlockTransparency = 0.45

local BuildableItemsByName: { [string]: BuildableItemDefinition } = {
	FishTank = {
		Name = "FishTank",
		GridWidthInCells = 2,
		GridDepthInCells = 1,
		PreviewColor = Color3.fromRGB(70, 180, 255),
	},
}

local IsBuildModeEnabled = false
local SelectedBuildableItem: BuildableItemDefinition = BuildableItemsByName.FishTank
local GhostBlock: Part? = nil
local LastPlacementResult: GridPlacementResult? = nil
local StatusLabel: TextLabel? = nil
local FishCaughtLabel: TextLabel? = nil
local BuildModeButton: TextButton? = nil

local function getRemoteEvent(remoteEventName: string): RemoteEvent
	-- Waiting for remotes keeps startup order simple between Rojo sync and server service creation.
	local remoteFolder = ReplicatedStorage:WaitForChild(RemoteFolderName)

	return remoteFolder:WaitForChild(remoteEventName) :: RemoteEvent
end

local FishCaughtRemote = getRemoteEvent(FishCaughtRemoteName)
local PlaceStoreItemRequestedRemote = getRemoteEvent(PlaceStoreItemRequestRemoteName)
local StoreStatusChangedRemote = getRemoteEvent(StoreStatusChangedRemoteName)

local function getStoreBoundsPart(): BasePart?
	-- A simple Studio part defines the buildable area so level designers can resize the store visually.
	local storeBoundsPart = workspace:FindFirstChild(StoreBoundsPartName)

	if storeBoundsPart and storeBoundsPart:IsA("BasePart") then
		return storeBoundsPart
	end

	return nil
end

local function getOrCreatePlacementCollisionFolder(): Folder
	-- Placed items live together so overlap checks can ignore unrelated map geometry.
	local existingFolder = workspace:FindFirstChild(PlacementCollisionFolderName)

	if existingFolder and existingFolder:IsA("Folder") then
		return existingFolder
	end

	local newFolder = Instance.new("Folder")
	newFolder.Name = PlacementCollisionFolderName
	newFolder.Parent = workspace

	return newFolder
end

local function createGhostBlock(): Part
	-- The ghost uses a basic Part because it will be replaced by item-specific preview meshes later.
	local ghostBlock = Instance.new("Part")
	ghostBlock.Name = "BuildModeGhostBlock"
	ghostBlock.Anchored = true
	ghostBlock.CanCollide = false
	ghostBlock.CanQuery = false
	ghostBlock.CanTouch = false
	ghostBlock.Material = Enum.Material.ForceField
	ghostBlock.Transparency = GhostBlockTransparency
	ghostBlock.Parent = workspace

	return ghostBlock
end

local function createPrototypeHud()
	-- The HUD makes the prototype self-explanatory for playtests without adding a heavy UI framework.
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "PrototypeHud"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = playerGui

	local statusLabel = Instance.new("TextLabel")
	statusLabel.Name = "StatusLabel"
	statusLabel.AnchorPoint = Vector2.new(0, 1)
	statusLabel.Position = UDim2.fromScale(0.02, 0.98)
	statusLabel.Size = UDim2.fromOffset(440, 88)
	statusLabel.BackgroundColor3 = Color3.fromRGB(20, 24, 30)
	statusLabel.BackgroundTransparency = 0.15
	statusLabel.Font = Enum.Font.Gotham
	statusLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	statusLabel.TextSize = 18
	statusLabel.TextXAlignment = Enum.TextXAlignment.Left
	statusLabel.TextYAlignment = Enum.TextYAlignment.Center
	statusLabel.TextWrapped = true
	statusLabel.Text = "Go to the ship and press the prompt to cast your net. Press B to build fish tanks in the shop."
	statusLabel.Parent = screenGui

	local fishCaughtLabel = Instance.new("TextLabel")
	fishCaughtLabel.Name = "FishCaughtLabel"
	fishCaughtLabel.AnchorPoint = Vector2.new(0.5, 0)
	fishCaughtLabel.Position = UDim2.fromScale(0.5, 0.06)
	fishCaughtLabel.Size = UDim2.fromOffset(420, 70)
	fishCaughtLabel.BackgroundColor3 = Color3.fromRGB(10, 35, 55)
	fishCaughtLabel.BackgroundTransparency = 0.1
	fishCaughtLabel.Font = Enum.Font.GothamBold
	fishCaughtLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	fishCaughtLabel.TextSize = 24
	fishCaughtLabel.TextWrapped = true
	fishCaughtLabel.Visible = false
	fishCaughtLabel.Parent = screenGui

	local buildModeButton = Instance.new("TextButton")
	buildModeButton.Name = "BuildModeButton"
	buildModeButton.AnchorPoint = Vector2.new(1, 1)
	buildModeButton.Position = UDim2.fromScale(0.98, 0.98)
	buildModeButton.Size = UDim2.fromOffset(220, 56)
	buildModeButton.BackgroundColor3 = Color3.fromRGB(70, 120, 255)
	buildModeButton.Font = Enum.Font.GothamBold
	buildModeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	buildModeButton.TextSize = 18
	buildModeButton.Text = "Build Fish Tank (B)"
	buildModeButton.Parent = screenGui

	StatusLabel = statusLabel
	FishCaughtLabel = fishCaughtLabel
	BuildModeButton = buildModeButton
end

local function updateStatusText(message: string)
	-- A single status label gives immediate feedback for build mode, fishing, and customer rewards.
	if StatusLabel then
		StatusLabel.Text = message
	end
end

local function setGhostBlockColor(isPlacementValid: boolean)
	-- Green means the server should accept the placement, while red explains that the current cell is blocked.
	if not GhostBlock then
		return
	end

	if isPlacementValid then
		GhostBlock.Color = Color3.fromRGB(90, 255, 140)
	else
		GhostBlock.Color = Color3.fromRGB(255, 80, 80)
	end
end

local function calculateItemWorldSize(itemDefinition: BuildableItemDefinition): Vector3
	-- Multiplying grid cells by cell size converts designer-friendly grid dimensions into Roblox studs.
	return Vector3.new(
		itemDefinition.GridWidthInCells * GridCellSize,
		2,
		itemDefinition.GridDepthInCells * GridCellSize
	)
end

local function snapWorldPositionToStoreGrid(worldPosition: Vector3, storeBoundsPart: BasePart): (number, number, Vector3)
	-- Object space turns an angled store into a flat local grid, so snapping still works if the plot rotates.
	local localPositionInsideStore = storeBoundsPart.CFrame:PointToObjectSpace(worldPosition)

	-- Dividing by cell size converts studs into grid cells; rounding chooses the nearest cell center.
	local snappedGridX = math.round(localPositionInsideStore.X / GridCellSize)
	local snappedGridZ = math.round(localPositionInsideStore.Z / GridCellSize)

	-- Multiplying back by cell size converts the chosen grid cell into local studs again.
	local snappedLocalPosition = Vector3.new(snappedGridX * GridCellSize, 0, snappedGridZ * GridCellSize)
	local snappedWorldPosition = storeBoundsPart.CFrame:PointToWorldSpace(snappedLocalPosition)

	return snappedGridX, snappedGridZ, snappedWorldPosition
end

local function isPlacementInsideStoreBounds(
	itemDefinition: BuildableItemDefinition,
	gridX: number,
	gridZ: number,
	storeBoundsPart: BasePart
): boolean
	-- Half extents let us compare the item footprint against the store footprint from the center outward.
	local halfStoreWidthInCells = math.floor((storeBoundsPart.Size.X / GridCellSize) / 2)
	local halfStoreDepthInCells = math.floor((storeBoundsPart.Size.Z / GridCellSize) / 2)
	local halfItemWidthInCells = itemDefinition.GridWidthInCells / 2
	local halfItemDepthInCells = itemDefinition.GridDepthInCells / 2

	if gridX - halfItemWidthInCells < -halfStoreWidthInCells then
		return false
	end

	if gridX + halfItemWidthInCells > halfStoreWidthInCells then
		return false
	end

	if gridZ - halfItemDepthInCells < -halfStoreDepthInCells then
		return false
	end

	if gridZ + halfItemDepthInCells > halfStoreDepthInCells then
		return false
	end

	return true
end

local function doesPlacementOverlapExistingItems(itemWorldCFrame: CFrame, itemWorldSize: Vector3): boolean
	-- GetPartBoundsInBox gives a clear clipping test without writing custom rectangle intersection code.
	local overlapParameters = OverlapParams.new()
	overlapParameters.FilterType = Enum.RaycastFilterType.Include
	overlapParameters.FilterDescendantsInstances = { getOrCreatePlacementCollisionFolder() }

	local overlappingParts = workspace:GetPartBoundsInBox(itemWorldCFrame, itemWorldSize, overlapParameters)

	return #overlappingParts > 0
end

local function getMouseWorldPositionOnStorePlane(storeBoundsPart: BasePart): Vector3?
	-- Raycasting from the mouse lets build mode work with the camera instead of keyboard-only placement.
	local camera = workspace.CurrentCamera

	if not camera then
		return nil
	end

	local mouseRay = camera:ScreenPointToRay(Mouse.X, Mouse.Y)
	local raycastParameters = RaycastParams.new()
	raycastParameters.FilterType = Enum.RaycastFilterType.Include
	raycastParameters.FilterDescendantsInstances = { storeBoundsPart }

	local raycastResult = workspace:Raycast(mouseRay.Origin, mouseRay.Direction * 500, raycastParameters)

	if not raycastResult then
		return nil
	end

	return raycastResult.Position
end

local function calculatePlacementFromMouse(): GridPlacementResult?
	-- This function returns every decision build mode needs, so rendering and clicking stay simple.
	local storeBoundsPart = getStoreBoundsPart()

	if not storeBoundsPart then
		return nil
	end

	local mouseWorldPosition = getMouseWorldPositionOnStorePlane(storeBoundsPart)

	if not mouseWorldPosition then
		return nil
	end

	local gridX, gridZ, snappedWorldPosition = snapWorldPositionToStoreGrid(mouseWorldPosition, storeBoundsPart)
	local itemWorldSize = calculateItemWorldSize(SelectedBuildableItem)

	-- Raising by half height places the preview on top of the store plane instead of halfway through it.
	local liftedWorldPosition = snappedWorldPosition + Vector3.new(0, itemWorldSize.Y / 2, 0)
	local itemWorldCFrame = CFrame.new(liftedWorldPosition) * storeBoundsPart.CFrame.Rotation

	if not isPlacementInsideStoreBounds(SelectedBuildableItem, gridX, gridZ, storeBoundsPart) then
		return {
			IsValid = false,
			WorldCFrame = itemWorldCFrame,
			GridX = gridX,
			GridZ = gridZ,
			FailureReason = "Outside store bounds",
		}
	end

	if doesPlacementOverlapExistingItems(itemWorldCFrame, itemWorldSize) then
		return {
			IsValid = false,
			WorldCFrame = itemWorldCFrame,
			GridX = gridX,
			GridZ = gridZ,
			FailureReason = "Overlaps another item",
		}
	end

	return {
		IsValid = true,
		WorldCFrame = itemWorldCFrame,
		GridX = gridX,
		GridZ = gridZ,
	}
end

local function updateGhostBlock()
	-- The ghost updates every frame so build mode feels responsive while the mouse moves.
	if not IsBuildModeEnabled then
		return
	end

	if not GhostBlock then
		GhostBlock = createGhostBlock()
	end

	local placementResult = calculatePlacementFromMouse()

	if not placementResult then
		GhostBlock.Transparency = 1
		LastPlacementResult = nil
		return
	end

	local itemWorldSize = calculateItemWorldSize(SelectedBuildableItem)

	GhostBlock.Size = itemWorldSize
	GhostBlock.CFrame = placementResult.WorldCFrame
	GhostBlock.Transparency = GhostBlockTransparency
	LastPlacementResult = placementResult

	setGhostBlockColor(placementResult.IsValid)
end

local function placeSelectedItem()
	-- The client sends the chosen CFrame, then the server repeats validation before creating the tank.
	if not LastPlacementResult or not LastPlacementResult.IsValid then
		updateStatusText("Move the ghost inside the shop and away from other tanks before placing.")
		return
	end

	PlaceStoreItemRequestedRemote:FireServer(SelectedBuildableItem.Name, LastPlacementResult.WorldCFrame)
	updateStatusText("Placed a fish tank request. Customers can browse and buy from your shop.")
end

local function setBuildModeEnabled(shouldEnableBuildMode: boolean)
	-- Toggling build mode owns ghost lifetime so the workspace does not collect stale previews.
	IsBuildModeEnabled = shouldEnableBuildMode

	if not IsBuildModeEnabled and GhostBlock then
		GhostBlock:Destroy()
		GhostBlock = nil
		LastPlacementResult = nil
	end

	if BuildModeButton then
		BuildModeButton.Text = if IsBuildModeEnabled then "Placing Fish Tank" else "Build Fish Tank (B)"
	end

	if IsBuildModeEnabled then
		updateStatusText("Build mode is on. Move your mouse over the blue shop floor and click to place a fish tank.")
	else
		updateStatusText("Build mode is off. Go to the ship prompt to cast your net, or press B to build.")
	end
end

local function handleInputBegan(inputObject: InputObject, wasHandledByRoblox: boolean)
	-- Build controls stay small for the prototype: B toggles mode, click places the selected item.
	if wasHandledByRoblox then
		return
	end

	if inputObject.KeyCode == Enum.KeyCode.B then
		setBuildModeEnabled(not IsBuildModeEnabled)
	elseif inputObject.UserInputType == Enum.UserInputType.MouseButton1 and IsBuildModeEnabled then
		placeSelectedItem()
	end
end

local function handleFishCaught(castNetResult)
	-- The server tells us the rarest fish so the client can play the most exciting popup.
	local rarestFishCaught = castNetResult.RarestFishCaught

	if not FishCaughtLabel or not rarestFishCaught then
		return
	end

	FishCaughtLabel.Text = `Caught {rarestFishCaught.RarityName}: {rarestFishCaught.Name}! +{castNetResult.TotalSellValue} coins`
	FishCaughtLabel.Visible = true
	updateStatusText("Nice catch. Add tanks in the shop so customers have something clear to browse.")

	task.delay(3, function()
		if FishCaughtLabel then
			FishCaughtLabel.Visible = false
		end
	end)
end

local function handleStoreStatusChanged(storeData)
	-- Store data feedback makes customer purchases and mess visible before final tycoon UI exists.
	updateStatusText(
		`Shop level {storeData.StoreLevel} | Waiting coins: {storeData.CoinsWaitingToCollect} | Messes to clean: {storeData.MessCount}`
	)
end

function StoreBuilderController.Start()
	-- Start connects input and render updates without introducing a larger controller framework.
	createPrototypeHud()
	UserInputService.InputBegan:Connect(handleInputBegan)
	RunService.RenderStepped:Connect(updateGhostBlock)
	FishCaughtRemote.OnClientEvent:Connect(handleFishCaught)
	StoreStatusChangedRemote.OnClientEvent:Connect(handleStoreStatusChanged)

	if BuildModeButton then
		BuildModeButton.Activated:Connect(function()
			setBuildModeEnabled(not IsBuildModeEnabled)
		end)
	end
end

return StoreBuilderController

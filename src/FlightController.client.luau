-- Flight controller with customizable animations and an anti collision system

local ACTION_KEYS = {
	W = "__FLY_W__",
	A = "__FLY_A__",
	S = "__FLY_S__",
	D = "__FLY_D__",

	SPACE = "__FLY_SPACE__",
	LSHIFT = "__FLY_LSHIFT__",
}

local RAYCAST_SPACING = 2 -- How spread out raycasts are from each other (Higher value means more precision, there is an efficiency trade-off tho)
local RAYCAST_DISTANCE = 2 -- Raycast direction length

local KeyCode = Enum.KeyCode

local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer
local PlayerScripts = LocalPlayer:WaitForChild("PlayerScripts")

local PlayerModule = require(PlayerScripts.PlayerModule) :: ModuleScript
local RobloxControls = PlayerModule:GetControls()

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LLoPackages = Shared.LLoPackages

local Maid = require(LLoPackages.Maid) -- Maid was developed by me, but the functionality is virtually the same

local CurrentCamera = workspace.CurrentCamera

local LinearVelocity = script.LinearVelocity
local AlignOrientation = script.AlignOrientation

local function switch(value)
	return function(cases: { [any | "Default"]: () -> () })
		local case = cases[value] or cases["Default"]
		if case then
			case()
		end
	end
end

local function get_tracks(animator: Animator, fly_animations)
	return {
		idle = (fly_animations.Idle and animator:LoadAnimation(fly_animations.Idle)),

		forward = (fly_animations.Forward and animator:LoadAnimation(fly_animations.Forward)),
		backward = (fly_animations.Backward and animator:LoadAnimation(fly_animations.Backward)),

		left_strafing = (fly_animations.LeftStrafing and animator:LoadAnimation(fly_animations.LeftStrafing)),
		right_strafing = (fly_animations.RightStrafing and animator:LoadAnimation(fly_animations.RightStrafing)),

		left_diagonal_forward = (fly_animations.LeftDiagonalForward and animator:LoadAnimation(
			fly_animations.LeftDiagonalForward
		)),
		right_diagonal_forward = (fly_animations.RightDiagonalForward and animator:LoadAnimation(
			fly_animations.RightDiagonalForward
		)),

		left_diagonal_backward = (fly_animations.LeftDiagonalBackward and animator:LoadAnimation(
			fly_animations.LeftDiagonalBackward
		)),
		right_diagonal_backward = (fly_animations.RightDiagonalBackward and animator:LoadAnimation(
			fly_animations.RightDiagonalBackward
		)),
	}
end

local function get_vectordirection() -- Check if control keys are already held down and calculate the vector direction
	local direction = Vector3.zero

	if UserInputService:IsKeyDown(KeyCode.W) then
		direction += Vector3.new(0, 0, 1)
	end
	if UserInputService:IsKeyDown(KeyCode.A) then
		direction += Vector3.new(-1, 0, 0)
	end
	if UserInputService:IsKeyDown(KeyCode.S) then
		direction += Vector3.new(0, 0, -1)
	end
	if UserInputService:IsKeyDown(KeyCode.D) then
		direction += Vector3.new(1, 0, 0)
	end

	if UserInputService:IsKeyDown(KeyCode.Space) then
		direction += Vector3.new(0, 1, 0)
	end
	if UserInputService:IsKeyDown(KeyCode.LeftShift) then
		direction += Vector3.new(0, -1, 0)
	end

	return direction
end

local function is_colliding(character, move_direction)
	local root_part = character.PrimaryPart

	local size = root_part.Size

	local up_vector = root_part.CFrame.UpVector
	local right_vector = root_part.CFrame.RightVector
	local look_vector = root_part.CFrame.LookVector

	local abs = math.abs
	local ceil = math.ceil

	local face_size1, face_size2
	if abs(move_direction:Dot(look_vector)) > 0.9 then -- Check if the character is facing close enough to a specific direction
		face_size1, face_size2 = size.Y, size.X -- The front or back face
	elseif abs(move_direction:Dot(up_vector)) > 0.9 then
		face_size1, face_size2 = size.X, size.Z -- The top or bottom face
	else
		face_size1, face_size2 = size.Y, size.Z -- The side faces
	end

	local rays_count1 = ceil(face_size1 / RAYCAST_SPACING) -- How many raycast columns
	local rays_count2 = ceil(face_size2 / RAYCAST_SPACING) -- How many rows

	local params = RaycastParams.new()
	params.IgnoreWater = true
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.RespectCanCollide = true

	local center_origin = root_part.Position + (move_direction * (size.Z / 2))
	local direction = (move_direction * RAYCAST_DISTANCE)

	for i = 0, rays_count1, 1 do
		for j = 0, rays_count2, 1 do
			local offset1 = (i - rays_count1 / 2) * RAYCAST_SPACING * right_vector
			local offset2 = (j - rays_count2 / 2) * RAYCAST_SPACING * up_vector

			local origin = (center_origin + offset1 + offset2)

			if workspace:Raycast(origin, direction, params) then
				return true
			end
		end
	end

	return false
end

local FlightController = {}
FlightController.__index = FlightController

function FlightController:_addMovers()
	local character = self._character

	local attachment = Instance.new("Attachment")
	attachment.Parent = character.PrimaryPart

	local linear_velocity = LinearVelocity:Clone()
	linear_velocity.Parent = character
	linear_velocity.Attachment0 = attachment

	local align_orientation = AlignOrientation:Clone()
	align_orientation.Parent = character
	align_orientation.Attachment0 = attachment

	self._Maid.linear_velocity = linear_velocity
	self._Maid.align_orientation = align_orientation

	self._Maid:GiveTask(attachment)
end

function FlightController:_initFrameUpdate()
	local function step(delta_time)
		local speed = self.Speed
		local vector_direction = self.VectorDirection

		local camera_cframe = CurrentCamera.CFrame

		local look_vector = camera_cframe.LookVector
		local right_vector = camera_cframe.RightVector
		local up_vector = camera_cframe.UpVector

		-- Calculate the vector direction relative to the camera
		local move_direction = (right_vector * vector_direction.X)
			+ (up_vector * vector_direction.Y)
			+ (look_vector * vector_direction.Z)

		local final_velocity = Vector3.zero
		if not is_colliding(self._character, move_direction) then
			final_velocity = (move_direction * speed)
		end

		self._Maid.linear_velocity.VectorVelocity = final_velocity
		self._Maid.align_orientation.CFrame = camera_cframe.Rotation
	end
	return RunService.PreSimulation:Connect(step)
end

function FlightController:_stopAnimation()
	for _, track in self._tracks do
		if not track then
			continue
		end
		track:Stop()
	end
end

function FlightController:_updateAnimation()
	local vector_direction = self.VectorDirection
	local tracks = self._tracks

	self:_stopAnimation()

	local function play(track)
		return function()
			if not track then
				return
			end
			track:Play()

			return true
		end
	end

	switch(vector_direction)({
		[Vector3.new(0, 0, 1)] = play(tracks.forward),
		[Vector3.new(0, 0, -1)] = play(tracks.backward),
		[Vector3.new(-1, 0, 0)] = play(tracks.left_strafing),
		[Vector3.new(1, 0, 0)] = play(tracks.right_strafing),
		[Vector3.new(-1, 0, 1)] = play(tracks.left_diagonal_forward),
		[Vector3.new(1, 0, 1)] = play(tracks.right_diagonal_forward),
		[Vector3.new(-1, 0, -1)] = play(tracks.left_diagonal_backward),
		[Vector3.new(1, 0, -1)] = play(tracks.right_diagonal_backward),

		default = play(tracks.idle),
	})
end

function FlightController:_bindActions()
	local function closure(direction)
		return function(action_name, input_state)
			if input_state == Enum.UserInputState.Begin then
				self.VectorDirection += direction
			elseif input_state == Enum.UserInputState.End or input_state == Enum.UserInputState.Cancel then
				self.VectorDirection -= direction
			end

			self:_updateAnimation()
		end
	end

	ContextActionService:BindAction(ACTION_KEYS.W, closure(Vector3.new(0, 0, 1)), false, KeyCode.W)
	ContextActionService:BindAction(ACTION_KEYS.A, closure(Vector3.new(-1, 0, 0)), false, KeyCode.A)
	ContextActionService:BindAction(ACTION_KEYS.S, closure(Vector3.new(0, 0, -1)), false, KeyCode.S)
	ContextActionService:BindAction(ACTION_KEYS.D, closure(Vector3.new(1, 0, 0)), false, KeyCode.D)

	ContextActionService:BindAction(ACTION_KEYS.SPACE, closure(Vector3.new(0, 1, 0)), false, KeyCode.Space)
	ContextActionService:BindAction(ACTION_KEYS.LSHIFT, closure(Vector3.new(0, -1, 0)), false, KeyCode.LeftShift)
end
function FlightController:_unbindActions()
	ContextActionService:UnbindAction(ACTION_KEYS.W)
	ContextActionService:UnbindAction(ACTION_KEYS.A)
	ContextActionService:UnbindAction(ACTION_KEYS.S)
	ContextActionService:UnbindAction(ACTION_KEYS.D)

	ContextActionService:UnbindAction(ACTION_KEYS.SPACE)
	ContextActionService:UnbindAction(ACTION_KEYS.LSHIFT)
end

function FlightController:_init()
	self:_bindActions()
	self:_addMovers()
	self:_updateAnimation()

	self._humanoid.PlatformStand = true -- Disable ragdoll and other stuff
	RobloxControls:Disable() -- Disable roblox character movement

	local function on_destroy()
		self:_unbindActions()
		self:_stopAnimation()

		self._humanoid.PlatformStand = false
		RobloxControls:Enable() -- Give movement control back to roblox
	end

	self._Maid:GiveTask(self:_initFrameUpdate())
	self._Maid:GiveTask(on_destroy)
end

function FlightController.new(speed, fly_animations)
	local self = setmetatable({}, FlightController)

	self.Speed = speed
	self.VectorDirection = get_vectordirection()

	self._Maid = Maid.new()

	self._character = LocalPlayer.Character
	self._humanoid = LocalPlayer.Character.Humanoid

	self._tracks = get_tracks(self._humanoid.Animator, fly_animations)

	self:_init()

	return self
end

function FlightController:Destroy()
	self._Maid:Destroy()
end

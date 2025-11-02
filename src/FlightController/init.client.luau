-- Flight controller with customizable animations and an anti collision system

local ACTION_KEYS = { -- Constants for ContextActionService action names
	W = "__FLY_W__", -- W key
	A = "__FLY_A__", -- A key
	S = "__FLY_S__", -- S key
	D = "__FLY_D__", -- D key

	SPACE = "__FLY_SPACE__", -- Space key
	LSHIFT = "__FLY_LSHIFT__", -- Left shift key
}

local RAYCAST_SPACING = 2 -- How spread out raycasts are from each other (Higher value means more precision, there is an efficiency trade-off tho)
local RAYCAST_DISTANCE = 2 -- Raycast direction length

local KeyCode = Enum.KeyCode -- Reference to remove some boilerplate code

local RunService = game:GetService("RunService") -- Reference to the RunService service
local ContextActionService = game:GetService("ContextActionService") -- Reference to the ContextActionService service
local UserInputService = game:GetService("UserInputService") -- Reference to the UserInputService service

local ReplicatedStorage = game:GetService("ReplicatedStorage") -- Reference to the ReplicatedStorage service
local Players = game:GetService("Players") -- Reference to the Players service

local LocalPlayer = Players.LocalPlayer -- Reference to the LocalPlayer
local PlayerScripts = LocalPlayer:WaitForChild("PlayerScripts") -- Reference to PlayerScripts folder

local PlayerModule = require(PlayerScripts:WaitForChild("PlayerModule")) :: ModuleScript -- Reference to official roblox system for character and user controls
local RobloxControls = PlayerModule:GetControls() -- Reference to official roblox controls system

local Maid = require(ReplicatedStorage.LLoPkgs.Maid.Maid) -- Maid was developed by me, but the functionality is virtually the same

local CurrentCamera = workspace.CurrentCamera -- A reference to the player's camera, it is crucial for proper movement

local LinearVelocity = script.LinearVelocity -- Template LinearVelocity mover for primary movement function
local AlignOrientation = script.AlignOrientation -- Template AlignOrientation mover for smooth character rotation

local function switch(value) -- Mimics the switch control structure from other languages, it executes passed functions "cases" matching the passed expression "value", if none match it will call "Default"
	return function(cases: { [any | "Default"]: () -> () }) -- Closure for syntactic sugar - example shown on line 47
		local case = cases[value] or cases["Default"] -- Index cases for the proper case
		if case then -- If a case was found (Case isn't equal to nil)
			case() -- Call case
		end
	end
end

--[[
switch(value)
{
	[1] = func,
	[2] = func,
	[3] = func,

	[Default] = func,
}
]]

local function get_tracks(animator: Animator, fly_animations) -- Creates animation tracks, for the given animator, from the given animation objects
	return { -- Return a tracks table to the caller
		idle = (fly_animations.Idle and animator:LoadAnimation(fly_animations.Idle)), -- Create a track for the idle animation, if there is one

		forward = (fly_animations.Forward and animator:LoadAnimation(fly_animations.Forward)), -- Create a track for the forward animation, if there is one
		backward = (fly_animations.Backward and animator:LoadAnimation(fly_animations.Backward)), -- Create a track for the backward animation, if there is one

		left_strafing = (fly_animations.LeftStrafing and animator:LoadAnimation(fly_animations.LeftStrafing)), -- Create a track for the left strafing animation, if there is one
		right_strafing = (fly_animations.RightStrafing and animator:LoadAnimation(fly_animations.RightStrafing)), -- Create a track for the right strafing animation, if there is one

		left_diagonal_forward = (fly_animations.LeftDiagonalForward and animator:LoadAnimation(
			fly_animations.LeftDiagonalForward
		)), -- Create a track for the left diagonal forward animation, if there is one
		right_diagonal_forward = (fly_animations.RightDiagonalForward and animator:LoadAnimation(
			fly_animations.RightDiagonalForward
		)), -- Create a track for the right diagonal forward animation, if there is one

		left_diagonal_backward = (fly_animations.LeftDiagonalBackward and animator:LoadAnimation(
			fly_animations.LeftDiagonalBackward
		)), -- Create a track for the left diagonal backward animation, if there is one
		right_diagonal_backward = (fly_animations.RightDiagonalBackward and animator:LoadAnimation(
			fly_animations.RightDiagonalBackward
		)), -- Create a track for the right diagonal backward animation, if there is one
	}
end

local function get_vectordirection() -- Check if control keys are already held down and calculate the vector direction
	local direction = Vector3.zero -- Empty vector

	if UserInputService:IsKeyDown(KeyCode.W) then -- Check for key "W"
		direction += Vector3.new(0, 0, 1) -- Increment Vector3.Z
	end
	if UserInputService:IsKeyDown(KeyCode.A) then -- Check for key "A"
		direction += Vector3.new(-1, 0, 0) -- Decrement Vector3.X
	end
	if UserInputService:IsKeyDown(KeyCode.S) then -- Check for key "S"
		direction += Vector3.new(0, 0, -1) -- Decrement Vector3.Z
	end
	if UserInputService:IsKeyDown(KeyCode.D) then -- Check for key "D"
		direction += Vector3.new(1, 0, 0) -- Increment Vector3.X
	end

	if UserInputService:IsKeyDown(KeyCode.Space) then -- Check for key "Space"
		direction += Vector3.new(0, 1, 0) -- Increment Vector3.Y
	end
	if UserInputService:IsKeyDown(KeyCode.LeftShift) then -- Check for key "Left Shift"
		direction += Vector3.new(0, -1, 0) -- Decrement Vector3.Y
	end

	return direction -- Return proper direction to the caller
end

local function is_colliding(character, move_direction) -- Check whether there is an object ahead in the direction the player is moving
	local root_part = character.PrimaryPart -- Reference to HumanoidRootPart

	local size = root_part.Size -- Size used for an accurate raycast "hitbox" (Accurate size of the grid)

	local up_vector = root_part.CFrame.UpVector -- Root part CFrame's YVector component
	local right_vector = root_part.CFrame.RightVector -- Root part CFrame's XVector component
	local look_vector = root_part.CFrame.LookVector -- Root part CFrame's -ZVector component

	local abs = math.abs -- Reference to math.abs to remove boilerplace code
	local ceil = math.ceil -- Reference to math.ceil to remove boilerplace code

	local face_size1, face_size2 -- Declared variables for 2D Cartesian coordinates determining the range of the raycast grid, they get initialized below
	if abs(move_direction:Dot(look_vector)) > 0.9 then -- Check if the current move direction is similar enough to look_vector
		face_size1, face_size2 = size.Y, size.X -- Use the front or back face size
	elseif abs(move_direction:Dot(up_vector)) > 0.9 then -- Check if the current move direction is similar enough to up_vector
		face_size1, face_size2 = size.X, size.Z -- Use the top or bottom face size
	else -- move_direction is mostly perpendicular to the look_vector normal
		face_size1, face_size2 = size.Y, size.Z -- Use the side faces' size
	end

	local rays_count1 = ceil(face_size1 / RAYCAST_SPACING) -- How many rows of raycasts should be sent
	local rays_count2 = ceil(face_size2 / RAYCAST_SPACING) -- How many columns of raycasts should be sent

	local params = RaycastParams.new() -- Construct a RaycastParams object
	params.IgnoreWater = true -- Set IgnoreWater property to true - we don't want the character to freeze just above water
	params.FilterType = Enum.RaycastFilterType.Exclude -- Set FilterType property to RaycastFilterType.Exclude - we only need to ignore the character
	params.FilterDescendantsInstances = { character } -- Set FilterDescendantsInstances to {[1] = character} Ignore LocalPlayer.Character assembly
	params.RespectCanCollide = true -- Set RespectCanCollide to true - Sanitize with BasePart.CanCollide instead of BasePart.CanQuery

	local center_origin = root_part.Position + (move_direction * (size.Z / 2)) -- Get a base origin offsetted by a small vector directed to move_direction
	local direction = (move_direction * RAYCAST_DISTANCE) -- move_direction with a specified length

	-- Shoot a grid of raycasts from the nearest face
	for i = 0, rays_count1, 1 do -- Control structure counting from 0 to rays_count1 by 1 and executing the block of code below (rays_count1 - 0) amount of times
		for j = 0, rays_count2, 1 do -- Control structure counting from 0 to rays_count2 by 1 and executing the block of code below (rays_count2 - 0) amount of times
			local offset1 = (i - rays_count1 / 2) * RAYCAST_SPACING * right_vector -- Calculates the X offset from center_origin
			local offset2 = (j - rays_count2 / 2) * RAYCAST_SPACING * up_vector -- Calculates the Y offset from center_origin

			local origin = (center_origin + offset1 + offset2) -- Calculate origin

			if workspace:Raycast(origin, direction, params) then -- Raycast from origin to origin+direction and check for a intersection
				return true -- Intersection found, return true and cancel the loop
			end
		end
	end

	return false -- No intersection found, return false to the caller
end

local FlightController = {} -- Declare and initialize the table for the class
FlightController.__index = FlightController -- __index metamethod pointing to itself to reuse methods for objects

function FlightController:_addMovers() -- Add a private init method, to clone the necessary body movers which are used for flying
	local character = self._character -- Reference of a reference to LocalPlayer.Character

	local attachment = Instance.new("Attachment") -- Create an attachment
	attachment.Parent = character.PrimaryPart -- Parent it to Character.HumanoidRootPart

	local linear_velocity = LinearVelocity:Clone() -- Clone the template LinearVelocity object
	linear_velocity.Parent = character -- Parent it to Character.HumanoidRootPart
	linear_velocity.Attachment0 = attachment -- Link it to to attachment

	local align_orientation = AlignOrientation:Clone() -- Clone the template AlignOrientation object
	align_orientation.Parent = character -- Parent it to Character.HumanoidRootPart
	align_orientation.Attachment0 = attachment -- Link it to to attachment

	self._Maid.linear_velocity = linear_velocity -- Task self._Maid to clean linear_velocity once it's not needed anymore
	self._Maid.align_orientation = align_orientation -- Task self._Maid to clean align_orientation once it's not needed anymore

	self._Maid:GiveTask(attachment) -- Task self._Maid to clean attachment once it's not needed anymore
end

function FlightController:_initFrameUpdate() -- Add a private method, that creates and returns a RBXScriptConnection handling the stepping of the update function for body movers
	local function step(delta_time) -- Declare and initialize the update function for body movers
		local speed = self.Speed -- Reference to the flight speed property
		local vector_direction = self.VectorDirection -- Reference to the current direction the player wants to fly to

		local camera_cframe = CurrentCamera.CFrame -- Reference to the current CFrame of the player's camera

		local look_vector = camera_cframe.LookVector -- CurrentCamera CFrame's -ZVector
		local right_vector = camera_cframe.RightVector -- CurrentCamera CFrame's XVector
		local up_vector = camera_cframe.UpVector -- CurrentCamera CFrame's YVector

		local move_direction = (right_vector * vector_direction.X)
			+ (up_vector * vector_direction.Y)
			+ (look_vector * vector_direction.Z) -- Declare a variable and calculate the vector direction relative to the camera

		local final_velocity = Vector3.zero -- Declare the final velocity which will be given to self._Maid.linear_velocity and set it to an empty Vector3
		if not is_colliding(self._character, move_direction) then -- Call is_colliding() to find out whether the player isn't flying towards an obstacle
			final_velocity = (move_direction * speed) -- No obstacle in front of the player, assign a real final_velocity
		end

		self._Maid.linear_velocity.VectorVelocity = final_velocity -- Assign final_velocity to self._Maid.linear_velocity.VectorVelocity
		self._Maid.align_orientation.CFrame = camera_cframe.Rotation -- Assign camera_cframe without a translation to self._Maid.align_orientation.CFrame
	end
	return RunService.PreSimulation:Connect(step) -- Connect step to the PreSimulation phase of the task scheduler and return the RBXScriptConnection to the caller
end

function FlightController:_stopAnimation() -- Add a private method, that cancels all running FlyAnimations tracks
	for _, track in self._tracks do -- Iterate through self._tracks (Table passed by get_tracks())
		if not track then -- If the value of the current pair is nil
			continue -- Break this iteration and continue with the next one
		end
		track:Stop() -- Stop the track
	end
end

function FlightController:_updateAnimation() -- Add a private method, that updates the running animation
	local vector_direction = self.VectorDirection -- Reference to self.VectorDirection
	local tracks = self._tracks -- Reference to self._tracks

	self:_stopAnimation() -- Call FlightController:_stopAnimation() to cancel the currently running animation

	local function play(track) -- Declare and initialize a function, that returns a closure function that plays the passed track
		return function() -- Return a closure function to the caller
			if not track then -- If the track is nil
				return -- Terminate the execution of this function and return to the caller
			end
			track:Play() -- Play the track

			return true -- Return true to the caller
		end
	end

	switch(vector_direction)({
		[Vector3.new(0, 0, 1)] = play(tracks.forward), -- If vector_direction is equivalent to Vector3 [0, 0, 1], then call play() to play tracks.forward
		[Vector3.new(0, 0, -1)] = play(tracks.backward), -- If vector_direction is equivalent to Vector3 [0, 0, -1], then call play() to play tracks.backward
		[Vector3.new(-1, 0, 0)] = play(tracks.left_strafing), -- If vector_direction is equivalent to Vector3 [-1, 0, 0], then call play() to play tracks.left_strafing
		[Vector3.new(1, 0, 0)] = play(tracks.right_strafing), -- If vector_direction is equivalent to Vector3 [1, 0, 0], then call play() to play tracks.right_strafing
		[Vector3.new(-1, 0, 1)] = play(tracks.left_diagonal_forward), -- If vector_direction is equivalent to Vector3 [-1, 0, 1], then call play() to play tracks.left_diagonal_forward
		[Vector3.new(1, 0, 1)] = play(tracks.right_diagonal_forward), -- If vector_direction is equivalent to Vector3 [1, 0, 1], then call play() to play tracks.right_diagonal_forward
		[Vector3.new(-1, 0, -1)] = play(tracks.left_diagonal_backward), -- If vector_direction is equivalent to Vector3 [-1, 0, -1], then call play() to play tracks.left_diagonal_backward
		[Vector3.new(1, 0, -1)] = play(tracks.right_diagonal_backward), -- If vector_direction is equivalent to Vector3 [1, 0, -1], then call play() to play tracks.right_diagonal_backward

		default = play(tracks.idle), -- If vector_direction doesn't match any one of the cases above, then call play() to play tracks.idle
	}) -- Call switch() to mimic the switch statement, and play the track whose case value matches the vector_direction
end

function FlightController:_bindActions() -- Add a private method, that binds movement keys to ContextActionService actions
	local function closure(direction) -- Declare and initialize a function, that returns a closure function that updates the vector_direction with the passed direction
		return function(action_name, input_state) -- Return a closure function to the caller
			if input_state == Enum.UserInputState.Begin then -- If input_state is equivalent to UserInputState.Begin
				self.VectorDirection += direction -- Add direction to self.VectorDirection, player wants to fly to that direction
			elseif input_state == Enum.UserInputState.End or input_state == Enum.UserInputState.Cancel then -- If input_state is equivalent to UserInputState.End or UserInputState.Cancel
				self.VectorDirection -= direction -- Subtract direction from self.VectorDirection, player doesn't want to fly to that direction anymore
			end

			self:_updateAnimation() -- Call self:_updateAnimation to update the running animation after the change
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

	self._humanoid.PlatformStand = true -- Disable some humanoid functionality
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

-- Demo
local speed = 64
local fly_animations = {
	Forward = script.Animations.Front,
	Backward = script.Animations.Back,

	LeftStrafing = script.Animations.Left,
	RightStrafing = script.Animations.Right,

	LeftDiagonalForward = script.Animations.LeftFront,
	RightDiagonalForward = script.Animations.RightFront,

	LeftDiagonalBackward = script.Animations.LeftBack,
	RightDiagonalBackward = script.Animations.RightBack,
}

local curr_controller
ContextActionService:BindAction("__test__", function(_, input_state: Enum.UserInputState)
	local uis = Enum.UserInputState

	if input_state == uis.Begin then
		if not curr_controller then
			curr_controller = FlightController.new(speed, fly_animations)
		end
	elseif input_state == uis.End or input_state == uis.Cancel then
		curr_controller:Destroy()
		curr_controller = nil
	end
end, false, Enum.UserInputType.MouseButton1)

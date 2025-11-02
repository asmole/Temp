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

-- (The package is a submodule linked to a private repository, if this is an issue and you want to see the source just ask)
local Maid = require(ReplicatedStorage.LLoPkgs.Maid.Maid) -- Reference to a Maid package, it was developed by me, but the functionality is virtually the same

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

	ContextActionService:BindAction(ACTION_KEYS.W, closure(Vector3.new(0, 0, 1)), false, KeyCode.W) -- Bind Keycode.W to Vector3 direction [0, 0, 1]
	ContextActionService:BindAction(ACTION_KEYS.A, closure(Vector3.new(-1, 0, 0)), false, KeyCode.A) -- Bind Keycode.A to Vector3 direction [-1, 0, 0]
	ContextActionService:BindAction(ACTION_KEYS.S, closure(Vector3.new(0, 0, -1)), false, KeyCode.S) -- Bind Keycode.S to Vector3 direction [0, 0, -1]
	ContextActionService:BindAction(ACTION_KEYS.D, closure(Vector3.new(1, 0, 0)), false, KeyCode.D) -- Bind Keycode.D to Vector3 direction [1, 0, 0]

	ContextActionService:BindAction(ACTION_KEYS.SPACE, closure(Vector3.new(0, 1, 0)), false, KeyCode.Space) -- Bind Keycode.Space to Vector3 direction [0, 1, 0]
	ContextActionService:BindAction(ACTION_KEYS.LSHIFT, closure(Vector3.new(0, -1, 0)), false, KeyCode.LeftShift) -- Bind Keycode.leftShift to Vector3 direction [0, -1, 0]
end
function FlightController:_unbindActions() -- Add a private method, that unbinds movement keys from ContextActionService actions
	ContextActionService:UnbindAction(ACTION_KEYS.W) -- Unbinds ACTION_KEYS.W from Keycode.W
	ContextActionService:UnbindAction(ACTION_KEYS.A) -- Unbinds ACTION_KEYS.A from Keycode.A
	ContextActionService:UnbindAction(ACTION_KEYS.S) -- Unbinds ACTION_KEYS.S from Keycode.S
	ContextActionService:UnbindAction(ACTION_KEYS.D) -- Unbinds ACTION_KEYS.D from Keycode.D

	ContextActionService:UnbindAction(ACTION_KEYS.SPACE) -- Unbinds ACTION_KEYS.SPACE from Keycode.Space
	ContextActionService:UnbindAction(ACTION_KEYS.LSHIFT) -- Unbinds ACTION_KEYS.LSHIFT from Keycode.LeftShift
end

function FlightController:_init() -- Add a private method, that initializes the functionality of this current instance
	self:_bindActions() -- Calls FlightController:_bindActions() to bind keys to movement directions
	self:_addMovers() -- Calls FlightController:_addMovers() to create the necessary body movers
	self:_updateAnimation() -- Calls FlightController:_updateAnimation() to update the animations

	self._humanoid.PlatformStand = true -- Sets Humanoid.PlatformStand to true to disable some humanoid functionality
	RobloxControls:Disable() -- Calls RobloxControls:Disable() to disable roblox character movement

	local function on_destroy() -- Declares and initializes a function that calls after Maid:Destroy() to disable functionality and enable roblox optimizations
		self:_unbindActions() -- Calls FlightController:_unbindActions() to unbind keys from movement directions
		self:_stopAnimation() -- Calls FlightController:_stopAnimation() to cancel all running tracks

		self._humanoid.PlatformStand = false -- Sets Humanoid.PlatformStand to false to enable humanoid functionality
		RobloxControls:Enable() -- Calls RobloxControls:Enable() to give movement control back to roblox
	end

	self._Maid:GiveTask(self:_initFrameUpdate()) -- Tasks self._Maid to disconnect the RBXScriptConnection returned by FlightController:_initFrameUpdate(), when it is no longer needed
	self._Maid:GiveTask(on_destroy) -- Tasks self._Maid to call on_destroy() after Maid:DoCleaning() or Maid:Destroy() gets called
end

function FlightController.new(speed, fly_animations) -- Add a constructor to FlightController, that creates properties and initializes functionality
	local self = setmetatable({}, FlightController) -- Create the table which will be the object and link it to a metatable

	self.Speed = speed -- Initializes the property Speed and assigns the argument speed to it
	self.VectorDirection = get_vectordirection() -- Initializes the property VectorDirection and assigns a Vector3 returned by get_vectordirection() to it

	self._Maid = Maid.new() -- Initializes the private property _Maid and assigns a new Maid object to it

	self._character = LocalPlayer.Character -- Initializes the private property _character and assigns a reference to the LocalPlayer's character to it
	self._humanoid = LocalPlayer.Character.Humanoid -- Initializes the private property _humanoid and assigns a reference to the character's humanoid to it

	self._tracks = get_tracks(self._humanoid.Animator, fly_animations) -- Initializes a private property _tracks and assigns a value returned by get_tracks() to it

	self:_init() -- Calls self:_init() to initialize the functionality of this current instance

	return self -- Returns the instance to the caller
end

function FlightController:Destroy() -- Add a deconstructor to FlightController, that disables all functionality
	self._Maid:Destroy() -- Call Maid:Destroy() to clean all MaidTasks assigned
end

-- Demo
local speed = 64 -- Speed used in the demo place
local fly_animations = {
	Forward = script.Animations.Front, -- A pair for the forward flight animation
	Backward = script.Animations.Back, -- A pair for the backward flight animation

	LeftStrafing = script.Animations.Left, -- A pair for the left strafing flight animation
	RightStrafing = script.Animations.Right, -- A pair for the right strafing flight animation

	LeftDiagonalForward = script.Animations.LeftFront, -- A pair for the left diagonal forward flight animation
	RightDiagonalForward = script.Animations.RightFront, -- A pair for the right diagonal forward flight animation

	LeftDiagonalBackward = script.Animations.LeftBack, -- A pair for the left diagonal backward flight animation
	RightDiagonalBackward = script.Animations.RightBack, -- A pair for the right diagonal backward flight animation
} -- Animations used in the demo place

local curr_controller -- Declare a variable that stores the currently running FlightController instance
ContextActionService:BindAction("__test__", function(_, input_state: Enum.UserInputState) -- Bind LMB to __test__
	local uis = Enum.UserInputState -- Reference to Enum.UserInputState to remote boilerplate code

	if input_state == uis.Begin then -- If the player started holding the LMB
		if not curr_controller then -- If there isn't a running FlightController currently
			curr_controller = FlightController.new(speed, fly_animations) -- Build a new FlightController instance and assign it to curr_controller
		end
	elseif input_state == uis.End or input_state == uis.Cancel then -- If the player stopped holding the LMB or roblox stopped registering it
		curr_controller:Destroy() -- Call FlightController:Destroy() to deconstruct the running FlightController instance
		curr_controller = nil -- Assign nil to curr_controller
	end
end, false, Enum.UserInputType.MouseButton1)

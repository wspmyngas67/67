local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local localPlayer = Players.LocalPlayer
local gui = localPlayer:WaitForChild("PlayerGui")
local Config = {
    MinDiveDistance = 5.5,
    CenterDeadzone = 2.8,
    MinBallSpeed = 2.0,
    CooldownTime = 0.8,
    InvertDirections = false,
    GoalCheckTolerance = 25,
    Gravity = Vector3.new(0, -110, 0),
    DragCoeff = 0.00017,
    MagnusCoeff = 0.016,
    MagnusMax = 50,
    SpinDecay = 0.995,
    BounceY = 0.60,
    BounceXZ = 0.60,
    GroundY = 0.5,
    SimTime = 2.5,
    ShowTrajectory = true,
    LineColor = Color3.fromRGB(255, 40, 40),
    LineTransparency = 0.2
}
local lastDiveTime = 0
local beamAttachment0, beamAttachment1, trajectoryBeam
if Config.ShowTrajectory then
    local folder = Instance.new("Folder")
    folder.Name = "predictor"
    folder.Parent = workspace
    local partA = Instance.new("Part")
    partA.Anchored = true
    partA.CanCollide = false
    partA.Transparency = 1
    partA.Size = Vector3.new(0.1, 0.1, 0.1)
    partA.Parent = folder
    local partB = Instance.new("Part")
    partB.Anchored = true
    partB.CanCollide = false
    partB.Transparency = 1
    partB.Size = Vector3.new(0.1, 0.1, 0.1)
    partB.Parent = folder
    beamAttachment0 = Instance.new("Attachment", partA)
    beamAttachment1 = Instance.new("Attachment", partB)
    trajectoryBeam = Instance.new("Beam")
    trajectoryBeam.Attachment0 = beamAttachment0
    trajectoryBeam.Attachment1 = beamAttachment1
    trajectoryBeam.Color = ColorSequence.new(Config.LineColor)
    trajectoryBeam.Width0 = 0.5
    trajectoryBeam.Width1 = 0.8
    trajectoryBeam.FaceCamera = true
    trajectoryBeam.Transparency = NumberSequence.new(Config.LineTransparency)
    trajectoryBeam.Parent = folder
end
local function getDiveButtons()
    local keeperControls = gui:FindFirstChild("KeeperControlsUI")
    if not keeperControls then return nil, nil end
    local buttonRoot = keeperControls:FindFirstChild("ButtonRoot")
    if not buttonRoot then return nil, nil end
    return buttonRoot:FindFirstChild("KeeperDivePad_left"), buttonRoot:FindFirstChild("KeeperDivePad_right")
end
local function getGoalBarriers()
    local field = workspace:FindFirstChild("Field")
    if not field then return nil, nil end
    
    return field:FindFirstChild("GoalSensorNorthPlayerBarrier"), field:FindFirstChild("GoalSensorSouthPlayerBarrier")
end
local function triggerButtonInstant(button)
    if not button or not button.Visible then return end
    if firesignal then
        task.spawn(function()
            for i = 1, 3 do
                pcall(function() firesignal(button.MouseButton1Down) end)
                pcall(function() firesignal(button.Activated) end)
                pcall(function() firesignal(button.MouseButton1Click) end)
                pcall(function() firesignal(button.MouseButton1Up) end)
                task.wait()
            end
        end)
    else
        warn("shitty executor")
    end
end
local function updateTrajectoryLine(startPos: Vector3, endPos: Vector3, visible: boolean)
    if not Config.ShowTrajectory or not trajectoryBeam then return end
    trajectoryBeam.Enabled = visible
    if visible then
        beamAttachment0.Parent.Position = startPos
        beamAttachment1.Parent.Position = endPos
    end
end
local function simulateBallTrajectory(ball: BasePart)
    local pos = ball.Position
    local vel = ball.AssemblyLinearVelocity
    local omega = ball.AssemblyAngularVelocity
    local mass = ball.AssemblyMass
    local extraForce = Vector3.zero
    for _, child in ball:GetChildren() do
        if child:IsA("BodyForce") then
            extraForce = extraForce + child.Force
        end
    end
    local aExtra = mass > 0 and (extraForce / mass) or Vector3.zero
    local dt = (1/60) * 0.48
    local steps = math.floor(Config.SimTime / dt)
    local points = {}
    for i = 1, steps do
        local aGrav = Config.Gravity
        local aDrag = Vector3.zero
        if vel.Magnitude > 0.001 then
            aDrag = -vel.Unit * (vel.Magnitude ^ 2) * Config.DragCoeff
    end
        local cross = omega:Cross(vel)
        local aMagnus = cross * Config.MagnusCoeff
        if aMagnus.Magnitude > Config.MagnusMax then
            aMagnus = aMagnus.Unit * Config.MagnusMax
        end
        aExtra = aExtra * 0.984
        local accel = aGrav + aDrag + aMagnus + aExtra
        vel = vel + accel * dt
        pos = pos + vel * dt
        omega = omega * Config.SpinDecay
        if pos.Y < Config.GroundY then
            pos = Vector3.new(pos.X, Config.GroundY, pos.Z)
            vel = Vector3.new(
                vel.X * Config.BounceXZ,
                -vel.Y * Config.BounceY,
                vel.Z * Config.BounceXZ
            )
        end
        table.insert(points, pos)
        if vel.Magnitude < 2 and pos.Y <= Config.GroundY + 0.1 then
            break
        end
    end
    return points
end
local function getBestTargetPoint(trajectoryPoints, playerPos)
    local closestPoint = trajectoryPoints[1]
    local minDistance = math.huge
    for _, point in ipairs(trajectoryPoints) do
        local dist = (Vector3.new(point.X, 0, point.Z) - Vector3.new(playerPos.X, 0, playerPos.Z)).Magnitude
        if dist < minDistance then
            minDistance = dist
            closestPoint = point
        end
    end
    return closestPoint
end
local function isTrajectoryHeadingToGoal(trajectoryPoints)
    local northBarrier, southBarrier = getGoalBarriers()
    local goalPositions = {}
    if northBarrier and northBarrier:IsA("BasePart") then table.insert(goalPositions, northBarrier.Position) end
    if southBarrier and southBarrier:IsA("BasePart") then table.insert(goalPositions, southBarrier.Position) end
    if #goalPositions == 0 then return true end
    for _, point in ipairs(trajectoryPoints) do
        for _, goalPos in ipairs(goalPositions) do
            local dist = (Vector3.new(point.X, 0, point.Z) - Vector3.new(goalPos.X, 0, goalPos.Z)).Magnitude
            if dist <= Config.GoalCheckTolerance then
                return true
            end
        end
    end
    return false
end
local function checkAndDive(ball: BasePart)
    local character = localPlayer.Character
    if not character then 
        updateTrajectoryLine(Vector3.zero, Vector3.zero, false)
        return 
    end
    local hrp = character:FindFirstChild("HumanoidRootPart")
    if not hrp then 
        updateTrajectoryLine(Vector3.zero, Vector3.zero, false)
        return 
    end
    local playerPos = hrp.Position
    local ballPos = ball.Position
    local rawDistance = (ballPos - playerPos).Magnitude
    if rawDistance < Config.MinDiveDistance then
        updateTrajectoryLine(Vector3.zero, Vector3.zero, false)
        return
    end
    local velocity = ball.AssemblyLinearVelocity
    if velocity.Magnitude < Config.MinBallSpeed then
        updateTrajectoryLine(Vector3.zero, Vector3.zero, false)
        return
    end
    local dirToBallFromPlayer = (ballPos - playerPos).Unit
    local ballMoveDir = velocity.Unit
    if ballMoveDir:Dot(dirToBallFromPlayer) > 0.4 then
        updateTrajectoryLine(Vector3.zero, Vector3.zero, false)
        return
    end
    local trajectoryPoints = simulateBallTrajectory(ball)
    if #trajectoryPoints == 0 then return end
    updateTrajectoryLine(ballPos, trajectoryPoints[#trajectoryPoints], true)
    if not isTrajectoryHeadingToGoal(trajectoryPoints) then
        return
    end
    if os.clock() - lastDiveTime < Config.CooldownTime then return end
    local targetBallPos = getBestTargetPoint(trajectoryPoints, playerPos)
    local localTargetPoint = hrp.CFrame:PointToObjectSpace(targetBallPos)
    if localTargetPoint.Z > 1 then
        return
    end
    if math.abs(localTargetPoint.X) < Config.CenterDeadzone then
        return
    end
    local isRight = localTargetPoint.X > 0
    if Config.InvertDirections then
        isRight = not isRight
    end
    local leftButton, rightButton = getDiveButtons()
    if isRight then
        if rightButton then
            triggerButtonInstant(rightButton)
            lastDiveTime = os.clock()
        end
    else
        if leftButton then
            triggerButtonInstant(leftButton)
            lastDiveTime = os.clock()
        end
    end
end
RunService.RenderStepped:Connect(function()
    local matchBall = workspace:FindFirstChild("MatchBall")
    if matchBall and matchBall:IsA("BasePart") then
        checkAndDive(matchBall)
    else
        updateTrajectoryLine(Vector3.zero, Vector3.zero, false)
    end
end)

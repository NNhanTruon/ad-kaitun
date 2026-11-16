--[[ =====================================================================
  AD KAITUN v1 — Anime Dimensions Simulator Auto-Farm (F2P)
  Build trên reverse của client thật:
   - Remote:  ReplicatedStorage.RemoteEvents.MainRemoteEvent   :FireServer(cmd, ...)
              ReplicatedStorage.RemoteFunctions.MainRemoteFunction :InvokeServer(cmd, ...)
   - Combat:  FireServer("UseSkill", {hrpCFrame = CFrame}, slot)  / ..., "BasicAttack"
   - Queue:   InvokeServer("QueuePlayer", mapName, difficulty, false)
   - MapInfo: require(ReplicatedStorage.Modules.settings).MapInfo  (live, auto cập nhật)
   - Stats:   ReplicatedStorage[<player>.."StatDisplay"].<Stat>.Value
  Không hardcode map/level — pick map cao nhất mà account level cho phép.
===================================================================== ]]

-----------------------------------------------------------------------
-- Services & bootstrap
-----------------------------------------------------------------------
local Players = game:GetService("Players")
local RS      = game:GetService("ReplicatedStorage")
local lp      = Players.LocalPlayer

local env = (getgenv and getgenv()) or _G
if env.AD_Kaitun and env.AD_Kaitun.Stop then
    pcall(function() env.AD_Kaitun.Stop() end)
    task.wait(0.2)
end

local K = { Version = "1.0" }
env.AD_Kaitun = K

-----------------------------------------------------------------------
-- Config (sửa trong UI hoặc ở đây)
-----------------------------------------------------------------------
K.Config = {
    AutoFarm      = true,             -- master switch
    AutoRetry     = true,             -- tự bấm RetryDungeon khi hết run
    AutoRevive    = true,             -- tự revive khi chết
    AutoDaily     = true,             -- claim daily quest / online reward / battlepass
    AutoEquip     = true,             -- tự equip character nếu trống (costume tắt: server reject)
    AutoRaid      = true,             -- raid phase khi level >= 15
    AutoInfinite  = true,             -- Infinite Mode khi level >= 20 (solo)
    RaidEvery     = 3,                -- cứ 3 lần queue dimension thì làm 1 raid
    PreferDiff    = {"Nightmare", "Hard", "Easy", "Infinite"},
    AttackDelay   = 0.34,             -- nhịp BasicAttack (có jitter)
    SkillDelay    = 1.15,             -- nhịp mỗi skill slot
    QueueTimeout  = 75,               -- giây chờ queue trước khi cancel + đổi map
    IdleRetry     = 45,               -- giây không kill enemy gì thì Retry
    BlacklistTime = 300,              -- map queue fail bị cấm (giây)
    -- Auto shop / loadout / cards
    AutoBuyChar   = true,             -- auto mua nhan vat manh nhat mua duoc (gem)
    AutoSlots     = true,             -- auto equip main + 2 assist
    AutoCards     = true,             -- auto equip card manh nhat
    AutoDeleteLow = true,             -- auto xoa card Common/Uncommon/Rare
    KeepRarity    = "Epic",           -- giu lai tu rarity nay tro len (Epic/Legendary/Mythic/Divine)
    ShopInterval  = 300,              -- giay giua moi lan quet shop
    SlotInterval  = 120,              -- giay giua moi lan chinh loadout
    CardInterval  = 120,              -- giay giua moi lan chinh card
    -- Fast entry / story sticky / white screen
    FastEntry     = true,             -- join nhanh 5-10s: CreateRoom + startGame truoc, QueuePlayer du phong
    StorySticky   = true,             -- story: replay lien tuc, chi back lobby khi duoc len map/diff
    RetryCooldown = 12,               -- giay toi thieu giua 2 lan RetryDungeon
    WhiteScreen   = false,            -- bat l: tat render 3D (man hinh trang)
}

-----------------------------------------------------------------------
-- State
-----------------------------------------------------------------------
K.Running      = false
K.Gui          = nil
K.Logs         = {}
K.SkillCD      = {}
K.BasicCD      = 0
K.AttackIndex  = 0
K.Runs         = 0
K.DailyClaims  = 0
K.RaidDebt     = 0
K.Ban          = {}          -- [mapName] = tick hết hạn
K.QueueActive  = false
K.QueueStart   = 0
K.QueueMap     = ""
K.QueueDiff    = ""
K.StartTime    = tick()
K.LastDaily    = 0
K.LastKill     = 0
K.Kills        = 0
K.LastShop   = 0
K.LastSlots  = 0
K.LastCards  = 0
K.ShopBuys   = 0
K.CardDeleted = 0
K.TargetMap   = ""
K.TargetDiff  = ""
K.Entering    = false
K.WhiteScreen = false
K.LastRetry   = 0
K.CostumeTried = false
K.LastPhase    = ""
K.Threads      = {}

-----------------------------------------------------------------------
-- Helpers
-----------------------------------------------------------------------
local function now() return tick() end

local function stat(name)
    local folder = RS:FindFirstChild(lp.Name .. "StatDisplay")
    if not folder then return nil end
    local v = folder:FindFirstChild(name)
    return v and v.Value or nil
end

local function getSettings()
    local ok, s = pcall(function() return require(RS.Modules.settings) end)
    return ok and s or {}
end

local function getUtility()
    local ok, u = pcall(function() return require(RS.Modules.Utility) end)
    return ok and u or nil
end

local function srvType()
    local u = getUtility()
    if not u then return "Unknown" end
    local ok, t = pcall(function() return u.getServerType() end)
    return ok and t or "Unknown"
end

local function fire(cmd, ...)
    local args = { ... }
    local ev = RS:FindFirstChild("RemoteEvents")
    ev = ev and ev:FindFirstChild("MainRemoteEvent")
    if not ev then return nil end
    return pcall(function() ev:FireServer(cmd, table.unpack(args)) end)
end

local function invoke(cmd, ...)
    local args = { ... }
    local rf = RS:FindFirstChild("RemoteFunctions")
    rf = rf and rf:FindFirstChild("MainRemoteFunction")
    if not rf then return nil end
    local ok, res = pcall(function() return rf:InvokeServer(cmd, table.unpack(args)) end)
    return ok and res or nil
end

function K.Log(msg)
    table.insert(K.Logs, 1, string.format("[%s] %s", os.date("%H:%M:%S"), tostring(msg)))
    while #K.Logs > 6 do table.remove(K.Logs) end
    pcall(function() print("[AD_Kaitun] " .. tostring(msg)) end)
end

local function humanTime(s)
    s = math.max(0, math.floor(s))
    return string.format("%d:%02d:%02d", s // 3600, (s % 3600) // 60, s % 60)
end

local function jitter(base)
    return base * (0.85 + math.random() * 0.3)
end

-----------------------------------------------------------------------
-- Map picker — live MapInfo, chọn map khó nhất mà level cho phép
-----------------------------------------------------------------------
local SPECIAL = {
    ["Time Challenge"] = true, ["Boss Rush"] = true,
    ["Daily Raid Challenge"] = true, ["Infinite Mode"] = true,
}

function K.PickMap()
    local lvl = stat("Level") or 1
    local bestMap, bestDiff, bestReq = nil, nil, -1
    for _, m in pairs(getSettings().MapInfo or {}) do
        if type(m) == "table" and m.mapName and not m.isRaid and not m.limited
           and not m.endTime and not m.excludeFromList and not SPECIAL[m.mapName]
           and (not m.minimumPlayersToStart or m.minimumPlayersToStart <= 1)
           and not (K.Ban[m.mapName] and K.Ban[m.mapName] > now()) then
            for _, dn in ipairs(K.Config.PreferDiff) do
                local d = m.difficulties and m.difficulties[dn]
                local req = d and d.levelReq
                if req and req <= lvl and req > bestReq then
                    bestMap, bestDiff, bestReq = m.mapName, dn, req
                    break
                end
            end
        end
    end
    if bestMap then return bestMap, bestDiff end
    -- fallback: Time Challenge lúc nào cũng mở (level 1)
    return "Time Challenge", "Easy"
end
function K.GateOf(map, diff)
    if not map or not diff then return -1 end
    local m = (getSettings().MapInfo or {})[map]
    if not m then return -1 end
    local d = m.difficulties and m.difficulties[diff]
    return (d and d.levelReq) or -1
end

-----------------------------------------------------------------------
-- Vao dungeon (async): clear party -> CreateRoom -> poll -> QueuePlayer du phong
-- Server hay tra nil/Fail gia; chi tin srvType()=="Game"
-----------------------------------------------------------------------
function K.EnterDungeon(map, diff)
    if not map or map == "" then return end
    if K.Entering then return end
    K.Entering = true
    K.QueueActive, K.QueueStart = true, now()
    K.QueueMap, K.QueueDiff = map, diff
    K.TargetMap, K.TargetDiff = map, diff   -- story: giu target, khong doi khi chua du dieu kien
    task.spawn(function()
        local entered = false
        local t0 = now()
        local function pollGame(sec)
            for i = 1, sec * 2 do
                task.wait(0.5)
                if srvType() == "Game" then return true end
            end
            return false
        end
        -- 1) xoa state party/queue cu
        pcall(function() fire("RemovePlayerFromParty") end)
        pcall(function() invoke("RemovePlayerFromQueue") end)
        task.wait(0.4)
        -- 2) FAST PATH: CreateRoom + startGame (solo room, khong cho matchmaking)
        local res = invoke("CreateRoom", { MapName = map, Difficulty = diff })
        local st = type(res) == "table" and tostring(res.status) or "Sent"
        K.Log(("CreateRoom %s [%s] -> %s"):format(map, diff, st))
        task.wait(0.3)
        pcall(function() require(lp.PlayerGui.Modules.RoomModule).startGame() end)
        entered = pollGame(6)   -- ~6s la vao duoc
        -- 3) Fallback: QueuePlayer matchmaking (toi da 45s)
        if not entered then
            local q = invoke("QueuePlayer", map, diff, false)
            local qs = type(q) == "table" and tostring(q.status) or "Sent"
            K.Log(("QueuePlayer -> %s"):format(qs))
            if type(q) == "table" and q.status == "Fail" then
                local msg = tostring(q.message or "")
                if msg:find("arty") then
                    pcall(function() fire("RemovePlayerFromParty") end)
                    task.wait(1)
                    q = invoke("QueuePlayer", map, diff, false)
                    qs = type(q) == "table" and tostring(q.status) or "Sent"
                    K.Log("QueuePlayer retry -> " .. qs)
                end
            end
            if not (type(q) == "table" and q.status == "Fail") then
                entered = pollGame(20)
            end
        end
        -- 4) thu lai CreateRoom 1 lan
        if not entered then
            K.Log("Slow entry -> retry CreateRoom")
            pcall(function() fire("RemovePlayerFromParty") end)
            task.wait(0.5)
            res = invoke("CreateRoom", { MapName = map, Difficulty = diff })
            task.wait(0.3)
            pcall(function() require(lp.PlayerGui.Modules.RoomModule).startGame() end)
            entered = pollGame(6)
        end
        if entered then
            K.Log(("ENTERED %s [%s] sau %.1fs"):format(map, diff, now() - t0))
            K.QueueStuck = 0
            K.Runs += 1
            if stat("Level") and stat("Level") >= 15 then
                K.RaidDebt = (K.RaidDebt or 0) + 1
            end
        else
            K.Log("Enter FAILED: " .. map .. " [" .. diff .. "]")
            K.Ban[map] = now() + 60      -- ban nhe 60s, retry lai
            task.wait(8)
        end
        K.QueueActive = false
        K.Entering = false
    end)
end

-- QueuePlayer cho raid lobby
function K.Queue(map, diff)
    if not map or map == "" then return false end
    K.QueueActive, K.QueueStart = true, now()
    K.QueueMap, K.QueueDiff = map, diff
    local res = invoke("QueuePlayer", map, diff, false)
    local status = type(res) == "table" and tostring(res.status) or "Sent"
    K.Log(("Queue %s [%s] -> %s"):format(map, diff, status))
    if status == "Fail" then
        K.QueueActive = false
        if diff ~= "Easy" then
            task.defer(function() K.Queue(map, "Easy") end)
        end
        return false
    end
    K.Runs += 1
    return true
end

function K.CancelQueue()
    if K.QueueActive then
        pcall(function() invoke("RemovePlayerFromQueue") end)
        K.QueueActive = false
    end
end

-----------------------------------------------------------------------
-- Dailies / online rewards / battlepass
-----------------------------------------------------------------------
function K.ClaimDailies()
    local s = getSettings()
    local order = {
        "DailyQuest_Login", "DailyQuest_Enemies", "Daily_TimePlayed",
        "DailyQuest_DungeonClear", "DailyQuest_Raid", "DailyQuest_BossRush",
    }
    for _, name in ipairs(order) do
        local q = (s.DailyQuestSettings or {})[name]
        if q then
            local cur = stat(name) or 0
            if cur >= (q.AmountNeeded or 1) then
                local r = invoke("CompleteDailyQuest", name)
                if type(r) == "table" and r.status == "Success" then
                    K.DailyClaims += 1
                    K.Log("Daily claimed: " .. name)
                end
                task.wait(0.4)
            end
        end
    end
    local all = (s.DailyQuestSettings or {})["DailyQuest_AllQuestClear"]
    if all and (stat("DailyQuest_AllQuestClear") or 0) >= (all.AmountNeeded or 5) then
        local r = invoke("CompleteDailyQuest", "DailyQuest_AllQuestClear")
        if type(r) == "table" and r.status == "Success" then
            K.DailyClaims += 1
            K.Log("Daily claimed: AllQuestClear")
        end
    end
    for _, e in ipairs(s.limitedEventCurrencyOnlineRewards or {}) do
        if e.statName and stat(e.statName) == false then
            local r = invoke("ClaimOnlineReward", e.statName)
            if type(r) == "table" and r.status == "Success" then
                K.Log("Online reward: " .. tostring(e.statName))
            end
            task.wait(0.3)
        end
    end
    pcall(function() invoke("ClaimBattlepassReward", "Free") end)
end

-----------------------------------------------------------------------
-- Auto equip character / costume
-----------------------------------------------------------------------
function K.AutoEquip()
                if K.Config.AutoBuyChar and now() - (K.LastShop or 0) > K.Config.ShopInterval then
                    K.LastShop = now()
                    task.spawn(function() pcall(K.AutoBuyCharacter) end)
                end
                if K.Config.AutoSlots and now() - (K.LastSlots or 0) > K.Config.SlotInterval then
                    K.LastSlots = now()
                    task.spawn(function() pcall(K.AutoEquipLoadout) end)
                end
                if (K.Config.AutoCards or K.Config.AutoDeleteLow) and now() - (K.LastCards or 0) > K.Config.CardInterval then
                    K.LastCards = now()
                    task.spawn(function() pcall(K.AutoCards) end)
                end
    if not K.Config.AutoEquip then return end
    local cur = stat("CharacterName")
    if cur == nil or cur == "" then
        for name in pairs(getSettings().CharacterSettings or {}) do
            local own = invoke("VerifyPlayerOwnsCharacter", name, "Character")
            if own == true then
                local r = invoke("EquipCharacter", name)
                K.Log(("EquipCharacter %s -> %s"):format(name, type(r) == "table" and tostring(r.status) or "Sent"))
                break
            end
        end
        return
    end
end

-----------------------------------------------------------------------
-- Combat loop — remote-driven, không cần aim (server tự tính hitbox)
-----------------------------------------------------------------------
function K.CombatTick()
    local char = lp.Character
    if not char then return end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    local hum = char:FindFirstChildWhichIsA("Humanoid")
    if not hrp or not hum then return end
    if hum.Health <= 0 then
        if K.Config.AutoRevive then
            invoke("RevivePlayer")
            task.wait(2.2)
        end
        return
    end
    local cf  = hrp.CFrame
    local t   = now()
    local fired = false
    for _, slot in ipairs({1, 2, 3, 4}) do
        if t - (K.SkillCD[slot] or -99) >= K.Config.SkillDelay then
            fire("UseSkill", {hrpCFrame = cf}, slot)
            K.SkillCD[slot] = t
            fired = true
            break
        end
    end
    if not fired and t - K.BasicCD >= K.Config.AttackDelay then
        K.AttackIndex += 1
        if K.AttackIndex > 4 then K.AttackIndex = 1 end
        fire("UseSkill", {attackNumber = K.AttackIndex, hrpCFrame = cf}, "BasicAttack")
        K.BasicCD = t
    end
end

-----------------------------------------------------------------------
-- Supervisor (1 vòng/0.15s) + combat (nhanh hơn)
-----------------------------------------------------------------------
function K.Supervisor()
    while K.Running do
        local ok, err = pcall(function()
            if not K.Config.AutoFarm then return end
            local st = srvType()
            -- result screen → retry / leave (chỉ khi đang ở trong dungeon)
            if st == "Game" then
                local rg = lp.PlayerGui:FindFirstChild("UniversalGui")
                rg = rg and rg:FindFirstChild("UniversalCenterUIFrame")
                rg = rg and rg:FindFirstChild("ResultUI")
                local retryBtn = rg and rg:FindFirstChild("Frame")
                retryBtn = retryBtn and retryBtn:FindFirstChild("ResultLayout")
                retryBtn = retryBtn and retryBtn:FindFirstChild("RetryDungeonButton")
                -- ResultUI.fck  Visible mới là màn hình kết quả (nút bên trong lúc nào cũng visible)
                if rg and rg.Visible and K.Config.AutoRetry then
                    if now() - (K.LastRetry or -99) > K.Config.RetryCooldown then
                        K.LastRetry = now()
                        fire("RetryDungeon")
                        K.Log("Run ended -> RetryDungeon")
                        K.QueueActive = false
                        K.QueueMap, K.QueueDiff = "", ""
                    end
                    return
                end
            elseif st == "Lobby" then
                -- dọn trạng thái queue/result khi đã về lobby (queue mất ~25s mới coi là treo)
                if K.QueueActive and now() - K.QueueStart > 25 then
                    K.QueueActive = false
                    K.QueueMap, K.QueueDiff = "", ""
                end
            end
            -- dailies
            if K.Config.AutoDaily and now() - K.LastDaily > 240 then
                K.LastDaily = now()
                task.spawn(function() pcall(K.ClaimDailies) end)
            end
            if st == "Lobby" then
                K.AutoEquip()
                -- story sticky: chi doi target khi level duoc len map/diff cao hon
                if K.Config.StorySticky and K.TargetMap ~= "" then
                    local m2, d2 = K.PickMap()
                    if m2 and K.GateOf(m2, d2) > K.GateOf(K.TargetMap, K.TargetDiff) then
                        K.Log(("STORY UPGRADE: %s [%s] -> %s [%s]"):format(K.TargetMap, K.TargetDiff, m2, d2))
                        K.TargetMap, K.TargetDiff = m2, d2
                    end
                elseif not K.Config.StorySticky then
                    local m, d = K.PickMap()
                    K.TargetMap, K.TargetDiff = m, d
                end
                if not K.QueueActive and not K.Entering then
                    local lvl = stat("Level") or 1
                    if K.Config.AutoRaid and lvl >= 15 and (K.RaidDebt or 0) >= K.Config.RaidEvery then
                        local r = invoke("TeleportToRaidLobby")
                        if r ~= nil then K.RaidDebt = 0 end
                        task.wait(6)
                    elseif K.Config.AutoInfinite and lvl >= 20 and #Players:GetPlayers() <= 1 then
                        K.EnterDungeon("Infinite Mode", "Infinite")
                    elseif K.TargetMap ~= "" then
                        K.EnterDungeon(K.TargetMap, K.TargetDiff)
                    else
                        local m, d = K.PickMap()
                        K.EnterDungeon(m, d)
                    end
                end
            elseif st == "RaidLobby" then
                if not K.QueueActive then
                    local lvl = stat("Level") or 1
                    local queued = false
                    if lvl >= 15 then
                        for _, m in pairs(getSettings().MapInfo or {}) do
                            if type(m) == "table" and m.isRaid and m.mapName and not m.limited
                               and not m.endTime and not m.excludeFromList
                               and not (K.Ban[m.mapName] and K.Ban[m.mapName] > now()) then
                                local req = m.difficulties and m.difficulties.Easy and m.difficulties.Easy.levelReq
                                if (not req or req <= lvl) and (not m.minimumPlayersToStart or m.minimumPlayersToStart <= 1) then
                                    K.Queue(m.mapName, "Easy"); queued = true; break
                                end
                            end
                        end
                    end
                    if not queued then
                        invoke("TeleportToLobbyWithSave")
                        task.wait(6)
                    end
                end
            elseif st ~= "Game" and st ~= "Unknown" and st ~= "RaidLobby" then
                -- khong back lobby truoc dieu kien: vao lai dungeon dang farm
                if now() - (K.LastRescue or -99) > 30 then
                    K.LastRescue = now()
                    if K.TargetMap ~= "" and not K.Entering then
                        K.Log("Rescue: re-enter " .. K.TargetMap)
                        K.EnterDungeon(K.TargetMap, K.TargetDiff)
                    else
                        invoke("TeleportToLobbyWithSave")
                    end
                end
            end
        end)
        if not ok then K.Log("supervisor error: " .. tostring(err)) end
        task.wait(0.15)
    end
end

function K.CombatLoop()
    while K.Running do
        local ok = pcall(function()
            if K.Config.AutoFarm and srvType() == "Game" then
                K.CombatTick()
            end
        end)
        if not ok then task.wait(0.5) end
        task.wait(0.12)
    end
end

-----------------------------------------------------------------------
-- UI
-----------------------------------------------------------------------
local function corner(inst, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 6)
    c.Parent = inst
end

function K.BuildUI()
    local parent = (gethui and gethui()) or game:GetService("CoreGui")
    local old = parent:FindFirstChild("AD_Kaitun")
    if old then old:Destroy() end

    local gui = Instance.new("ScreenGui")
    gui.Name = "AD_Kaitun"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.Parent = parent

    local bg   = Color3.fromRGB(14, 16, 24)
    local acc  = Color3.fromRGB(0, 210, 255)
    local acc2 = Color3.fromRGB(255, 90, 180)
    local txt  = Color3.fromRGB(235, 240, 255)
    local sub  = Color3.fromRGB(150, 160, 190)

    local main = Instance.new("Frame")
    main.Size = UDim2.new(0, 316, 0, 352)
    main.Position = UDim2.new(0.03, 0, 0.12, 0)
    main.BackgroundColor3 = bg
    main.BackgroundTransparency = 0.08
    main.BorderSizePixel = 0
    main.Active = true
    main.Draggable = false
    main.Parent = gui
    corner(main, 10)
    local stroke = Instance.new("UIStroke")
    stroke.Color = acc; stroke.Thickness = 1.2; stroke.Transparency = 0.55
    stroke.Parent = main

    -- title
    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -70, 0, 30)
    title.Position = UDim2.new(0, 10, 0, 4)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.Text = "⚡ AD KAITUN v" .. K.Version
    title.TextColor3 = acc
    title.TextSize = 15
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = main

    local close = Instance.new("TextButton")
    close.Size = UDim2.new(0, 26, 0, 26)
    close.Position = UDim2.new(1, -58, 0, 4)
    close.BackgroundColor3 = Color3.fromRGB(40, 20, 30)
    close.Text = "×"; close.TextColor3 = acc2; close.Font = Enum.Font.GothamBold; close.TextSize = 16
    close.Parent = main; corner(close, 6)
    close.MouseButton1Click:Connect(function() gui.Enabled = not gui.Enabled end)

    local hide = Instance.new("TextButton")
    hide.Size = UDim2.new(0, 26, 0, 26)
    hide.Position = UDim2.new(1, -30, 0, 4)
    hide.BackgroundColor3 = Color3.fromRGB(20, 40, 30)
    hide.Text = "—"; hide.TextColor3 = acc; hide.Font = Enum.Font.GothamBold; hide.TextSize = 16
    hide.Parent = main; corner(hide, 6)
    local collapsed = false
    hide.MouseButton1Click:Connect(function()
        collapsed = not collapsed
        main.Size = collapsed and UDim2.new(0, 316, 0, 34) or UDim2.new(0, 316, 0, 352)
        for _, c in ipairs(main:GetChildren()) do
            if c ~= title and c ~= close and c ~= hide and c:IsA("GuiObject") then c.Visible = not collapsed end
        end
    end)

    -- phase
    local phase = Instance.new("TextLabel")
    phase.Name = "Phase"
    phase.Size = UDim2.new(1, -20, 0, 22)
    phase.Position = UDim2.new(0, 10, 0, 32)
    phase.BackgroundTransparency = 1
    phase.Font = Enum.Font.GothamBold
    phase.Text = "BOOTING..."
    phase.TextColor3 = acc2
    phase.TextSize = 14
    phase.TextXAlignment = Enum.TextXAlignment.Left
    phase.Parent = main

    -- level + exp bar
    local lvl = Instance.new("TextLabel")
    lvl.Name = "Level"
    lvl.Size = UDim2.new(1, -20, 0, 16)
    lvl.Position = UDim2.new(0, 10, 0, 54)
    lvl.BackgroundTransparency = 1
    lvl.Font = Enum.Font.Gotham
    lvl.Text = "Level 1"
    lvl.TextColor3 = txt; lvl.TextSize = 12
    lvl.TextXAlignment = Enum.TextXAlignment.Left
    lvl.Parent = main

    local expbg = Instance.new("Frame")
    expbg.Size = UDim2.new(1, -20, 0, 6)
    expbg.Position = UDim2.new(0, 10, 0, 72)
    expbg.BackgroundColor3 = Color3.fromRGB(35, 38, 52)
    expbg.BorderSizePixel = 0
    expbg.Parent = main; corner(expbg, 3)
    local expfill = Instance.new("Frame")
    expfill.Name = "Fill"
    expfill.Size = UDim2.new(0, 0, 1, 0)
    expfill.BackgroundColor3 = Color3.fromRGB(90, 220, 120)
    expfill.BorderSizePixel = 0
    expfill.Parent = expbg; corner(expfill, 3)

    -- stat grid
    local stats = Instance.new("TextLabel")
    stats.Name = "Stats"
    stats.Size = UDim2.new(1, -20, 0, 92)
    stats.Position = UDim2.new(0, 10, 0, 82)
    stats.BackgroundTransparency = 1
    stats.Font = Enum.Font.Gotham
    stats.Text = "..."
    stats.TextColor3 = sub
    stats.TextSize = 11.5
    stats.TextXAlignment = Enum.TextXAlignment.Left
    stats.TextYAlignment = Enum.TextYAlignment.Top
    stats.TextWrapped = false
    stats.Parent = main

    -- log
    local log = Instance.new("TextLabel")
    log.Name = "Log"
    log.Size = UDim2.new(1, -20, 0, 74)
    log.Position = UDim2.new(0, 10, 0, 176)
    log.BackgroundTransparency = 1
    log.Font = Enum.Font.Gotham
    log.Text = ""
    log.TextColor3 = Color3.fromRGB(190, 200, 225)
    log.TextSize = 10.5
    log.TextXAlignment = Enum.TextXAlignment.Left
    log.TextYAlignment = Enum.TextYAlignment.Top
    log.TextWrapped = true
    log.Parent = main

    -- manual map queue
    local mapBox = Instance.new("TextBox")
    mapBox.Name = "MapBox"
    mapBox.Size = UDim2.new(0.5, -24, 0, 22)
    mapBox.Position = UDim2.new(0, 10, 1, -86)
    mapBox.BackgroundColor3 = Color3.fromRGB(26, 30, 44)
    mapBox.PlaceholderText = "map (vd Titan Dimension)"
    mapBox.Text = ""
    mapBox.TextColor3 = txt
    mapBox.Font = Enum.Font.Gotham; mapBox.TextSize = 11
    mapBox.ClearTextOnFocus = false
    mapBox.Parent = main; corner(mapBox, 4)

    local diffBox = Instance.new("TextBox")
    diffBox.Size = UDim2.new(0.5, -24, 0, 22)
    diffBox.Position = UDim2.new(0.5, 10, 1, -86)
    diffBox.BackgroundColor3 = Color3.fromRGB(26, 30, 44)
    diffBox.PlaceholderText = "diff (Easy/Hard/Nightmare)"
    diffBox.Text = ""
    diffBox.TextColor3 = txt
    diffBox.Font = Enum.Font.Gotham; diffBox.TextSize = 11
    diffBox.ClearTextOnFocus = false
    diffBox.Parent = main; corner(diffBox, 4)

    local qBtn = Instance.new("TextButton")
    qBtn.Size = UDim2.new(0.5, -17, 0, 22)
    qBtn.Position = UDim2.new(0, 10, 1, -60)
    qBtn.BackgroundColor3 = Color3.fromRGB(20, 60, 80)
    qBtn.Text = "QUEUE"
    qBtn.TextColor3 = acc; qBtn.Font = Enum.Font.GothamBold; qBtn.TextSize = 11
    qBtn.Parent = main; corner(qBtn, 4)
    qBtn.MouseButton1Click:Connect(function()
        local m = mapBox.Text ~= "" and mapBox.Text or K.PickMap()
        local d = diffBox.Text ~= "" and diffBox.Text or "Easy"
        K.Log("Manual enter: " .. tostring(m) .. " [" .. tostring(d) .. "]")
        K.EnterDungeon(tostring(m), tostring(d))
    end)

    local farmBtn = Instance.new("TextButton")
    farmBtn.Name = "FarmBtn"
    farmBtn.Size = UDim2.new(0.5, -17, 0, 22)
    farmBtn.Position = UDim2.new(0.5, 10, 1, -60)
    farmBtn.BackgroundColor3 = Color3.fromRGB(30, 70, 30)
    farmBtn.Text = "FARM: ON"
    farmBtn.TextColor3 = Color3.fromRGB(120, 255, 140)
    farmBtn.Font = Enum.Font.GothamBold; farmBtn.TextSize = 11
    farmBtn.Parent = main; corner(farmBtn, 4)
    farmBtn.MouseButton1Click:Connect(function()
        K.Config.AutoFarm = not K.Config.AutoFarm
        farmBtn.Text = K.Config.AutoFarm and "FARM: ON" or "FARM: OFF"
        farmBtn.TextColor3 = K.Config.AutoFarm and Color3.fromRGB(120, 255, 140) or Color3.fromRGB(255, 120, 120)
        K.Log("AutoFarm = " .. tostring(K.Config.AutoFarm))
    end)

    local rBtn = Instance.new("TextButton")
    rBtn.Size = UDim2.new(0.5, -17, 0, 22)
    rBtn.Position = UDim2.new(0, 10, 1, -34)
    rBtn.BackgroundColor3 = Color3.fromRGB(60, 45, 15)
    rBtn.Text = "RETRY"
    rBtn.TextColor3 = Color3.fromRGB(255, 210, 90)
    rBtn.Font = Enum.Font.GothamBold; rBtn.TextSize = 11
    rBtn.Parent = main; corner(rBtn, 4)
    rBtn.MouseButton1Click:Connect(function()
        fire("RetryDungeon"); K.Log("Manual RetryDungeon")
    end)

    local lBtn = Instance.new("TextButton")
    lBtn.Size = UDim2.new(0.5, -17, 0, 22)
    lBtn.Position = UDim2.new(0.5, 10, 1, -34)
    lBtn.BackgroundColor3 = Color3.fromRGB(60, 25, 25)
    lBtn.Text = "LEAVE"
    lBtn.TextColor3 = Color3.fromRGB(255, 130, 130)
    lBtn.Font = Enum.Font.GothamBold; lBtn.TextSize = 11
    lBtn.Parent = main; corner(lBtn, 4)
    lBtn.MouseButton1Click:Connect(function()
        fire("LeaveDungeon"); K.Log("Manual LeaveDungeon")
    end)
    local wsBtn = Instance.new("TextButton")
    wsBtn.Name = "WhiteBtn"
    wsBtn.Size = UDim2.new(0, 66, 0, 20)
    wsBtn.Position = UDim2.new(1, -78, 0, 54)
    wsBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
    wsBtn.Text = "WHITE: OFF"
    wsBtn.TextColor3 = Color3.fromRGB(150, 150, 150)
    wsBtn.Font = Enum.Font.GothamBold
    wsBtn.TextSize = 10
    wsBtn.Parent = main
    corner(wsBtn, 4)
    wsBtn.MouseButton1Click:Connect(function()
        K.SetWhite(not K.WhiteScreen)
        wsBtn.Text = K.WhiteScreen and "WHITE: ON" or "WHITE: OFF"
        wsBtn.TextColor3 = K.WhiteScreen and Color3.fromRGB(255, 215, 90) or Color3.fromRGB(150, 150, 150)
    end)

    -- drag trên title
    do
        local dragging, dragStart, startPos = false, nil, main.Position
        title.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
               or input.UserInputType == Enum.UserInputType.Touch then
                dragging = true; dragStart = input.Position; startPos = main.Position
            end
        end)
        game:GetService("UserInputService").InputChanged:Connect(function(input)
            if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
               or input.UserInputType == Enum.UserInputType.Touch) then
                local delta = input.Position - dragStart
                main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X,
                                          startPos.Y.Scale, startPos.Y.Offset + delta.Y)
            end
        end)
        game:GetService("UserInputService").InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
               or input.UserInputType == Enum.UserInputType.Touch then
                dragging = false
            end
        end)
    end

    K.Gui = gui
    return gui
end

-----------------------------------------------------------------------
-- UI refresh
-----------------------------------------------------------------------
function K.RefreshUI()
    if not K.Gui then return end
    local main = K.Gui:FindFirstChildOfClass("Frame")
    if not main then return end
    local lvl  = stat("Level") or 1
    local exp  = stat("Experience") or 0
    local maxe = stat("MaxExperience") or 1
    local gem  = stat("Gem") or 0
    local chr  = stat("CharacterName") or "?"
    local kills = stat("EnemiesDefeatedRound") or 0
    local st   = srvType()
    local mapLine = "—"
    if st == "Game" or K.QueueActive then
        mapLine = (K.QueueMap ~= "" and K.QueueMap or "dungeon") .. " [" .. (K.QueueDiff ~= "" and K.QueueDiff or "?") .. "]"
    end
    local phaseTxt = ({
        Lobby = "🏠 LOBBY — chọn map", Game = "⚔️ FARMING", RaidLobby = "🩸 RAID LOBBY",
        CharacterTest = "🧪 TEST", AFK = "💤 AFK", Unknown = "…",
    })[st] or st
    if not K.Config.AutoFarm then phaseTxt = "⏸ PAUSED" end

    local phase = main:FindFirstChild("Phase")
    if phase then phase.Text = phaseTxt end
    local lvlL = main:FindFirstChild("Level")
    if lvlL then lvlL.Text = ("Account Level %s   💎 %s Gems   🧩 %s"):format(tostring(lvl), tostring(gem), tostring(chr)) end
    local bar = main:FindFirstChild("Level")
    local expbg = bar and bar.Parent and bar.Parent:FindFirstChildWhichIsA("Frame")
    if expbg then
        local fill = expbg:FindFirstChild("Fill")
        if fill then
            local p = math.clamp((maxe > 0) and (exp / maxe) or 0, 0, 1)
            fill.Size = UDim2.new(p, 0, 1, 0)
        end
    end
    local statsL = main:FindFirstChild("Stats")
    if statsL then
        statsL.Text = ("Runs: %d   Kills(run): %d   Raid clears: %s\nDaily claims: %d   Uptime: %s\nFarm: %s   Raid debt: %d"):format(
            K.Runs, kills, tostring(stat("RaidClears") or 0), K.DailyClaims,
            humanTime(now() - K.StartTime),
            K.Config.AutoFarm and "ON" or "OFF", K.RaidDebt or 0)
    end
    local logL = main:FindFirstChild("Log")
    if logL then logL.Text = table.concat(K.Logs, "\n") end
end

-----------------------------------------------------------------------
-- Start / Stop
-----------------------------------------------------------------------
function K.Start()
    if K.Running then return end
    K.Running = true
    K.StartTime = now()
    K.BuildUI()
    table.insert(K.Threads, task.spawn(K.Supervisor))
    table.insert(K.Threads, task.spawn(K.CombatLoop))
    table.insert(K.Threads, task.spawn(function()
        while K.Running do
            task.wait(0.5)
            pcall(K.RefreshUI)
        end
    end))
    K.Log("AD_Kaitun v" .. K.Version .. " started — auto farm ON")
end

function K.SetWhite(on)
    K.WhiteScreen = on and true or false
    pcall(function()
        game:GetService("RunService"):Set3dRenderingEnabled(not K.WhiteScreen)
    end)
    K.Log("White screen " .. (K.WhiteScreen and "ON" or "OFF"))
end

function K.Stop()
    K.Running = false
    pcall(function()
        if K.Gui then K.Gui:Destroy() end
    end)
    K.Gui = nil
    K.Logs = {}
end

-----------------------------------------------------------------------
-- AUTO SHOP / LOADOUT / CARDS
-----------------------------------------------------------------------
K.TierRank = {
    -- S+ meta (uu tien cao nhat)
    ["King of Curses (Incarnate)"]=100,["Shadow Monarch"]=100,["Kodotoki"]=100,
    ["Priestess (Shrine)"]=100,["Demon Girl (New Year)"]=100,["Virtual Swordsman (Stardust)"]=100,
    ["Ice Queen Esdeaf"]=100,["Fluffy (Gear 5)"]=100,["Fluffy (Vampire King)"]=100,
    ["Ichini (Final)"]=100,["Nardo (Six Paths)"]=100,["Combat Titan"]=100,["Infinite Nojo"]=100,
    ["Cursed Sage"]=100,["Tobushiko"]=100,["Tengu"]=100,["Sun Gomi"]=100,["Scarlet Cutter"]=100,
    ["Dusk"]=100,["Nyx Sword King"]=100,["Shinobi (Six Paths)"]=100,["Sora Sun God"]=100,
    ["Tanjiro Sun God"]=100,["Dio"]=100,["Esper"]=100,["Nilin (Valentine)"]=100,
    ["Tengoku"]=100,["Ryuka"]=100,["Eyzen (Void)"]=100,["Hirito"]=100,["Rivai"]=100,["Toro"]=100,
    -- A
    ["Perfect Soldier"]=80,["Alturia"]=80,["Ichini (Fullbring)"]=80,["Black Pasta"]=80,
    ["Roku (Ultra Instinct)"]=80,["Black Asta"]=80,["Madoka"]=80,["Meguretsu"]=80,
    ["Dual Wielder"]=80,["Demon Lord Ramura"]=80,["King of Heroes"]=80,["Makima"]=80,
    ["Primordial"]=80,["Soul King"]=80,["Combat Giant"]=80,["Priestess"]=80,["Tiger"]=80,
    ["Zane"]=80,["Astral Wolf"]=80,["Hime"]=80,["Shadow Ramura"]=80,["Witch Meguretsu"]=80,
    ["Alturia Alter"]=80,["Ramura"]=80,["Takamuri"]=80,["Chainsaw"]=80,["Alis"]=80,
    ["Red Emperor"]=80,["Nardo (Beast)"]=80,["Zetsu"]=80,["Bowman"]=80,["Mochi Boy"]=80,
    ["Toro (Summer)"]=80,["Mochi Boy (Summer)"]=80,["Best Boy (Summer)"]=80,
    -- B
    ["Vampire King Luffy"]=40,["Nojo"]=40,["Tonjuro"]=40,["Yomiichi"]=40,["Akuma"]=40,
    ["Kaido"]=40,["Yamato"]=40,["Vampire Mika"]=40,["Obito"]=40,["Beast King"]=40,
    ["Deku Hundred"]=40,["Yor"]=40,["Takamuri (Summer)"]=40,["Onihime"]=40,["Cyborg"]=40,
    ["Asana"]=40,["Lance Guy"]=40,["Eugebro"]=40,["Tall Might"]=40,["BiriBiri"]=40,
    ["Koneki"]=40,["Winter Spirit Lia"]=40,
    -- C/base/starters
    ["Cherry"]=10,["Itabori"]=10,["Bakubro"]=10,["Ray"]=10,["Rokia"]=10,["Shield Man"]=10,
    ["Susky"]=10,["Saiya"]=5,["One Hero"]=5,["Kuroshi"]=5,["Shinobi"]=5,["Gomi"]=5,
    ["Rek u"]=5,["Hatsu"]=5,["Pasta"]=5,["Yakaza"]=5,["Christmas Alter"]=5,
}

local function rankOf(name, entry)
    if not name then return 0 end
    local r = K.TierRank[name]
    if r then return r end
    if entry then
        r = K.TierRank[entry.displayName or ""]
        if r then return r end
        r = K.TierRank[entry.anime or ""]
        if r then return r end
    end
    return 1
end

-- Mua nhan vat manh nhat mua duoc (gem), khong mua do Robux
function K.AutoBuyCharacter()
    local gems = stat("Gem") or 0
    local best, bestRank = nil, 0
    for name, c in pairs(getSettings().CharacterSettings or {}) do
        local cost = tonumber(c.cost) or 0
        local robux = c.robuxCost
        if not robux and cost > 0 and cost <= gems then
            local rank = rankOf(name, c)
            if rank > bestRank or (rank == bestRank and best and cost > best.cost) then
                best, bestRank = { name = name, cost = cost }, rank
            end
        end
    end
    if not best or bestRank <= 1 then
        if best then K.Log("Shop: khong co giang mua xung dang (gem=" .. gems .. ")") end
        return nil
    end
    local res = invoke("BuyCharacter", best.name)
    local st = type(res) == "table" and tostring(res.status) or "Sent"
    K.Log(("BUY %s (%s gems, rank %d) -> %s"):format(best.name, best.cost, bestRank, st))
    if st == "Success" or st == "Sent" then
        task.wait(0.5)
        invoke("EquipCharacter", best.name)
        K.Log("Equipped main: " .. best.name)
        K.ShopBuys += 1
        return best.name
    end
    return nil
end

-- Equip main + 2 assist = 3 slot manh nhat dang so h~uu
function K.AutoEquipLoadout()
    local cs = getSettings().CharacterSettings or {}
    local owned = {}
    for name, c in pairs(cs) do
        local own = invoke("VerifyPlayerOwnsCharacter", name, "Character")
        if own == true then
            table.insert(owned, { name = name, rank = rankOf(name, c), cost = tonumber(c.cost) or 0 })
        end
    end
    table.sort(owned, function(a, b)
        if a.rank == b.rank then return a.cost > b.cost end
        return a.rank > b.rank
    end)
    if #owned == 0 then return end
    local cur = stat("CharacterName")
    local mainName = owned[1].name
    if cur ~= mainName then
        local r = invoke("EquipCharacter", mainName)
        K.Log(("Equip main %s -> %s"):format(mainName, type(r) == "table" and tostring(r.status) or "Sent"))
        task.wait(0.4)
    end
    local a1 = stat("AssistCharacterName1")
    local a2 = stat("AssistCharacterName2")
    local assist1 = owned[2] and owned[2].name or mainName
    local assist2 = owned[3] and owned[3].name or assist1
    if a1 ~= assist1 then
        local r = invoke("EquipCharacterAssist", assist1, 1)
        K.Log(("Equip assist1 %s -> %s"):format(assist1, type(r) == "table" and tostring(r.status) or "Sent"))
        task.wait(0.4)
    end
    if a2 ~= assist2 then
        local r = invoke("EquipCharacterAssist", assist2, 2)
        K.Log(("Equip assist2 %s -> %s"):format(assist2, type(r) == "table" and tostring(r.status) or "Sent"))
        task.wait(0.4)
    end
end

-- Card inventory qua InventoryModule.returnInventory()
local function getInventory()
    local ok, im = pcall(function() return require(lp.PlayerGui.Modules.InventoryModule) end)
    if not ok or type(im) ~= "table" or not im.returnInventory then return nil end
    local ok2, inv = pcall(function() return im.returnInventory() end)
    return ok2 and inv or nil
end

function K.CardScore(e)
    local rar = tostring(e.Rarity or e.rarity or e.cardRarity or "Common")
    local s = (K.CardRarityRank[rar] or 1) * 1000000
    for _, k in ipairs({ "Attack", "Health", "CardHealth", "CriticalChance", "CriticalDamage", "Damage", "Level" }) do
        local v = e[k]
        if type(v) == "number" then s = s + v end
    end
    return s
end

function K.CardRarityOf(e)
    return tostring(e.Rarity or e.rarity or e.cardRarity or "Common")
end

K.CardRarityRank = { Common = 1, Uncommon = 2, Rare = 3, Epic = 4, Legendary = 5, Mythic = 6, Divine = 7 }

function K.AutoCards()
    local inv = getInventory()
    if not inv or not inv.Cards then
        K.Log("Cards: inventory chua san sang")
        return
    end
    local equipped, bag = {}, {}
    for id, e in pairs(inv.Cards) do
        if type(e) == "table" then
            local uid = e.Unique_ID or e.uniqueId or e.id or id
            local rec = { uid = uid, score = K.CardScore(e), rarity = K.CardRarityOf(e), eq = (e.Equipped == true) }
            table.insert(rec.eq and equipped or bag, rec)
        end
    end
    -- debug 1 lan: liet ke fieldThat card that contain
    if not K.CardDebugDone then
        K.CardDebugDone = true
        for _, e in pairs(inv.Cards) do
            if type(e) == "table" then
                local keys = {}
                for k, v in pairs(e) do table.insert(keys, tostring(k) .. "=" .. (type(v) == "table" and "tbl" or tostring(v))) end
                table.sort(keys)
                K.Log("CARD SAMPLE: " .. table.concat(keys, ", "))
            end
        end
    end
    -- equip card manh nhat (thay the neu manh hon equip hien tai)
    if K.Config.AutoCards then
        table.sort(bag, function(a, b) return a.score > b.score end)
        table.sort(equipped, function(a, b) return a.score > b.score end)
        local slots = 3
        for i = 1, slots do
            local cur = equipped[i]
            local cand = bag[i]
            if cand and (not cur or cand.score > cur.score) then
                local r = invoke("EquipCard", cand.uid)
                K.Log(("EquipCard %s (rar %s) -> %s"):format(tostring(cand.uid), cand.rarity, type(r) == "table" and tostring(r) or tostring(r)))
                task.wait(0.4)
            end
        end
    end
    -- xoa card Common/Uncommon/Rare khong equipped
    if K.Config.AutoDeleteLow then
        local keep = K.CardRarityRank[K.Config.KeepRarity] or 3
        local del = {}
        for _, c in ipairs(bag) do
            if (K.CardRarityRank[c.rarity] or 1) < keep then
                table.insert(del, c.uid)
            end
        end
        -- chia batch 20 neu nhieu
        for i = 1, #del, 20 do
            local batch = {}
            for j = i, math.min(i + 19, #del) do table.insert(batch, del[j]) end
            local res = invoke("MassDeleteCardsFromInventory", batch)
            local st = type(res) == "table" and tostring(res.status) or tostring(res)
            K.Log(("Delete low cards x%d -> %s"):format(#batch, st))
            K.CardDeleted += #batch
            task.wait(0.8)
        end
    end
end

-- boot
task.spawn(function()
    -- 0) MCP bridge self-loader: nối lại roblox-executor-mcp, retry vĩnh viễn (idempotent)
    task.spawn(function()
        while true do
            if not getgenv().MCP_Loaded then
                pcall(function()
                    loadstring(game:HttpGet("http://localhost:16384/script.luau"))()
                end)
                if getgenv().MCP_Loaded then
                    print("[AD_Kaitun] MCP bridge connected")
                end
            end
            task.wait(3)
        end
    end)

    local ok, err = pcall(function()
        local folder = RS:WaitForChild(lp.Name .. "StatDisplay", 10)
        K.Log("Stats folder: " .. (folder and "OK" or "waiting..."))
        K.Start()
    end)
    if not ok then K.Log("boot error: " .. tostring(err)) end
end)
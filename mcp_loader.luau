-- Roblox Executor MCP loader (autoexec)
-- Ket noi Roblox client toi MCP bridge tai 192.168.1.41:16384
print("[MCPlOADER] start, BridgeURL=" .. tostring(getgenv().BridgeURL or "localhost:16384"))
while not getgenv().MCP_Loaded do
    local bridgeUrl = getgenv().BridgeURL or "localhost:16384"
    pcall(function() loadstring(game:HttpGet("http://" .. bridgeUrl .. "/script.luau"))() end)
    if getgenv().MCP_Loaded then
        print("[MCPlOADER] connected OK")
        break
    end
    task.wait(0.15)
end
print("[MCPlOADER] loop exit MCP_Loaded=" .. tostring(getgenv().MCP_Loaded))
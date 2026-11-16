-- Anime Dimensions — MCP bridge loader (autoexec)
-- Giữ bridge của roblox-executor-mcp sống qua mỗi lần join game.
-- BẮT BUỘC trỏ BridgeURL về IP LAN của máy chạy MCP (localhost trên điện thoại = chính điện thoại).
getgenv().BridgeURL = "192.168.1.44:16384"
while not getgenv().MCP_Loaded do
    local bridgeUrl = getgenv().BridgeURL or "localhost:16384"
    pcall(function() loadstring(game:HttpGet("http://" .. bridgeUrl .. "/script.luau"))() end)
    task.wait(0.15)
end
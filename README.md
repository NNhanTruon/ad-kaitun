# AD Kaitun — Anime Dimensions Simulator Auto-Farm

Script kaitun (auto farm) F2P cho **Anime Dimensions Simulator** (Roblox, placeId `6938803436`), build trên reverse remote thật của client — không hardcode map/level, tự đọc `MapInfo` live.

Account thực chiến: **Level 1 → 83+** trong một phiên, farm liên tục không về lobby giữa chừng.

## File

| File | Nội dung |
|---|---|
| `AD_Kaitun.luau` | Script chính (45KB) — auto farm + UI + shop + loadout + card + white screen |
| `AD_MiniFarm_Guide.md` | Guide tiếng Việt: roadmap Level 1 → Endgame, tier meta, daily routine |
| `mcp_loader.luau` | Loader nối roblox-executor-mcp bridge (localStorage chạy, không autoexec) |
| `ramwatch.sh` | Watchdog RAM cho Android: kill roblox khi RAM < 700MB, relaunch khi hồi phục (chỉ đụng com.roblox.client) |
| `ad_autoexec.luau` | Bản loader autoexec đầu (giữ lại để tham khảo) |

## Tính năng chính

- **Combat remote-driven**: `FireServer("UseSkill", {hrpCFrame=CFrame}, slot)` xoay vòng skill 1-4 + BasicAttack — không cần aim.
- **Fast entry 5-10s**: clear party → `CreateRoom({MapName, Difficulty})` + `startGame()` → poll 6s → fallback `QueuePlayer` → retry. Log `ENTERED ... sau X.Xs`.
- **Story sticky**: khoá target map/difficulty, chỉ `STORY UPGRADE` khi level thật sự đủ gate cao hơn. Không back lobby giữa chừng. `RetryDungeon` cooldown 12s; lạc vào chỗ lạ thì vào lại đúng dungeon.
- **Auto shop**: mua nhân vật mạnh nhất mua được bằng Gem theo bảng tier meta (S+ → A → B → C → starter), rồi equip luôn.
- **Auto loadout đủ 3 slot**: `EquipCharacter(main)` + `EquipCharacterAssist(name, 1)` + `(name, 2)`.
- **Auto card**: `EquipCard(Unique_ID)` cho card mạnh nhất; `MassDeleteCardsFromInventory` xoả Common/Uncommon/Rare (giữ Epic+).
- **Daily**: claim đúng thứ tự `DailyQuestSettings`, `ClaimOnlineReward`, `ClaimBattlepassReward("Free")`.
- **UI theo dõi**: Level + EXP bar, Gem, Runs, Kills, Raid clears, uptime, log 6 dòng; nút `FARM ON/OFF`, `QUEUE` manual, `RETRY`, `LEAVE`, **`WHITE`** (tắt render 3D — màn hình trắng).
- **Self-healing**: tự nạp lại MCP bridge, tự dọn party state, ban map fail chỉ 60s.

## Cài đặt

1. Vào game bằng executor (Arceus X NEO / điện thoại).
2. Chạy `AD_Kaitun.luau`.
3. Muốn autoexec: copy vào `/sdcard/Arceus X/Autoexec/`.

## Cấu hình (trong file, `K.Config`)

```lua
FastEntry     = true,     -- join nhanh: CreateRoom + startGame trước
StorySticky   = true,     -- replay liên tục, chỉ đổi map khi đủ level gate
RetryCooldown = 12,       -- giây giữa 2 lần RetryDungeon
WhiteScreen   = false,    -- tắt render 3D (màn hình trắng)
KeepRarity    = "Epic",   -- giữ card Epic+, xoả Common/Uncommon/Rare
```

## Watchdog RAM (Linux/Android qua adb)

```bash
nohup bash ramwatch.sh &
```

MemAvailable < 700MB → force-stop Roblox; > 1.5GB → relaunch. Chỉ đụng `com.roblox.client`.

## Disclaimer

Dùng cho mục đích học tập/nghiên cứu trên account của chính bạn. Tự chịu rủi ro nếu dùng trên account người khác.
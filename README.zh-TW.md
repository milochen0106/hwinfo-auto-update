[![tests](https://github.com/milochen0106/hwinfo-auto-update/actions/workflows/tests.yml/badge.svg)](https://github.com/milochen0106/hwinfo-auto-update/actions/workflows/tests.yml)

# HWiNFO 自動更新工具（繁體中文導覽）

> 語言：[English](README.md) ｜ **繁體中文**

這是一套以 PowerShell 編寫的輕量工具：它會盯住 **HWiNFO 官方的穩定版發布通知**，一旦有新版本，就自動、靜默地完成更新，並保留你原有的設定。

不需要安裝任何 PowerShell 模組、外掛、agent 或背景服務。一台已經裝好 HWiNFO 的 Windows 10/11 電腦，加上管理者權限與網路，就足夠了。

---

## 導覽目錄

1. [為什麼需要這套工具](#1-為什麼需要這套工具)
2. [它會做什麼](#2-它會做什麼)
3. [快速開始（三分鐘上線）](#3-快速開始三分鐘上線)
4. [運作流程](#4-運作流程)
5. [需求與工具清單](#5-需求與工具清單)
6. [使用情境與指令](#6-使用情境與指令)
7. [參數對照表](#7-參數對照表)
8. [排程工作設定](#8-排程工作設定)
9. [檔案、日誌與備份](#9-檔案日誌與備份)
10. [疑難排解](#10-疑難排解)
11. [隱私與安全稽核](#11-隱私與安全稽核)
12. [設計限制](#12-設計限制)
13. [常見問答](#13-常見問答)
14. [授權與第三方聲明](#14-授權與第三方聲明)

---

## 1. 為什麼需要這套工具

HWiNFO 內建的「自動更新」功能是 **Pro 版專屬**。若你使用的是官方安裝檔裝上的免費版（非商業用途），要保持在最新版本只能自己上網查看、下載、執行安裝程式。

本工具把這件事自動化：

- 版本通知來源不是第三方猜測，而是 **HWiNFO 官方 RSS**（`https://www.hwinfo.com/news.xml/`）。
- 只認 **正式版**（`HWiNFO v8.60 released`），刻意忽略 Beta / RC / 預發布版本。
- 更新方式與系統管理員手動執行的一致：winget（比對套件 manifest 中記錄的 SHA-256）或直接執行官方 Inno Setup 安裝檔（先驗 PE 結構與Authenticode）。

---

## 2. 它會做什麼

| 步驟 | 行為 |
|---|---|
| 讀取本機版本 | 從 `HWiNFO64.EXE` 的 `ProductVersion` 取得，例如 `8.52-6060` → `8.52` |
| 尋找安裝路徑 | 先查 Windows 解除安裝登錄檔，再退回標準 Program Files 路徑；也可用 `-InstallDir` 指定 |
| 抓取官方通知 | 解析 RSS，篩掉 Beta / RC / pre-release，取最高穩定版 |
| 比對版本 | 官方版較新才動作；`-CheckOnly` 只回報不異動 |
| 備份設定 | 更新前將 `HWiNFO64.INI` 另存為時間戳檔名 |
| 關閉程式 | 先抓取執行中的 HWiNFO64 PID，逐一停止，再輪詢這些 PID 直到消失（最多 15 秒） |
| 執行更新 | 優先 winget（比對 manifest 記錄的 SHA-256）；失敗時改為 curl 下載官方安裝檔，先驗 PE 結構、Authenticode 簽章與精確發行者（`O=REALiX, s.r.o.`）再靜默安裝 |
| 驗證結果 | 重新讀取版本；未達目標版本即判定失敗 |
| 還原狀態 | 若更新前 HWiNFO 正在執行，**即使更新失敗**也會在 `finally` 中重新啟動 |
| 留下紀錄 | 每一步都寫入 `Update-HWiNFO.log` |

---

## 3. 快速開始（三分鐘上線）

### 步驟 1：取得程式

將本 repo 複製或下載到一個**固定位置**（排程工作會記錄絕對路徑，之後請勿移動資料夾）：

```powershell
git clone https://github.com/milochen0106/hwinfo-auto-update.git C:\Scripts\hwinfo-auto-update
```

確認兩支腳本都在同一層：

```powershell
Get-ChildItem .\Update-HWiNFO.ps1, .\Bootstrap-HWiNFO-AutoUpdate.ps1
```

### 步驟 2：先只檢查（建議）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Update-HWiNFO.ps1 -CheckOnly
```

你會看到類似：

```text
2026-11-25 23:35:34 [INFO] Install directory: C:\Program Files\HWiNFO64
2026-11-25 23:35:34 [INFO] Installed version: 8.60
2026-11-25 23:35:34 [INFO] Latest stable version: 8.60 (source: https://www.hwinfo.com/news.xml/)
2026-11-25 23:35:35 [INFO] Already up to date.
```

### 步驟 3：一鍵安裝更新與排程

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Bootstrap-HWiNFO-AutoUpdate.ps1
```

系統會彈出 UAC，請按「是」。這支腳本會：

1. 立即執行一次更新檢查；
2. 註冊每日 09:00、以最高權限執行的排程工作 `HWiNFO-AutoUpdate`。

重複執行是安全的：註冊時使用 `-Force`，會覆蓋同名的舊工作。

---

## 4. 運作流程

```mermaid
flowchart TD
    A[讀取本機 HWiNFO64.EXE 版本] --> B[抓取官方 RSS]
    B --> C{有新穩定版？}
    C -- 否 --> D[記錄『已是最新』，結束 0]
    C -- 是 --> E{-CheckOnly？}
    E -- 是 --> F[記錄可用版本，不異動，結束 0]
    E -- 否 --> G[備份 HWiNFO64.INI]
    G --> H[關閉執行中的 HWiNFO64]
    H --> I{有指定 InstallerPath？}
    I -- 有 --> J[使用指定安裝檔]
    I -- 無 --> K[winget install --force --silent]
    K -- 成功 --> L[驗證安裝後版本]
    K -- 失敗 --> M[curl 下載官方安裝檔]
    M --> N[Inno Setup 靜默安裝]
    J --> N
    N --> L
    L --> O{更新前 HWiNFO 有在執行？}
    O -- 有 --> P[重新啟動 HWiNFO]
    O -- 無 --> Q[記錄結果，結束 0]
    P --> Q
```

---

## 5. 需求與工具清單

### 不需要插件

兩支腳本只用 Windows PowerShell **內建 cmdlet**。沒有 PowerShell Gallery 套件、沒有 NuGet provider、沒有第三方模組、沒有 agent、沒有背景服務。指令本身帶 `-ExecutionPolicy Bypass`，所以對方即使預設為 `Restricted`，也不必改系統原則。

### 工具與條件對照

| 需求 | 是否 Windows 內建 | 用途 | 缺少時 |
|---|---|---|---|
| Windows 10 / 11（x64 或 ARM64） | 作業系統本身 | 全部功能 | 不支援；腳本以 `HWiNFO64.EXE` 為目標 |
| Windows PowerShell 5.1+（`powershell.exe`） | ✅ 內建 | 執行腳本 | 無法執行；PowerShell 7 可用但非必要 |
| .NET Framework | ✅ 內建 | XML 解析、TLS 1.2 | 隨 PowerShell 一併滿足 |
| **HWiNFO 64（官方 Inno 安裝）** | ❌ 需自行安裝 | 版本讀取、備份、更新 | 回報 `Cannot locate HWiNFO64.EXE`；可用 `-InstallDir` 指定 |
| 系統管理員權限 | ❌ 需 UAC 同意 | 寫入 Program Files、註冊最高權限排程 | `-CheckOnly` 仍可用；實際更新會失敗 |
| 可連到 `www.hwinfo.com` | ✅ 網路 | RSS、下載頁、安裝檔 | 無法取得版本資訊 |
| `winget`（App Installer） | 通常有（Win10 1809+ / Win11），但可能被移除 | **建議路徑**，比對套件 manifest 記錄的 SHA-256 | 非必要：自動改走直接下載 |
| `curl.exe` | ✅ Win10 1809+ / Win11 內建 | 快速備援下載 | 非必要：改走 `Invoke-WebRequest`，但官方 CDN 可能回 403 |
| 工作排程器 | ✅ 內建 | 每日自動執行 | 僅自動化不可用，手動執行仍可 |

**簡單說**：一般 Windows 11 電腦，你只需要準備 HWiNFO 本身、更新時按一下 UAC、以及網路。其他東西都已經在系統裡。

---

## 6. 使用情境與指令

| 情境 | 指令 |
|---|---|
| 只檢查、不安裝 | `powershell -NoProfile -ExecutionPolicy Bypass -File .\Update-HWiNFO.ps1 -CheckOnly` |
| 立即更新到最新版 | `powershell -NoProfile -ExecutionPolicy Bypass -File .\Update-HWiNFO.ps1` |
| 強制重裝同版本（修復） | `powershell -NoProfile -ExecutionPolicy Bypass -File .\Update-HWiNFO.ps1 -Force` |
| 用手動下載好的安裝檔 | `powershell -NoProfile -ExecutionPolicy Bypass -File .\Update-HWiNFO.ps1 -InstallerPath 'C:\Temp\hwi64_860.exe'` |
| 更新後不要自動開 HWiNFO | 加上 `-NoRestore` |
| 改排程時間為 18:30 | `powershell -NoProfile -ExecutionPolicy Bypass -Command "& '.\Bootstrap-HWiNFO-AutoUpdate.ps1' -TaskTime '18:30'"` |

`-InstallerPath` 仍會先讀 RSS：只有真的需要更新（或給了 `-Force`）才會用到你提供的安裝檔。

---

## 7. 參數對照表

### `Update-HWiNFO.ps1`

| 參數 | 型別 | 預設 | 說明 |
|---|---|---|---|
| `-CheckOnly` | switch | 關 | 只比對版本，不下載、不安裝 |
| `-Force` | switch | 關 | 版本已相同時仍重裝（修復用）。**不會**降版 |
| `-AllowDowngrade` | switch | 關 | 明確允許安裝比目前更舊的版本；未指定時本機版本較新就跳過 |
| `-NoRestore` | switch | 關 | 更新後不重新啟動 HWiNFO |
| `-InstallerPath` | string | 無 | 使用預先下載的安裝檔（同樣驗簽章） |
| `-InstallDir` | string | 自動偵測 | 覆寫 HWiNFO 安裝目錄 |
| `-LogPath` | string | `<腳本目錄>\Update-HWiNFO.log` | 日誌位置 |

### `Bootstrap-HWiNFO-AutoUpdate.ps1`

| 參數 | 型別 | 預設 | 說明 |
|---|---|---|---|
| `-TaskName` | string | `HWiNFO-AutoUpdate` | 排程工作名稱 |
| `-TaskTime` | string | `09:00` | 每日執行時間（`HH:mm`） |
| `-InstallerPath` | string | 無 | 轉傳給 `Update-HWiNFO.ps1` |
| `-StalePids` | int[] | 無 | 更新前先終止的舊行程 PID；只處理 PowerShell 行程且命令列含本專案腳本路徑者 |

> 從 `powershell -Command` 傳陣列請用 `-StalePids @(1234,5678)`；寫成 `-StalePids 1234,5678` 會被當成單一字串。
> `-TaskName` 不得含 `\ / : * ? " < > |`，`-TaskTime` 必須是 24 小時制 `HH:mm`；兩者都在提權**前**驗證，打錯不會留下半套設定。

---

## 8. 排程工作設定

由 Bootstrap 建立，屬性如下：

| 屬性 | 值 |
|---|---|
| 名稱 | `HWiNFO-AutoUpdate` |
| 觸發 | 每日 09:00（可用 `-TaskTime` 改） |
| 執行權限 | Highest privileges |
| 帳號 | 目前使用者，interactive logon |
| 動作 | `powershell.exe -NoProfile -ExecutionPolicy Bypass -NonInteractive -File "<repo>\Update-HWiNFO.ps1"` |
| 錯過時補跑 | 是（`StartWhenAvailable`） |
| 重複執行個體 | `IgnoreNew` |
| 逾時 | 15 分鐘 |

查看與移除：

```powershell
Get-ScheduledTask -TaskName 'HWiNFO-AutoUpdate' | Format-List
Unregister-ScheduledTask -TaskName 'HWiNFO-AutoUpdate' -Confirm:$false
```

---

## 9. 檔案、日誌與備份

| 項目 | 位置 | 用途 |
|---|---|---|
| `Update-HWiNFO.ps1` | repo 根目錄 | 版本檢查與更新主程式 |
| `Bootstrap-HWiNFO-AutoUpdate.ps1` | repo 根目錄 | 提升權限與註冊排程 |
| `lib/HWiNFO.Core.ps1` | `lib/` | 純函式（版本解析、RSS 解析、PE 檢查、簽章檢查、參數驗證），由兩支腳本與測試共用 |
| `tests/HWiNFO.Core.Tests.ps1` | `tests/` | Pester 測試；不連網、不安裝 |
| `.github/workflows/tests.yml` | `.github/` | CI：在 `windows-latest` 跑 Pester 與 PSScriptAnalyzer |
| `Update-HWiNFO.log` | repo 根目錄 | 追加式執行紀錄 |
| `Bootstrap-HWiNFO-AutoUpdate.log` | repo 根目錄 | 一次性安裝紀錄 |
| `HWiNFO-Backups/` | repo 根目錄 | 時間戳記的 `HWiNFO64.INI` 備份 |
| `%TEMP%\HWiNFO-AutoUpdate\` | 使用者暫存 | 備援路徑下載的安裝檔 |

日誌格式：

```text
yyyy-MM-dd HH:mm:ss [LEVEL] message
```

層級分為 `INFO`、`WARN`、`ERROR`。備份檔名格式為 `HWiNFO64.<yyyyMMdd-HHmmss>.INI`。腳本**不會**自動刪除備份，請依你的留存政策自行清理。

### 結束代碼

| 代碼 | 意義 |
|---|---|
| `0` | 已是最新、dry-run 完成，或更新後驗證成功 |
| `1` | 失敗：無法取得版本通知、找不到安裝目錄、下載／安裝失敗、更新後驗證失敗 |

Bootstrap 會轉回更新程式的結束碼；參數驗證失敗或排程註冊失敗時另外回 `1`。未提權的父行程會等待提權後的子行程並轉回其結束碼；只有在 Windows 不允許跨完整性層級等待時才會回 `0`，此時請看 `Bootstrap-HWiNFO-AutoUpdate.log` 的最終結果。

工作排程器在首次執行前顯示 `0x41303`（`267011`，「工作尚未執行」）是正常現象。

### 測試與 CI

```powershell
# 需要 Pester 5 以上（Windows 內建的 3.4 不支援）
Install-Module Pester -MinimumVersion 5.5.0 -Force -Scope CurrentUser
Invoke-Pester -Path ./tests -Output Detailed
```

測試刻意保持「純函式」：使用 XML fixture、Windows 內建的簽章檔案與暫存檔，因此不連網、不安裝 HWiNFO，也不需要系統管理員權限。CI（`.github/workflows/tests.yml`）在每次 push 與 PR 執行同一套測試、以 error/warning 等級跑 PSScriptAnalyzer，並用 Windows PowerShell 5.1 解析所有 `.ps1`。文件頂端的 badge 指向 `main` 最近一次執行結果，個別紀錄在 Actions 分頁。

目前沒有會真正執行升級或提權的自動化測試；那些路徑仍以 `-CheckOnly` 加人工檢視日誌驗證。

---

## 10. 疑難排解

| 現象 | 原因 | 處理方式 |
|---|---|---|
| `Cannot locate HWiNFO64.EXE` | 非標準安裝路徑或可攜版 | 加 `-InstallDir "D:\Tools\HWiNFO64"` |
| 官方 CDN 對 `Invoke-WebRequest` 回 `403` | 該用戶端被 CDN 擋下 | 腳本已優先用 `curl.exe` + 瀏覽器 UA；請保留 `curl.exe` |
| winget 下載卡住幾分鐘 | winget manifest 指向較慢的鏡像（`sac.sk`） | 等待，或改用手動下載的安裝檔 + `-InstallerPath` |
| UAC 被取消／逾時 | 提升行程根本沒啟動，未做任何異動 | 重跑 Bootstrap 並按「是」 |
| `Access denied`（`Wait-Process`／`Stop-Process`） | 非提升行程不能控制提升行程 | 從提升後的 Bootstrap 用 `-StalePids` 清理 |
| 出現 Beta 但沒安裝 | 設計如此，Beta／RC 被篩掉 | 等正式版；若確定要預發布，需修改 `Get-LatestStableVersion` |
| HWiNFO 短暫消失 | 更新前會關閉它，完成後再開 | 不希望自動開就用 `-NoRestore` |
| `Unexpected publisher '...'` 或 `Authenticode signature is not valid` | 安裝檔不是 `REALiX, s.r.o.` 簽章（代理頁面、鏡像 HTML、被竄改） | 重新從 `https://www.hwinfo.com/download/` 下載；不要繞過檢查 |
| `Refusing to stop PID=...` | 該 PID 已被 Windows 重用，現在屬於別的程式 | 什麼都沒被終止，可忽略；下次用 `-StalePids` 前先確認 PID |
| Bootstrap 回 `0` 但什麼都沒發生 | Windows 擋住跨完整性層級的等待 | 看 `Bootstrap-HWiNFO-AutoUpdate.log` 的最終結果 |
| 首次排程顯示 `267011` | 尚未到執行時間 | 無須處理 |

---

## 11. 隱私與安全稽核

公開版本已做過以下檢查與處理：

- **檔案內容**：無個人 email、本機帳號路徑、token、API key 或密碼；`README.md` 中的 `C:\Users\<you>` 是佔位符，不是實際路徑。
- **Git commit metadata**：已全面改用 `milochen0106@users.noreply.github.com`，不再暴露個人 Gmail。
- **來源限制**：版本資訊只取自官方 RSS；安裝檔只來自官方下載頁或 winget manifest。
- **雜湊驗證**：winget 路徑比對的是**套件 manifest 中記錄的 SHA-256**，不是另外由 REALiX 發布的雜湊值，因此不把它當成「發行者提供」。直接下載路徑在執行前做三項檢查：(1) PE 結構檢查（`MZ`、`e_lfanew` 處的 PE 簽章、機器類型非零、至少一個 section、PE32/PE32+ optional header）——這只是「外形」檢查，不能用來證明檔案完整；(2) Authenticode 簽章狀態為 `Valid`；(3) 以可處理引號的解析器取出憑證**組織欄位 `O`，並要求精確等於 `REALiX, s.r.o.`**。只含「REALiX」字樣或由其他發行者簽出的有效憑證都會被拒絕。比對的是法律實體而非憑證指紋，因此同一發行者換發新憑證仍可通過。
- **`-InstallerPath` 同樣驗證**：你提供的安裝檔也要通過上述三項檢查，被掉包或損毀的檔案不會被執行。
- **下載備援**：先寫入 `.part` 暫存檔，超過 10 MB 才會改名為正式檔；curl 失敗時先清掉不完整檔案，再試 `Invoke-WebRequest`。上次留下的截斷檔不會被當成成功下載。
- **PID 誤殺防護**：`-StalePids` 只接受 `powershell`／`pwsh` 且命令列含本專案腳本路徑的行程；Windows 會重用 PID，單靠 ID 不足以證明身分。
- **無憑證儲存**：腳本不保存任何憑證、token 或個人化設定，只讀取公開 HTTPS 端點與本機安裝資訊。
- **權限透明**：提升權限由 Bootstrap 明確觸發 UAC；在新的電腦上請先審視腳本再按「是」。

> 這套檢查**無法**防禦：官方 RSS 被入侵，或官方簽章程式碼簽章憑證被竊。因為信任錨點就是官方本身，RSS 被改寫或官方簽出的惡意安裝檔都會通過驗證。PE 結構檢查也無法證明檔案在簽章後沒被動過，完整性是由 Authenticode 負責。

> 補充說明：force push 已把舊 commit 從分支歷史移除，但 GitHub 短期內仍可能透過舊 SHA 直接存取該物件；若要求澈底清除，需向 GitHub Support 提出請求。

---

## 12. 設計限制

- 僅 Windows；HWiNFO 32 與 DOS 版不在範圍內。
- 只處理正式版，預發布版本刻意排除。
- 實際更新與註冊最高權限排程都需要系統管理員權限。
- 官方 HWiNFO 安裝檔在靜默安裝後仍可能自行啟動一次 HWiNFO；本工具不干涉這個內建行為。
- 版本比對只用 `major.minor`（例如 `8.60`），不使用 build number（例如 `6120`）；這與官方公開發布編號一致。
- 若官方改變 RSS 標題格式或安裝檔網址命名規則，需調整 `Get-LatestStableVersion` 或 `Get-InstallerUrl`。

---

## 13. 常見問答

**Q：它會安裝 Beta 嗎？**
不會。RSS 中的 Beta / RC 公告會被排除，這是刻意設計，避免不穩定版本進到正式環境。

**Q：執行時會不會覆蓋我的 HWiNFO 設定？**
更新前會先備份 `HWiNFO64.INI`；官方 Inno 安裝在升級時會保留既有設定。即使發生異常，你仍有時間戳備份可還原。

**Q：公司環境可以用嗎？**
HWiNFO 64 免費版僅供非商業使用。商業用途需依[官方授權](https://www.hwinfo.com/licenses/)升級 Pro；本工具只負責更新，不處理授權。

**Q：可以完全離線更新嗎？**
不行。版本通知必須連到官方 RSS，安裝檔也必須從官方來源取得。但你可以先手動下載安裝檔，再用 `-InstallerPath` 離線更新（版本檢查仍會失敗，需搭配 `-Force`）。

**Q：要怎麼確認腳本沒有亂改東西？**
先看 `-CheckOnly` 輸出，再查 `Update-HWiNFO.log`；每次更新都有版本、備份路徑、安裝檔 SHA-256 與結束碼可追溯。

---

## 14. 授權與第三方聲明

本 repo 的腳本以 [MIT License](LICENSE) 釋出。

HWiNFO® 為 Martin Malík / REALiX, s.r.o. 的註冊商標。本專案為獨立工具，**與 REALiX 無任何關聯、背書或贊助關係**。HWiNFO 軟體本身仍適用其[官方授權條款](https://www.hwinfo.com/licenses/)。

變更紀錄請見 [CHANGELOG.md](CHANGELOG.md)；漏洞回報政策請見 [SECURITY.md](SECURITY.md)。

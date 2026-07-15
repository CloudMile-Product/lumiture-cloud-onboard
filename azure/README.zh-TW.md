# LumiTure Azure 介接 SOP — Cloud Shell

> 客戶自助、**唯讀**、零安裝的引導式介接：於客戶自有 Azure 身分下，將 Azure 成本資料唯讀授權給 [LumiTure](https://app.lumiture.ai)。為 [GCP Cloud Shell 流程](../gcp/README.zh-TW.md) 的 Azure 對應版本。
> 英文版：[`README.md`](README.md)。跨雲整合版 SOP：[`../README.zh-TW.md`](../README.zh-TW.md)。

## Azure 與 GCP 流程差異

| | GCP | Azure |
|---|---|---|
| 客戶授權 | 於既有 BQ 匯出上授予 IAM | **管理員同意** LumiTure SP **＋** RBAC 角色 |
| 唯一無法腳本化的步驟 | 啟用帳單匯出（Console 專屬） | **管理員同意**（Microsoft 瀏覽器流程） |
| 原生 Shell | Google Cloud Shell（徽章自動複製 repo） | **Azure Cloud Shell**（無自動複製，需於步驟 2 自行 `git clone`） |
| 資料路徑 | 直接讀取 BQ 資料集 | Cost Management 匯出 → Blob → GCS → BigQuery |
| IaC 工具 | Terraform（`../gcp/terraform/`） | **Bicep**（`bicep/`） |

由於 Azure Cloud Shell 無 Google 那種「開啟指定 git repo + 導覽」的徽章，進入點為：開啟 Azure Cloud Shell → 自行 clone → 啟動導覽。

## ⚠️ 首次於此租戶：請先完成一次性管理員同意

LumiTure 透過**多租戶服務主體（SP）**讀取資料，該 SP 必須先由**租戶管理員**於租戶內**同意（admin consent）一次**——此為 Microsoft **瀏覽器**步驟，**無法腳本化**。

**操作**：於 LumiTure 平台 → **Authorization → Connect Azure** → 以**租戶管理員**身分登入 → **Accept（同意）**。

- 完成同意前，腳本會停在 **Phase 0** 且**不套用任何授權**。
- 同一租戶只需同意一次；同租戶內新增其他訂用帳戶時**無須再次同意**。
- 完整步驟見 [`tutorial.md` → Step 1](tutorial.md)。

## 一鍵開始

1. 開啟 **Azure Cloud Shell**：<https://shell.azure.com>（選 **Bash**）
2. 複製並進入目錄：
   ```bash
   git clone https://github.com/CloudMile-Product/lumiture-cloud-onboard.git && cd lumiture-cloud-onboard/azure
   ```
3. 依 [`tutorial.md`](tutorial.md) 逐步操作（或直接執行 `onboard-wrapper.sh`）

## 必要權限

| 角色 | 授予範圍 | 用途 | 必要性 |
|---|---|---|---|
| `Cost Management Reader` | 訂用帳戶 | 讀取成本資料 | ✅ 必要 |
| `Storage Blob Data Reader` | 儲存體帳戶（匯出檔所在） | 讀取每日成本匯出檔 | ✅ 必要 |
| `LumiTure FinOps Reader`（自訂角色） | 訂用帳戶 | VM 清單 + `Microsoft.Insights/Metrics/Read`（Rightsizing 用量） | ⬜ 選配（預設開啟） |

## 最小權限 vs 完整 FinOps（請於 POC 前決定）

| 模式 | 授予內容 | 適用 |
|---|---|---|
| **完整 FinOps（預設）** | 上表全部角色 + 建立 FOCUS 格式匯出 | 需同時評估成本與 Rightsizing |
| **最小權限（`--no-usage --no-focus`）** | 僅 `Cost Management Reader` + `Storage Blob Data Reader` + ActualCost 匯出 | 資安審查優先、POC 僅需成本可視化 |

## 本目錄檔案

| 檔案 | 用途 |
|---|---|
| `tutorial.md` | Cloud Shell 逐步導覽 |
| `onboard-wrapper.sh` | 客戶執行的互動式 bash 包裝腳本 |
| `init.sh` | 底層腳本（同意檢查 + RBAC 授權 + 成本匯出 + 表單值輸出） |
| `bicep/` | Bicep 模組——宣告式替代方案（相同角色授權 + 匯出）。見 `bicep/README.md`。 |

## 兩種執行方式

- **方式 A — bash／Cloud Shell（建議）**：零安裝、客戶自助。
- **方式 B — Bicep**：偏好 IaC、或**資安要求先審閱再授權**的團隊；以 what-if 審閱將授予之角色與資源後再套用。

兩者授予**相同角色**、建立相同匯出，並輸出**相同的精靈表單值**。

## 腳本執行內容

0. **前置檢查**：確認 LumiTure 多租戶 SP 已於租戶同意（瀏覽器步驟已於 LumiTure 精靈先行完成）。未同意則即時失敗並提示。
1. 確保 Cost Management 匯出所需的**儲存體帳戶 + 容器**存在，並設定生命週期規則，**自動刪除逾 180 天的匯出檔**（`--export-retention-days <n>` 調整、`--no-retention` 略過）——每日匯出不會去重，此規則使儲存成本維持平穩。
2. 授予 `Cost Management Reader`（訂用帳戶）與 `Storage Blob Data Reader`（儲存體帳戶）。
3. 建立每日 `ActualCost` 匯出，**並**（預設）建立 FOCUS 格式匯出（`--no-focus` 略過）。
4. **（預設）** 建立並指派**用量自訂角色** `LumiTure FinOps Reader`（VM 清單 + `Microsoft.Insights/Metrics/Read`）以取得 Rightsizing／用量資料；`Cost Management Reader` 不含 Monitor 指標。LumiTure 以列出 VM 驗證此授權。傳入 `--no-usage` 可改為最小的僅帳單授權。
5. 輸出需填回 LumiTure 精靈的表單值（或以 session token 執行時自動註冊）。

客戶本機零安裝；身分驗證全程留在客戶 Azure 帳號內；LumiTure 永不接觸客戶憑證。

## 帳單資料路徑

成本資料**並非**由 LumiTure 直接讀取客戶儲存體，而是以**事件觸發**方式擷取：

```
客戶儲存體（每日匯出檔）  →  BlobCreated 事件  →  Event Grid Webhook  →  LumiTure 擷取至自有代管儲存體
```

- 本腳本 **Phase 2.7 建立此 Event Grid 訂閱**（傳入 `--event-trigger-url`，或以 `--lumiture-api` + `--lumiture-jwt` 取得）。該端點須為可回應 Event Grid 驗證交握的正式函式端點——佔位 URL 會失敗。
- 成本資料於匯出的首次每日執行完成後（**約 24 小時**）開始入庫。

## 驗證與預期結果

| 項目 | 預期 |
|---|---|
| 資料範圍 | 同步**當月**成本資料；若於每月**前 10 日內**授權，另一併納入**前一月**（Azure 於前一月帳單結算前會持續修正，故月初一併回補前一月） |
| 資料可見時間 | 授權設定後**約 24 小時**（首次每日匯出完成後）於 LumiTure 平台看到資料 |

## 授權條款

MIT —— 見 [`../LICENSE`](../LICENSE)。

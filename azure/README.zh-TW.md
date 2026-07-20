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
3. 執行主腳本，並帶入 **LumiTure 提供的事件觸發 URL**：
   ```bash
   ./init.sh --event-trigger-url <由 LumiTure 提供的事件觸發 URL>
   ```
   > ⚠️ **`--event-trigger-url` 為必要參數，否則資料不會流入。** 未帶入時腳本仍會完成授權與建立匯出，但會**略過 Event Grid 訂閱** → 成本資料不會流入 LumiTure。**Phase 4 會偵測到並以非零狀態結束**並指出缺少訂閱；惟先前已建立的授權與匯出為實際生效，請帶入 URL 重跑，勿視為「什麼都沒發生」。此 URL 因環境而異（prod／dev／staging 不同），不列於本文件，請向 LumiTure 導入窗口索取。

   其餘參數於正式環境**皆有預設值，無需指定**：訂用帳戶＝目前 `az` 作用中訂用帳戶、租戶＝該登入之租戶、匯出儲存體＝依訂用帳戶自動命名（`ltexp…`）、資源群組＝`lumiture-billing-rg`、LumiTure SP／API＝正式環境預設、用量角色＋FOCUS 匯出＝預設開啟。

   > **多個訂用帳戶**：`./init.sh` 直接採用目前**作用中**的訂用帳戶；請以 `--subscription-id <GUID>` 明確指定：
   > ```bash
   > ./init.sh --subscription-id <GUID> --event-trigger-url <由 LumiTure 提供的事件觸發 URL>
   > ```

4. **完成介接**：將腳本輸出的表單值填回 LumiTure 精靈（<https://app.lumiture.ai/authorization/billing-integration/azure>）完成註冊。

> **補充（非必要）**：[`tutorial.md`](tutorial.md) 為逐步導覽，供需要逐項解說時參閱；直接執行 `./init.sh` 即可完成，無須先讀 tutorial。

## 必要權限

| 角色 | 授予範圍 | 用途 | 必要性 |
|---|---|---|---|
| `Cost Management Reader` | 訂用帳戶 | 讀取成本資料 | ✅ 必要 |
| `Storage Blob Data Reader` | 儲存體帳戶（匯出檔所在） | 讀取每日成本匯出檔 | ✅ 必要 |
| `LumiTure FinOps Reader`（自訂角色） | 訂用帳戶 | VM 清單 + `Microsoft.Insights/Metrics/Read`（Rightsizing 用量） | ⬜ 選配（預設開啟） |

> 上表為授予**給 LumiTure SP** 的角色。另有一個授予對象不是 LumiTure 的角色：**匯出本身的受控識別**在特定條件下需要 `Storage Blob Data Contributor`，由腳本自動處理，見[匯出的受控識別](#匯出的受控識別)。

## 最小權限 vs 完整 FinOps（請於 POC 前決定）

| 模式 | 授予內容 | 適用 |
|---|---|---|
| **完整 FinOps（預設）** | 上表全部角色 + 建立 FOCUS 格式匯出 | 需同時評估成本與 Rightsizing |
| **最小權限（`--no-usage --no-focus`）** | 僅 `Cost Management Reader` + `Storage Blob Data Reader` + ActualCost 匯出 | 資安審查優先、POC 僅需成本可視化 |

## 本目錄檔案

| 檔案 | 用途 |
|---|---|
| `init.sh` | **主腳本（請執行此檔）**——同意檢查 + RBAC 授權 + 成本匯出 + Event Grid 訂閱 + 結構自檢 + 表單值輸出 |
| `tutorial.md` | Cloud Shell 側欄逐步導覽（**非必要步驟**） |
| `bicep/` | Bicep 模組——宣告式替代方案（相同角色授權 + 匯出）。見 `bicep/README.md`。 |

## 兩種執行方式

- **方式 A — bash／Cloud Shell（建議）**：零安裝、客戶自助。
- **方式 B — Bicep**：偏好 IaC、或**資安要求先審閱再授權**的團隊；以 what-if 審閱將授予之角色與資源後再套用。需帶入 **`eventTriggerUrl`**（等同方式 A 的 `--event-trigger-url`）；套用後可由輸出 **`eventSubscriptionWired`** 確認資料路徑是否已接通。

兩者授予**相同角色**、建立相同匯出，並輸出**相同的精靈表單值**；**兩者都需要 LumiTure 提供的事件觸發 URL**，否則資料不會流入。

## 腳本執行內容

0. **前置檢查**：確認 LumiTure 多租戶 SP 已於租戶同意（瀏覽器步驟已於 LumiTure 精靈先行完成）。未同意則即時失敗並提示。
1. 確保 Cost Management 匯出所需的**儲存體帳戶 + 容器**存在，並設定生命週期規則，**自動刪除逾 180 天的匯出檔**（`--export-retention-days <n>` 調整、`--no-retention` 略過）——每日匯出不會去重，此規則使儲存成本維持平穩。
2. 授予 `Cost Management Reader`（訂用帳戶）與 `Storage Blob Data Reader`（儲存體帳戶）。
3. 建立每日 `ActualCost` 匯出，**並**（預設）建立 FOCUS 格式匯出（`--no-focus` 略過）。若建立後的匯出帶有自身的受控識別，則一併授予其儲存體寫入權限——見[匯出的受控識別](#匯出的受控識別)。
4. **（預設）** 建立並指派**用量自訂角色** `LumiTure FinOps Reader`（VM 清單 + `Microsoft.Insights/Metrics/Read`）以取得 Rightsizing／用量資料；`Cost Management Reader` 不含 Monitor 指標。LumiTure 以列出 VM 驗證此授權。傳入 `--no-usage` 可改為最小的僅帳單授權。
5. 建立 **Event Grid 訂閱**（`BlobCreated` → LumiTure webhook，即資料路徑）——**僅在帶入 `--event-trigger-url` 時執行**；未帶入時顯示警告並略過，且下述 Phase 4 檢查會**使整個執行失敗**。
6. **（預設）** 回補 **3 個月歷史資料**：以一次性匯出建立，**每月一個**，讓首次進入儀表板即可看到趨勢而非僅有當月（`--backfill-months <n>` 調整、`--backfill-months 0` 略過）。
7. **Phase 4 結構自檢**：回讀實際狀態，確認兩個匯出皆存在且指向本次推導出的儲存體、每個匯出受控識別皆具寫入權、Event Grid 訂閱指向所帶入的觸發 URL。見[失敗即中止](#失敗即中止)。
8. 輸出需填回 LumiTure 精靈的表單值。

客戶本機零安裝；身分驗證全程留在客戶 Azure 帳號內；LumiTure 永不接觸客戶憑證。

> **歷史資料只在介接當下取得，錯過就沒有。** LumiTure 的服務主體為**唯讀**授權，無法建立 Cost Management 匯出，而匯出是取得歷史 FOCUS 資料的唯一途徑。本腳本以**客戶自身（訂用帳戶 Owner）**身分執行，因此是唯一能執行回補的時機。若以 `--backfill-months 0` 介接，日後要補回這段歷史必須重跑腳本。

## 帳單資料路徑

成本資料**並非**由 LumiTure 直接讀取客戶儲存體，而是以**事件觸發**方式擷取：

```
客戶儲存體（每日匯出檔）  →  BlobCreated 事件  →  Event Grid Webhook  →  LumiTure 擷取至自有代管儲存體
```

- 本腳本 **Phase 2.7 建立此 Event Grid 訂閱**（傳入 `--event-trigger-url`，或以 `--lumiture-api` + `--lumiture-jwt` 取得）。該端點須為可回應 Event Grid 驗證交握的正式函式端點——佔位 URL 會失敗。
- 成本資料於匯出的首次每日執行完成後（**約 24 小時**）開始入庫。

## 匯出的受控識別

Cost Management 匯出在寫入儲存體時，用的**不是** LumiTure 的服務主體，而是**匯出本身的識別**。

當儲存體**停用共用金鑰（shared key）存取**時（CSP 與企業資安政策下常見），Azure 會為匯出建立一組受控識別，並改以該識別寫入。此識別需具備儲存體的 `Storage Blob Data Contributor`，否則每次匯出執行都會以 `AccessToStorageAccountDenied` 失敗——**且 Azure 不會有任何提示**：匯出存在、於 Portal 顯示正常，只是不產生任何檔案。

腳本會在建立匯出後檢查是否有此識別，有就自動補上該角色（重複執行不影響）。這一步只有腳本做得到，因為它以**客戶自身（訂用帳戶 Owner）**身分執行；LumiTure 的唯讀 SP 無權授予角色，**事後無法由 LumiTure 端補救**。若儲存體允許共用金鑰，匯出不會有此識別，腳本即略過。

## 失敗即中止

任何會導致管線半接通的狀況——匯出或角色建立失敗、缺少 Event Grid 訂閱、匯出指向其他儲存體、匯出識別缺少寫入權——都會被收集，腳本**以非零狀態結束並逐項列出問題**。因此綠色的 `Azure onboarding complete` 代表結構已回讀並通過檢查，而非僅代表腳本跑完。

Phase 4 刻意只驗**結構、不驗資料**：匯出自隔日起算，執行當下尚未產生任何資料。成本資料約 1 天後才會入庫，請於**隔日**確認儀表板，而非當下。

> **同名、但指向另一個儲存體的第二個匯出**：通常是先前執行殘留下來的，會使資料分流到兩處。Phase 4 會提出警告，請至 Portal 刪除——由 CLI 以名稱刪除會刪到錯的那一個。

## 驗證與預期結果

| 項目 | 預期 |
|---|---|
| 資料範圍 | 介接當下回補**前 3 個月**歷史（預設，`--backfill-months` 調整）＋持續同步**當月**；若於每月**前 10 日內**授權，另一併納入**前一月**（Azure 於前一月帳單結算前會持續修正，故月初一併回補前一月） |
| 歷史資料時效 | **僅於介接當下可取得**；`--backfill-months 0` 略過後，日後補回需重跑腳本 |
| 資料可見時間 | 授權設定後**約 24 小時**（首次每日匯出完成後）於 LumiTure 平台看到資料 |
| 腳本結束狀態 | 結構檢查（Phase 4）全數通過才輸出 `Azure onboarding complete` 並以 0 結束；任一項不通過則列出問題並以**非零**結束——此時請勿進入下一步，先排除後重跑 |

## 授權條款

MIT —— 見 [`../LICENSE`](../LICENSE)。

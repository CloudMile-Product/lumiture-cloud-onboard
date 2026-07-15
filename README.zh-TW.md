# LumiTure 雲端帳單資料介接 — 部署 SOP（GCP / Azure）

> **文件性質**：客戶自助部署標準作業程序（SOP）
> **對象**：客戶端 IT／雲端管理人員
> **原則**：**唯讀（read-only）**、**零安裝**、全程於**客戶自有雲端身分**下執行；LumiTure **不接觸、不儲存任何客戶憑證**。

---

## 1. 文件目的與適用範圍

本文件說明將客戶 GCP／Azure 的**帳單／成本資料**唯讀介接至 [LumiTure](https://app.lumiture.ai) 所需的**權限、前置設定、操作步驟與驗證方式**，供客戶 IT 於 POC 或正式導入前，先行**確認並配置測試環境中的各項必要權限**。

- 適用雲端：**GCP**、**Azure**（AWS 規劃中，暫不在本文件範圍）。
- 兩朵雲各自獨立，可**擇一或並行**導入；彼此無相依。
- 每項授權皆提供**兩種執行方式**：
  - **方式 A — 引導式 Cloud Shell**：於雲端原生 Shell 一鍵引導，零安裝。
  - **方式 B — IaC（Terraform／Bicep）**：宣告式套用，供偏好基礎設施即程式碼、或需先行審閱後再套用的團隊使用。

---

## 2. 授權原則（資訊安全說明）

| 項目 | 說明 |
|---|---|
| 存取權限 | **LumiTure 取得的權限僅為唯讀**：所有授予 LumiTure 的角色皆為 Viewer／Reader 等級；LumiTure 無法寫入、刪除或變更貴司任何資源組態。 |
| 執行身分 | 授權與前置佈建皆由**客戶自己的雲端管理員身分**執行（見 [2.1](#21-部署過程將於貴司環境建立變更的資源)），LumiTure 端僅取得被授予的唯讀角色。 |
| 憑證 | LumiTure **永不接觸客戶帳號密碼或金鑰**。GCP 以既有身分於 Cloud Shell 執行；Azure 以多租戶服務主體（SP）經一次性管理員同意介接。 |
| 透明度 | 所有授權邏輯為公開原始碼（本 repo，MIT 授權）。Terraform／Bicep 內容可**在套用前完整審閱**，確認每一項被授予的權限與建立的資源。 |
| 資料流向 | 僅擷取帳單／成本與（選配）用量指標資料；不觸及業務資料、應用程式或工作負載內容。 |

### 2.1 部署過程將於貴司環境建立／變更的資源

> 為求透明，以下列出**佈建腳本（或 IaC）以貴司管理員身分**在貴司環境建立或變更的項目。這些是介接所需的前置資源，**並非**由 LumiTure 執行——LumiTure 僅持有唯讀角色，無權執行下列任何動作。

| 雲端 | 建立／變更項目 | 說明 |
|---|---|---|
| **GCP** | IAM 角色繫結 | 於帳單匯出資料集與帳單帳戶，新增授予 LumiTure 唯讀服務帳戶的角色繫結；**不建立其他資源**。 |
| **Azure** | 儲存體帳戶 + 容器 | 供 Cost Management 匯出落地（若已存在則沿用）。 |
| **Azure** | 每日 Cost Export | 建立 `ActualCost` 匯出；預設另建 FOCUS 格式匯出（`--no-focus` 可略過）。 |
| **Azure** | 自訂角色 `LumiTure FinOps Reader` + 指派 | 供 Rightsizing 讀取 VM 清單與監視器指標；角色本身僅含唯讀權限。`--no-usage` 可略過。 |
| **Azure** | Event Grid 訂閱 | 將 `BlobCreated` 事件送至 LumiTure 擷取端點（見 [5.5](#55-資料流event-grid-觸發)）。 |
| **Azure** | 儲存體生命週期規則 | **自動刪除逾 180 天的匯出檔**——每日匯出不會去重，此規則避免儲存成本持續累積。僅作用於**匯出容器內的匯出檔**，不影響其他資料。可用 `--export-retention-days <n>` 調整，或 `--no-retention` 不建立此規則。 |

---

## 3. 權限總覽（快速對照表）

> 供資安審查快速核對。詳細操作見第 4（GCP）、第 5（Azure）節。

| 雲端 | 功能範圍 | 角色／權限 | 授予範圍（Scope） | 是否必要 |
|---|---|---|---|---|
| **GCP** | 帳單／成本（核心） | `BigQuery Data Viewer` | 帳單匯出資料集（BQ dataset） | ✅ 必要 |
| **GCP** | 帳單／成本（核心） | `Billing Account Viewer`（`roles/billing.viewer`） | 帳單帳戶（Billing Account） | ✅ 必要 |
| **GCP** | VM Rightsizing（用量） | `Cloud Monitoring Viewer`（`roles/monitoring.viewer`） | Scoping 專案 | ⬜ 選配 |
| **Azure** | 帳單／成本（核心） | `Cost Management Reader` | 訂用帳戶（Subscription） | ✅ 必要 |
| **Azure** | 帳單／成本（核心） | `Storage Blob Data Reader` | 儲存體帳戶（匯出檔所在） | ✅ 必要 |
| **Azure** | VM Rightsizing（用量） | `LumiTure FinOps Reader`（自訂角色：VM 清單 + `Microsoft.Insights/Metrics/Read`） | 訂用帳戶 | ⬜ 選配（預設開啟） |

> **用量功能為選配**：若 POC 階段僅需成本可視化、暫不評估 Rightsizing，可採**最小權限**路徑，僅授予上表標示「必要」之角色（GCP 略過 Monitoring Viewer；Azure 以 `--no-usage` 略過 FinOps Reader）。

---

## 4. GCP 部署程序

### 4.1 前置條件

1. **已於 GCP Console 啟用 BigQuery 帳單匯出（含定價 / Detailed Usage Cost）。**
   此為 Console 專屬步驟，無法由腳本代為開啟。
   建議於**正式介接前 24 小時完成**，以確保匯出資料表已開始累積資料。
2. 執行者需具備於**帳單帳戶**與**匯出資料集**上授予 IAM 角色之權限（一般為帳單管理員／專案 IAM 管理員）。

### 4.2 必要權限清單

| 角色 | 授予範圍 | 用途 | 必要性 |
|---|---|---|---|
| `BigQuery Data Viewer` | 帳單匯出資料集 | 讀取帳單與定價明細 | ✅ 必要 |
| `Billing Account Viewer` | 帳單帳戶 | 帳單帳戶層級檢視（介接驗證所需） | ✅ 必要 |
| `Cloud Monitoring Viewer` | Scoping 專案 | VM Rightsizing 用量指標 | ⬜ 選配 |

> 授予對象為 **LumiTure 唯讀服務帳戶**；其位址由 LumiTure 精靈提供，腳本亦已預設帶入正式環境服務帳戶。

### 4.3 操作步驟

#### 方式 A — 引導式 Cloud Shell（建議）

1. 於 LumiTure 平台開啟 GCP 介接精靈，取得專屬的 **Open in Cloud Shell** 連結／徽章。
2. 點擊後，Google Cloud Shell 以「終端機 + 導覽」版面開啟，依側欄 `tutorial.md` 逐步操作。
3. 腳本將自動：
   1. 探索客戶的 Cloud Billing Account 與 BigQuery 匯出資料集；
   2. 驗證匯出是否已產生資料；
   3. 於匯出資料集授予 `BigQuery Data Viewer`、於帳單帳戶授予 `Billing Account Viewer`；
   4. （選配 `--with-usage`）於 Scoping 專案授予 `Cloud Monitoring Viewer`；
   5. 輸出需貼回 LumiTure 精靈的**表單值（form values）**。
4. 將輸出的表單值填回 LumiTure 精靈，完成介接。

> **最小權限（僅成本）**：省略 `--with-usage`，即不授予 Monitoring Viewer。
> **已完成帳單介接、僅補用量**：以 `--skip-billing --scoping-project <專案ID>` 執行，僅追加 Monitoring Viewer。

#### 方式 B — Terraform（宣告式／可審閱）

適合希望**先審閱、再套用**或需可重複套用的團隊。

1. 取得 `gcp/terraform/` 模組，參考 `terraform/README.md` 與 `terraform/examples/`。
2. 填入變數（帳單帳戶、匯出資料集、Scoping 專案、LumiTure 服務帳戶）。
3. 執行 `terraform plan` **完整審閱將授予之角色**，確認無誤後 `terraform apply`。
4. 授予之角色與輸出表單值與方式 A 完全一致。

### 4.4 驗證與預期結果

| 項目 | 預期 |
|---|---|
| 歷史資料回補 | 首次同步回補**近 3 個月**歷史資料 |
| 資料可見時間 | 授權完成後，LumiTure **隨即觸發首次同步**；資料實際出現於平台的時間，取決於 **GCP BigQuery 帳單匯出產出資料的時間**（GCP 端行為，帳單匯出通常較實際用量延遲約 1 天），無法保證固定時間 |

---

## 5. Azure 部署程序

### 5.0 ⚠️ 一次性系統管理員同意（必須最先執行）

LumiTure 透過**多租戶服務主體（SP）**讀取資料，該 SP 必須先由**租戶管理員**於租戶內**同意（admin consent）一次**。此為 Microsoft **瀏覽器**流程，**無法由腳本執行**。

**操作**：於 LumiTure 平台 → **Authorization → Connect Azure** → 以**租戶管理員**身分登入 → **Accept（同意）**。

- 完成同意前，後續腳本會停在 **Phase 0** 且**不會套用任何授權**。
- 同一租戶只需同意一次；同租戶內新增其他訂用帳戶時**無須再次同意**。

### 5.1 前置條件

1. 已完成 **5.0 管理員同意**。
2. 執行者具備於**訂用帳戶**指派 RBAC 角色、以及建立**儲存體帳戶／容器**與 **Cost Management 匯出**之權限。
3. 於 Azure Cloud Shell（Bash）操作（無需本機安裝）。

### 5.2 必要權限清單

| 角色 | 授予範圍 | 用途 | 必要性 |
|---|---|---|---|
| `Cost Management Reader` | 訂用帳戶 | 讀取成本資料 | ✅ 必要 |
| `Storage Blob Data Reader` | 儲存體帳戶（匯出檔所在） | 讀取每日成本匯出檔 | ✅ 必要 |
| `LumiTure FinOps Reader`（自訂角色） | 訂用帳戶 | VM 清單 + 監視器指標（Rightsizing 用量） | ⬜ 選配（預設開啟） |

### 5.3 最小權限 vs 完整 FinOps（請於 POC 前決定）

| 模式 | 授予內容 | 適用 |
|---|---|---|
| **完整 FinOps（預設）** | 上表全部角色 + 建立 FOCUS 格式匯出 | 需同時評估成本與 Rightsizing |
| **最小權限（`--no-usage --no-focus`）** | 僅 `Cost Management Reader` + `Storage Blob Data Reader` + ActualCost 匯出 | 資安審查優先、POC 階段僅需成本可視化 |

### 5.4 操作步驟

#### 方式 A — 引導式 Azure Cloud Shell（建議）

1. 確認 **5.0 管理員同意**已完成。
2. 開啟 **Azure Cloud Shell**（<https://shell.azure.com>，選 **Bash**）。
3. 複製並進入目錄：
   ```bash
   git clone https://github.com/CloudMile-Product/lumiture-cloud-onboard.git && cd lumiture-cloud-onboard/azure
   ```
4. 依 `tutorial.md` 逐步執行（或直接執行 `onboard-wrapper.sh`）。腳本將：
   1. 前置檢查 SP 是否已於租戶同意（未同意則停止並提示）；
   2. 確保匯出用的儲存體帳戶／容器存在，並設定生命週期規則，**自動刪除逾 180 天的匯出檔**（`--export-retention-days <n>` 調整、`--no-retention` 略過）；
   3. 授予 `Cost Management Reader`（訂用帳戶）與 `Storage Blob Data Reader`（儲存體帳戶）；
   4. 建立每日 `ActualCost` 匯出，並（預設）建立 FOCUS 格式匯出（`--no-focus` 略過）；
   5. （預設）建立並指派自訂角色 `LumiTure FinOps Reader`（`--no-usage` 略過）；
   6. 建立 **Event Grid 訂閱**（見 5.5）；
   7. 輸出需填回 LumiTure 精靈的表單值。
5. 將表單值填回 LumiTure 精靈，完成介接。

#### 方式 B — Bicep（宣告式／可審閱）

1. 取得 `azure/bicep/` 模組，參考 `bicep/README.md`。
2. 填入參數後，先以 what-if／plan **審閱將授予之角色與資源**，確認後套用。
3. 授予之角色、匯出與表單值與方式 A 一致。

### 5.5 資料流（Event Grid 觸發）

成本資料**並非**由 LumiTure 直接讀取客戶儲存體，而是以**事件觸發**方式擷取：

```
客戶儲存體（每日匯出檔）  →  BlobCreated 事件  →  Event Grid Webhook  →  LumiTure 擷取至自有代管儲存體
```

- 腳本會於 Phase 2.7 建立此 Event Grid 訂閱（webhook 端點由 LumiTure 提供，需為可回應 Event Grid 驗證交握的正式端點）。

### 5.6 驗證與預期結果

| 項目 | 預期 |
|---|---|
| 資料範圍 | 同步**當月**成本資料；若於每月**前 10 日內**授權，另一併納入**前一月**（Azure 於前一月帳單結算前會持續修正，故月初一併回補前一月） |
| 資料可見時間 | 授權設定後**約 24 小時**（首次每日匯出完成後）於 LumiTure 平台看到資料 |

---

## 6. 資料時效總覽

| 雲端 | 歷史回補 | 資料可見時間 |
|---|---|---|
| GCP | 近 3 個月 | 授權後隨即觸發同步；實際出現時間視 **GCP 帳單匯出產出**而定（GCP 端，通常延遲約 1 天） |
| Azure | 當月（每月前 10 日內另含前一月） | 授權後約 **24 小時** |

---

## 7. 疑難排解（FAQ）

| 情境 | 處理方式 |
|---|---|
| Azure 腳本停在 Phase 0 | 尚未完成 **5.0 管理員同意**；請先於 LumiTure → Authorization → Connect Azure 完成同意。 |
| GCP 找不到匯出資料集 / 無資料 | 確認 BigQuery 帳單匯出（含定價）已啟用，且已累積至少數小時資料（建議上線前 24h 啟用）。 |
| 平台遲遲看不到資料 | GCP：資料出現時間取決於 GCP BigQuery 帳單匯出產出（通常延遲約 1 天）；Azure：待每日 Cost Export 首次完成（約 24 小時）。若明顯超過上述時間，請提供介接時間與訂用帳戶／專案資訊予窗口。 |
| 只想要成本、暫不要 Rightsizing | GCP：省略 `--with-usage`；Azure：以 `--no-usage --no-focus` 執行（最小權限）。 |
| 資安要求先審閱再授權 | 採**方式 B（Terraform／Bicep）**，以 `plan` / what-if 審閱全部角色後再套用。 |

---

## 8. 聯絡窗口

- 技術／部署問題：請聯繫 LumiTure 導入窗口（CloudMile 團隊）。
- 本 repo 為公開原始碼（MIT 授權），所有授權邏輯可完整審閱；英文版說明見各雲資料夾之 `README.md`（[`gcp/`](gcp/README.md)、[`azure/`](azure/README.md)）。

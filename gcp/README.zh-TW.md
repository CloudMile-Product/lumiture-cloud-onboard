# LumiTure GCP 介接 SOP — Cloud Shell

> 客戶自助、**唯讀**、零安裝的引導式介接：於客戶自有 Google 身分下，將 GCP 帳單資料唯讀授權給 [LumiTure](https://app.lumiture.ai)。LumiTure 永不接觸客戶憑證。
> 英文版：[`README.md`](README.md)。跨雲整合版 SOP：[`../README.zh-TW.md`](../README.zh-TW.md)。

## 一鍵開始

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://shell.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https://github.com/CloudMile-Product/lumiture-cloud-onboard&cloudshell_tutorial=gcp/tutorial.md&cloudshell_workspace=gcp&show=terminal)

點擊徽章 → Google Cloud Shell 以「**終端機 + 導覽**」版面開啟（`show=terminal`，不含 IDE 編輯器）→ 依側欄導覽逐步操作 → 完成。

## 前置條件

1. **已於 GCP Console 啟用 BigQuery 帳單匯出（含定價 / Detailed Usage Cost）。** 此為 Console 專屬步驟，無法由腳本代為開啟；建議於**正式介接前 24 小時完成**，確保匯出表已開始累積資料。
2. 執行者具備於**帳單帳戶**與**匯出資料集**授予 IAM 角色之權限（帳單管理員／專案 IAM 管理員）。

## 必要權限

| 角色 | 授予範圍 | 用途 | 必要性 |
|---|---|---|---|
| `BigQuery Data Viewer` | 帳單匯出資料集 | 讀取帳單與定價明細 | ✅ 必要 |
| `Billing Account Viewer`（`roles/billing.viewer`） | 帳單帳戶 | 帳單帳戶層級檢視（介接驗證所需） | ✅ 必要 |
| `Cloud Monitoring Viewer`（`roles/monitoring.viewer`） | Scoping 專案 | VM Rightsizing 用量指標 | ⬜ 選配 |

> 授予對象為 **LumiTure 唯讀服務帳戶**；其位址由 LumiTure 精靈提供，腳本亦已預設帶入正式環境服務帳戶。

## 本目錄檔案

| 檔案 | 用途 |
|---|---|
| `tutorial.md` | Cloud Shell 側欄逐步導覽 |
| `onboard-wrapper.sh` | 客戶於導覽中執行的互動式 bash 包裝腳本 |
| `init.sh` | 底層介接腳本（探索 + IAM 授權 + 表單值輸出） |
| `terraform/` | Terraform 模組——bash 流程的宣告式替代方案（相同 IAM 授權 + 選配自動提交）。見 `terraform/README.md` 與 `terraform/examples/`。 |

## 兩種執行方式

- **方式 A — bash／Cloud Shell（建議）**：零安裝、客戶自助，即上方一鍵徽章流程。
- **方式 B — Terraform**：偏好 IaC／需可重複套用、或**資安要求先審閱再授權**的團隊；以 `terraform plan` 完整審閱將授予之角色後再 `apply`。

兩者授予**相同兩個角色**並輸出**相同的精靈表單值**。

## 腳本執行內容

1. 探索客戶的 Cloud Billing Account 與 BigQuery 匯出資料集；
2. 驗證匯出是否已產生資料；
3. 於匯出資料集授予 `BigQuery Data Viewer`、於帳單帳戶授予 `Billing Account Viewer`（兩者皆為 LumiTure 介接驗證所需）；
4. **（選配 `--with-usage`）** 於 **Scoping 專案**（預設同 `--export-project`，可用 `--scoping-project` 覆寫）授予 `roles/monitoring.viewer` 以取得用量／Rightsizing 指標，並選配透過 `/platforms/gcp/usage/integration` 註冊。此為 Cloud **Monitoring** 路徑，與帳單面的「Detailed Usage Cost」資料集（純成本資料）不同；
5. 輸出需貼回 LumiTure 精靈的**表單值**。

客戶本機零安裝；身分驗證全程留在客戶 Google 帳號內；LumiTure 永不接觸客戶憑證。

## 常見選項

- **最小權限（僅成本）**：省略 `--with-usage`，即不授予 Monitoring Viewer。
- **已完成帳單介接、僅補用量**：以 `--skip-billing`（usage-only）執行——略過所有帳單探索／授權，僅做 `monitoring.viewer` 授權 + 選配用量提交。此選項隱含 `--with-usage`、需 `--scoping-project`，且不需 `bq` 或 ADC：
  ```bash
  ./init.sh --skip-billing \
    --scoping-project <專案ID> \
    --lumiture-sa <SA-email>          # 預設為正式環境 SA；如不同請自行帶入
  ```

> ⚠️ **勿混淆**：GCP 的「**Detailed Usage Cost**」是帳單匯出**資料集**（純成本）；`--with-usage` 則是 Monitoring **指標**（Rightsizing）。腳本的 `--detailed-usage-dataset` 屬帳單面、`--with-usage` 屬用量面。

## 驗證與預期結果

| 項目 | 預期 |
|---|---|
| 歷史資料回補 | 首次同步回補**近 3 個月**歷史資料 |
| 資料可見時間 | 授權完成後，LumiTure **隨即觸發首次同步**；資料實際出現於平台的時間，取決於 **GCP BigQuery 帳單匯出產出資料的時間**（GCP 端行為，帳單匯出通常較實際用量延遲約 1 天），無法保證固定時間 |

## 授權條款

MIT —— 見 [`LICENSE`](../LICENSE)。

# LumiTure AWS 介接 SOP — CloudShell / CloudFormation

> 客戶自助、零安裝的引導式介接：於客戶自有 AWS 身分下，建立跨帳號 IAM 角色，授權 [LumiTure](https://app.lumiture.ai) 建置帳單匯出。為 [GCP Cloud Shell 流程](../gcp/README.zh-TW.md) 與 [Azure 流程](../azure/README.zh-TW.md) 的 AWS 對應版本。
> 英文版：[`README.md`](README.md)。跨雲整合版 SOP：[`../README.zh-TW.md`](../README.zh-TW.md)。

## AWS 與 GCP／Azure 流程差異

| | GCP | Azure | AWS |
|---|---|---|---|
| 客戶授權 | 於既有 BQ 匯出上授予 IAM | 管理員同意 + RBAC 角色 | **跨帳號 IAM 角色 + ExternalId** |
| 資料管線由誰建置 | 客戶（匯出已存在） | 客戶（腳本建立匯出） | **LumiTure**——擔任（assume）該角色後自行建立 bucket 與匯出 |
| 無法腳本化的步驟 | 啟用帳單匯出（Console 專屬） | 管理員同意（瀏覽器） | ——無—— |
| 原生 Shell | Google Cloud Shell（徽章自動複製 repo） | Azure Cloud Shell | **AWS CloudShell**（無自動複製，需自行 `git clone`） |
| IaC 工具 | Terraform（`../gcp/terraform/`） | Bicep（`../azure/bicep/`） | **CloudFormation**（`cloudformation/`） |

客戶端只需建立一組角色＋政策（其餘由 LumiTure 建置），是三朵雲中最輕量的流程；但此授權**並非純唯讀**：政策允許 S3 寫入與帳單匯出管理，惟寫入僅限兩個專用 bucket（`lumiture-<帳號>-cur` / `-focus`）。詳見[權限邊界](#必要權限與邊界)。

## 前置條件

- ⚠️ **必須於 Organization 管理帳號（付款帳號，management/payer account）執行。** 成員帳號會被拒絕——本腳本與 LumiTure 後端都會擋下——因為將成員帳號誤當付款帳號介接，曾造成帳單資料毀損。無 Organization 的獨立帳號可正常介接（僅不適用用量 StackSet）。
- 執行者需具備 IAM 管理權限（建立角色與政策）。
- 帳號的帳單匯出配額需有餘裕：AWS 上限為 CUR 5 個／FOCUS 2 個，LumiTure 會各建立 1 個（腳本會先檢查）。

## 一鍵開始

1. 開啟 **AWS CloudShell**：<https://console.aws.amazon.com/cloudshell/>（任一區域皆可）
2. 複製並進入目錄：
   ```bash
   git clone https://github.com/CloudMile-Product/lumiture-cloud-onboard.git && cd lumiture-cloud-onboard/aws
   ```
3. 執行主腳本：
   ```bash
   ./init.sh
   ```
   其餘參數於正式環境**皆有預設值，無需指定**：角色＝`LumiTureIntegrationRole`、政策＝`LumiTureIntegrationPolicy`、ExternalId＝沿用既有角色上的值／以 session token 取得／本地產生、LumiTure API＝正式環境。
4. **完成介接**：將腳本輸出的表單值填回 LumiTure 精靈（<https://app.lumiture.ai/authorization/billing-integration/aws>）——先按 **Check Permission** 通過後再按 **Integrate**。帶入 `--lumiture-jwt <token>` 則由腳本自動送出（含 IAM 權限傳播延遲的自動重試）。

> **補充（非必要）**：[`tutorial.md`](tutorial.md) 為逐步導覽；直接執行 `./init.sh` 即可完成。

## 必要權限與邊界

授予 LumiTure 的是**一組跨帳號角色**（信任 `arn:aws:iam::536697256548:root`＋ExternalId 條件、無 MFA 條件），附掛一份**內容固定**的政策：

| LumiTure 可以 | LumiTure 不可以 |
|---|---|
| 建立／管理帳單匯出（`bcm-data-exports`、`cur`） | 讀取或碰觸任何工作負載（無 EC2/S3/RDS 資料存取） |
| 建立並寫入兩個專用 bucket（`lumiture-<帳號>-cur` / `-focus`，以 ARN 鎖定） | 寫入**其他任何** S3 bucket |
| 列出 Organization 帳號、讀取帳號別名、讀取自身角色／政策 | 修改 IAM、建立使用者、權限提升 |
| 讀取 CloudWatch 指標與 EC2 執行個體*中繼資料*（用量選配） | 啟動／停止／變更任何資源 |

> ⚠️ **政策內容為精確比對契約**：LumiTure 以**完全相等**（非子集合）驗證政策文件。請勿手動增刪動作或調整順序——任何修改都會使權限檢查失敗。政策漂移時重跑 `./init.sh` 即可改回。

## 本目錄檔案

| 檔案 | 用途 |
|---|---|
| `init.sh` | **主腳本（請執行此檔）**——管理帳號檢查 + 配額檢查 + 政策／角色建立 + 結構自檢 + 表單值輸出 |
| `onboard-wrapper.sh` | `init.sh` 的互動式包裝（確認提示、位置參數） |
| `tutorial.md` | CloudShell 逐步導覽（**非必要步驟**） |
| `cloudformation/` | CloudFormation 範本——宣告式替代方案（相同角色＋政策，表單值為 stack Outputs）。見 `cloudformation/README.md`。 |

## 兩種執行方式

- **方式 A — bash／CloudShell（建議）**：零安裝、客戶自助。
- **方式 B — CloudFormation**：偏好 IaC、或**資安要求先審閱再授權**的團隊；範本內即為將建立的完整政策與信任內容，可先審閱再套用（Console 上傳或 CLI `create-stack`）。

兩者建立**相同的角色＋政策**、輸出**相同的精靈表單值**。兩者擇一，**請勿都跑**（資源名稱會衝突）。

## 腳本執行內容

1. **管理帳號檢查**：成員帳號直接拒絕；獨立帳號放行（略過用量 StackSet）。
2. **配額檢查**：計算既有 CUR／FOCUS 匯出數（上限 5／2），不足時提前失敗，而非留給 LumiTure 的配額檢查晚點才報錯。
3. 建立客戶管理政策——**內容與 LumiTure 驗證文件完全一致**；偵測到舊版本漂移時就地更新（新增預設版本）。
4. 建立跨帳號角色（信任 LumiTure 帳號＋ExternalId、無 MFA 條件）並附掛政策；重跑時**沿用既有 ExternalId**（已送出的表單值不失效）。
5. **（選配，`--with-usage`）** 部署成員帳號監控 StackSet——見[用量整合（選配）](#用量整合選配)。
6. **Phase 5 結構自檢**：回讀實際狀態——信任主體與 ExternalId、政策已附掛、政策文件與預期完全相等（即 LumiTure 權限檢查的同一種比對）。
7. 輸出表單值（或以 `--lumiture-jwt` 自動送出：權限檢查 → 整合 → 用量）。

客戶本機零安裝；身分驗證全程留在客戶 AWS 帳號內；LumiTure 只能透過 ExternalId 把關的 AssumeRole 取得受限權限，永不接觸客戶憑證。

## 用量整合（選配）

Rightsizing／用量資料需要於**每個成員帳號**部署一組唯讀監控角色，透過 LumiTure 的 CloudFormation **StackSet**（service-managed，自動涵蓋新帳號）完成。`--with-usage`（wrapper 用 `WITH_USAGE=1`）自動化以下步驟：

1. 啟用 Organization 的 **CloudFormation StackSets 信任存取**（一次性、全組織生效——此為預設不開啟、需明確選配的原因）。
2. 以 **LumiTure 託管的範本 URL** 建立 StackSet——LumiTure 會逐位元組比對部署範本與託管副本，故腳本一律用 `--template-url`，絕不用本地檔案。
3. 部署 stack instances 至組織根（或以 `--ou-ids` 縮小範圍），等待完成；失敗比例超過一半（LumiTure 的門檻）則整體失敗。
4. 於帳單整合成功後送出 `stackset_name`／`role_name`／用量 `external_id`——用量的 ExternalId 與帳單的**是兩個不同的值**。

帳單必須先接通；用量可日後再由[用量精靈](https://app.lumiture.ai/authorization/usage-integration/aws)補做。

> **重跑且 StackSet 已存在時**：ExternalId 參數為 NoEcho（寫入後讀不回來）。請保留**建立當次**的值，或以 `--usage-external-id` 帶入相同值。

## 驗證與預期結果

| 項目 | 預期 |
|---|---|
| 資料範圍 | **本計費月份自 1 日至今日**的資料，每日更新；不會回補先前月份 |
| 資料可見時間 | 送出整合後**約 24 小時**（AWS 首次每日匯出完成後）於 LumiTure 平台看到資料 |
| 腳本結束狀態 | 結構自檢（Phase 5）全數通過才輸出 `AWS onboarding complete` 並以 0 結束；任一項不通過則列出問題、**略過自動送出**並以**非零**結束——請先排除再重跑 |
| 權限檢查失敗最常見原因 | 政策文件與預期不完全一致（曾手動修改／順序不同）——重跑 `./init.sh` 改回即可；剛建好角色的第一次檢查偶因 IAM 傳播延遲失敗，重按一次即可 |

## 授權條款

MIT —— 見 [`../LICENSE`](../LICENSE)。

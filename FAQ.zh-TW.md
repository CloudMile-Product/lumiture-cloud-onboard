# LumiTure 常見問答 — 會讀取哪些資料、不會讀取哪些資料

客戶資安或採購審閱時最常問的問題。

---

## Q1. 帳單明細的每一列有哪些欄位？

- 帳號、project、subscription、resource group
- 服務與 SKU
- 資源 ID 與名稱
- 標籤（label、tag）
- 用量數量、單價、金額

## Q2. AI 服務（例如 Azure AI Foundry）看得到什麼？

看得到各模型對應的計價項目，以及 token 數（記錄在用量數量欄位）。**看不到 prompt 與回應內容。**

目前只驗證過 Azure AI Foundry；其他雲的 AI 服務是否同樣帶有 token 數，尚未確認。

## Q3. 做 Rightsizing 建議時，會多讀哪些資料？

這部分需要另外授權（見 Q6），只讀兩類資料：

- **資源資料**：VM 名稱與 ID、所在帳號／project／subscription／resource group、區域、規格（machine type、instance type、VM size）、標籤。Azure 與 AWS 另可讀取運作狀態（運作中或停止）。
- **用量指標**：每台 VM 的 CPU 使用率，以及磁碟與網路的存取次數（ops/s）。

只有數字，不含程式或資料內容。

## Q4. 記憶體使用率一定讀得到嗎？

不一定，要 VM 有提供這個指標：

- **GCP**：只有部分機型會產生記憶體指標，一般 VM 沒有資料。
- **AWS**：需在 VM 上安裝 CloudWatch agent。
- **Azure**：讀取平台提供的「可用記憶體百分比」。

沒有記憶體資料時，規格建議會缺少記憶體這一項依據，不會憑空估算。

## Q5. LumiTure 看不到什麼？

- VM、資料庫、儲存空間裡的內容
- 應用程式資料與客戶資料
- AI 的 prompt 與回應

## Q6. 需要授予哪些權限？是否唯讀？

| 雲 | 權限 | 性質 |
|---|---|---|
| GCP | BigQuery Data Viewer（帳單匯出資料集）、Billing Account Viewer；用量分析另需 Cloud Monitoring Viewer | 皆唯讀 |
| Azure | Cost Management 與 Reader 類角色；用量分析另需自訂角色，動作皆為 `read` | 唯讀 |
| AWS | 帳單匯出所需的少量設定權限，加上讀取 CloudWatch 與 EC2 執行個體資訊 | **含少量寫入，見 Q7** |

GCP 與 Azure 的逐步授權說明見 [`README.zh-TW.md`](README.zh-TW.md)。

## Q7. AWS 也是完全沒有寫入權限嗎？

不是。AWS 與 GCP、Azure 不同：角色的 policy 包含少量寫入類動作，目的是建立帳單匯出：

- 對匯出用的 S3 bucket：`PutObject`、`CreateBucket`、`PutBucketPolicy`、`PutBucketNotification`
- `bcm-data-exports` 與 `cur` 的建立、修改、刪除匯出設定
- `cloudformation:UpdateStackSet`

這些不讀取或修改您的 VM、資料庫與儲存內容。完整 IAM policy 可另行提供，供貴司資安審閱。

## Q8. 貴司無法授權 IAM 給 LumiTure，怎麼辦？

走檔案上傳：客戶在自己的雲端匯出帳單，再用我們提供的一次性上傳網址上傳，LumiTure 不讀取客戶雲端的任何資料。這條路**只有帳單，沒有用量指標**，因此沒有 Rightsizing。步驟見 [`file-upload/README.zh-TW.md`](file-upload/README.zh-TW.md)。

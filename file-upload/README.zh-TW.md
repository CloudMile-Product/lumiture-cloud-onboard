# 檔案上傳 — 無法授權時的備援

> English: [`README.md`](README.md)

> **預覽。** 開始之前，LumiTure 會與貴司確認範圍、檔案清單與上傳方式，請先聯絡您的 LumiTure 窗口。

[`gcp/`](../gcp/)、[`azure/`](../azure/) 的引導流程都需要**授權 LumiTure 讀取帳單資料**。若貴司資安政策不允許授權，改走這條路：**由貴司在自己的身分下匯出帳單檔，再送到 LumiTure**。不授予任何權限，LumiTure 也不會讀取貴司的雲端。

適用：**一次性匯入**過去幾個月；若能持續送檔，也可作**定期傳送**。

## 流程

1. 依下方各雲指南，在自己的雲端**匯出**帳單檔。
2. **告知 LumiTure** 手上有哪些檔案（各雲、各月份的檔名與大小）。
3. **LumiTure 為每個檔案提供一個上傳網址**。一個網址只對應一個檔名且會過期，因此要等檔案清單確定後才能核發。
4. 用 [`upload.sh`](upload.sh) 把每個檔案上傳到對應的網址。

## 要匯出什麼

| 雲 | 匯出內容 | 格式 | 指南 |
|---|---|---|---|
| AWS | **CUR 2.0** 與 **FOCUS 1.0** 兩份匯出（Data Exports） | Parquet 或 CSV（gzip） | [`aws.md`](aws.md) |
| Azure | **Cost and usage details (actual cost)** 與 **FOCUS** 兩份成本匯出（Cost Management） | CSV（可 gzip） | [`azure.md`](azure.md) |
| GCP | **Detailed usage cost** 與 **Pricing** 兩份 BigQuery 匯出（不是 FOCUS 檔） | Avro | [`gcp.md`](gcp.md) |

GCP 請送這兩份 BigQuery 匯出，而不是 FOCUS 檔。用 Avro 而非 CSV，是為了保留 `labels`、`credits`、`project` 等巢狀欄位。資源使用率（rightsizing）資料**不在**這條路徑內；上表的 detailed usage cost 屬於帳單資料，**包含在內**。

## 開始之前

- **權限。** 各指南會列出執行者需要的權限。請及早詢問雲端管理員：建立匯出、bucket 與角色指派通常受到限制。
- **歷史資料。** 各雲能提供多少過去月份不同：新建的 AWS 匯出可能不含更早的月份；Azure 可針對過去月份重跑匯出，入口網站最多 13 個月；GCP 帳單匯出在剛啟用時會回補到上個月初（multi-region dataset），或從啟用當天開始（單一 region），所以已運作一段時間的匯出本來就含有更早的月份；新匯出最多可能要五天才補完，而 GCP pricing 完全不回補。匯出前請先與 LumiTure 確認您能提供什麼。
- **何時可以送某個月。** 雲端匯出在該月結束前會持續修正（Azure、AWS 的檔案是當月累計，GCP 的資料列可能延遲抵達）。請在該月已結束、帳單定案後再送，且每個期間只送一次。要重送前請先告知 LumiTure，因為重送的檔案可能被匯入兩次。
- **在哪裡執行。** 腳本需要 `bash` 與 `curl`。Windows 使用者請用 AWS CloudShell、Azure Cloud Shell 或 Google Cloud Shell。

## 取得上傳腳本

在 AWS CloudShell、Azure Cloud Shell、Google Cloud Shell 或任何 Linux、macOS shell：

```bash
git clone https://github.com/CloudMile-Product/lumiture-cloud-onboard.git && cd lumiture-cloud-onboard/file-upload
```

或只下載腳本並加上執行權限：

```bash
curl -fsSLO https://raw.githubusercontent.com/CloudMile-Product/lumiture-cloud-onboard/main/file-upload/upload.sh && chmod +x upload.sh
```

接著在該資料夾執行 `./upload.sh <檔案>`。

## 如何傳送

細節由 LumiTure 私下提供；本 repo 不公開任何 LumiTure 儲存位置。

1. **上傳網址（最快）**：LumiTure 提供已簽名、只允許**上傳**且**會過期**的網址。執行 `./upload.sh <檔案>`，在提示時貼上網址：腳本不接受把網址當作參數，所以網址不會留在 shell 歷史紀錄與 process 列表中。若要寫成腳本，可用管線傳入：`printf '%s' "$URL" | ./upload.sh <檔案>`。網址在過期前等同密碼，請妥善保管。能否重複使用、能否覆寫既有檔案，取決於雲端與簽名方式：S3 預先簽名的 PUT 網址與具寫入權限的 Azure SAS 網址可以；只有 `roles/storage.objectCreator` 的 GCS 簽名網址不行。若網址簽名時包含 header（例如 `Content-Type`），需把相同的 header 當作額外參數傳給 `upload.sh`。一次上傳就是一個 HTTP PUT，請先告知 LumiTure 檔案大小；非常大的檔案可能需要其他方式。
2. **貴司自建 Service Account 或身分（適合定期傳送）**：貴司在自己的雲端新建身分並提供其位址，LumiTure 可授權它上傳到 LumiTure 的位置。GCP 最單純；AWS、Azure 需要跨雲身分，較複雜，請洽 LumiTure。

## 檔案

| 檔案 | 用途 |
|---|---|
| [`aws.md`](aws.md)、[`azure.md`](azure.md)、[`gcp.md`](gcp.md) | 如何產生檔案（英文） |
| [`aws-export.example.json`](aws-export.example.json) | 完整的 AWS Data Exports 請求範例：FOCUS 1.0（請先替換 `YOUR_BUCKET`） |
| [`aws-cur2-export.example.json`](aws-cur2-export.example.json) | 同上，CUR 2.0 版（請先替換 `YOUR_BUCKET`） |
| [`upload.sh`](upload.sh) | 把一個檔案上傳到簽名網址。不內嵌任何憑證；網址本身就是憑證 |

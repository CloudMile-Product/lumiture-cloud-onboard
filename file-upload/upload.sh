#!/usr/bin/env bash
# Upload one file to a LumiTure signed, upload-only URL.
#   ./upload.sh <file> [header ...]
# The signed URL is a credential, so it is never taken from the command line (it would
# show in your shell history and in the process list). It is read from stdin:
#   - on a terminal you are prompted for it and nothing is echoed;
#   - or pipe it in:  printf '%s' "$URL" | ./upload.sh <file>
# Extra arguments are sent as request headers, for URLs signed with headers
# (for example 'Content-Type: application/octet-stream').
# The URL is handed to curl through its config on stdin, so it stays out of curl's
# process arguments too.
set -euo pipefail

usage() { echo "Usage: $0 <file> [header ...]   (the upload URL is read from stdin)" >&2; exit 2; }
[[ $# -ge 1 ]] || usage
file="$1"; shift
case "${file}" in
  http://*|https://*) echo "That looks like an upload URL. Do not pass it on the command line (it would show in your shell history and process list); pass the file to upload, then paste the URL when prompted." >&2; exit 2 ;;
esac
[[ "${1:-}" == "-" ]] && shift   # a lone '-' placeholder from older instructions is ignored
for a in "$@"; do
  case "${a}" in
    http://*|https://*) echo "Do not pass the upload URL as an argument (it would show in your shell history and process list). Run without it and paste the URL when prompted, or pipe it in on stdin." >&2; exit 2 ;;
  esac
done
[[ -f "${file}" ]] || { echo "No such file: ${file}" >&2; exit 2; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 2; }
unset -v url   # drop any inherited (possibly exported) variable of this name
url=""
if [[ -t 0 ]]; then
  read -r -s -p "Upload URL: " url || true
  echo >&2
else
  # read returns non-zero at end of input without a trailing newline, but still fills url
  IFS= read -r url || true
fi
url="$(printf '%s' "${url}" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
[[ -n "${url}" ]] || { echo "No upload URL given (paste it when prompted, or pipe it in on stdin)" >&2; exit 2; }
[[ "${url}" == https://* ]] || { echo "Upload URL must start with https://" >&2; exit 2; }
case "${url}" in *\"*|*\\*) echo "Upload URL contains a character this script cannot pass safely" >&2; exit 2 ;; esac

headers=()
have_blob_type=0
for h in "$@"; do
  headers+=(-H "${h}")
  case "$(printf '%s' "${h}" | tr '[:upper:]' '[:lower:]')" in x-ms-blob-type:*) have_blob_type=1 ;; esac
done
# Azure SAS blob uploads need the blob type; match the storage host only (also
# covers sovereign clouds such as blob.core.usgovcloudapi.net).
host="$(printf '%s' "${url#https://}" | tr '[:upper:]' '[:lower:]')"; host="${host%%[/?]*}"
if [[ "${have_blob_type}" -eq 0 ]]; then
  case "${host}" in *.blob.core.*) headers+=(-H "x-ms-blob-type: BlockBlob") ;; esac
fi

echo "Uploading $(basename "${file}") ($(wc -c < "${file}" | tr -d ' ') bytes)..."
if command -v shasum >/dev/null; then echo "sha256: $(shasum -a 256 "${file}" | cut -d' ' -f1)"
elif command -v sha256sum >/dev/null; then echo "sha256: $(sha256sum "${file}" | cut -d' ' -f1)"; fi

body="$(mktemp)"; trap 'rm -f "${body}"' EXIT; trap 'exit 130' INT TERM HUP
progress=(-sS); [[ -t 2 ]] && progress=(--progress-bar -S)
rc=0
# -q: ignore any ~/.curlrc; -g: no {} [] globbing of the file name; -K -: URL from stdin.
status=$(printf 'url = "%s"\n' "${url}" | curl -q -g "${progress[@]}" --connect-timeout 30 -K - -o "${body}" -w '%{http_code}' -X PUT "${headers[@]+"${headers[@]}"}" --upload-file "${file}") || rc=$?
if [[ "${rc}" -ne 0 ]]; then
  echo "The upload did not complete (curl exit code ${rc}). Check your network, proxy and TLS settings, then retry." >&2
  exit 1
fi
case "${status}" in
  200|201|204) echo "Done (HTTP ${status})." ;;
  *)
    echo "Upload failed (HTTP ${status}). Common causes: the URL expired; it was signed with headers you did not pass (add them as extra arguments, e.g. 'Content-Type: application/octet-stream'); or the file name already exists and the URL cannot overwrite. Ask LumiTure for a new URL if unsure." >&2
    # Print only the error code and message: the full body can echo the URL's signature.
    detail="$(grep -o '<Code>[^<]*</Code>\|<Message>[^<]*</Message>' "${body}" 2>/dev/null | sed 's/<[^>]*>//g' | head -c 400 || true)"
    detail="${detail//"${url}"/<upload-url>}"   # never echo the URL back, even if the server does
    if [[ -n "${detail}" ]]; then echo "Server said: ${detail}" | tr '\n' ' ' >&2; echo >&2; fi
    exit 1 ;;
esac

#!/usr/bin/env bash
# NEST HOMES — tell search engines the site changed.
#
#   ./ping-search.sh                     resubmit every URL in sitemap.xml
#   ./ping-search.sh /puja.html          resubmit just these paths
#
# Run this AFTER ./deploy.sh, never before — the engines fetch the URL soon
# after the ping, and pinging a stale page just gets the stale page indexed.
#
# Google does NOT support this. Its sitemap ping was retired in June 2023 and
# now returns 404; Google only accepts URLs through Search Console. Bing's own
# sitemap ping is likewise 410 Gone — IndexNow replaced it.

set -euo pipefail
cd "$(dirname "$0")"

KEY="57a72f92c851383d31f67971cf57029db8a26b5ab9a91c1d"
HOST="www.nesthomes.in"
GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YEL=$'\033[0;33m'; NC=$'\033[0m'
ok(){ echo "${GREEN}  ok${NC}  $1"; }
bad(){ echo "${RED} FAIL${NC}  $1"; FAILED=1; }
FAILED=0

# The key file must be publicly readable or every engine rejects the whole batch.
code=$(curl -s -o /tmp/nh_key -w "%{http_code}" --max-time 20 "https://$HOST/$KEY.txt" || echo 000)
if [ "$code" != "200" ] || [ "$(cat /tmp/nh_key)" != "$KEY" ]; then
  echo "${RED}IndexNow key file is not being served correctly (HTTP $code).${NC}"
  echo "Check that .vercelignore still has the '!$KEY.txt' negation — *.txt is blocked by default."
  exit 1
fi
ok "key file verified at https://$HOST/$KEY.txt"

# Build the URL list: explicit args, else everything in the sitemap.
URLS=()
if [ "$#" -gt 0 ]; then
  for p in "$@"; do
    case "$p" in https://*) URLS+=("$p");; *) URLS+=("https://$HOST$p");; esac
  done
else
  while IFS= read -r u; do URLS+=("$u"); done < <(
    curl -s --max-time 20 "https://$HOST/sitemap.xml" |
    grep -o '<loc>[^<]*</loc>' | sed 's/<[^>]*>//g')
fi
[ "${#URLS[@]}" -gt 0 ] || { echo "${RED}No URLs to submit.${NC}"; exit 1; }
echo "Submitting ${#URLS[@]} URL(s):"; printf '  %s\n' "${URLS[@]}"

LIST=$(printf '"%s",' "${URLS[@]}"); LIST="${LIST%,}"
PAYLOAD=$(printf '{"host":"%s","key":"%s","keyLocation":"https://%s/%s.txt","urlList":[%s]}' \
  "$HOST" "$KEY" "$HOST" "$KEY" "$LIST")

echo
echo "── IndexNow ──────────────────────────────────"
# One ping propagates to all participants, but hitting each directly is faster
# and shows exactly which engine accepted.
for ep in "https://api.indexnow.org/IndexNow" \
          "https://www.bing.com/indexnow" \
          "https://yandex.com/indexnow" \
          "https://searchadvisor.naver.com/indexnow" \
          "https://search.seznam.cz/indexnow"; do
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 \
    -X POST "$ep" -H "Content-Type: application/json; charset=utf-8" \
    --data-binary "$PAYLOAD" || echo 000)
  case "$code" in
    200|202) ok  "$code  ${ep#https://}" ;;
    429)     echo "${YEL} warn${NC}  429  ${ep#https://} (rate limited — try later)" ;;
    *)       bad "$code  ${ep#https://}" ;;
  esac
done

echo
echo "── Google ────────────────────────────────────"
echo "${YEL} note${NC}  Google has no ping API. Submit at:"
echo "        https://search.google.com/search-console → URL Inspection → Request Indexing"

echo
[ "$FAILED" -eq 0 ] && echo "${GREEN}Done.${NC}" || { echo "${RED}Some endpoints failed.${NC}"; exit 1; }

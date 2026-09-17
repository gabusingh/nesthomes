#!/usr/bin/env bash
# NEST HOMES — deploy to production (www.nesthomes.in + landing.nesthomes.in)
#
#   ./deploy.sh          deploy
#   ./deploy.sh --check  verify only, don't deploy
#
# `vercel` is not on PATH on this machine, so we go through npx.

set -euo pipefail
cd "$(dirname "$0")"

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YEL=$'\033[0;33m'; NC=$'\033[0m'
ok(){ echo "${GREEN}  ok${NC}  $1"; }
bad(){ echo "${RED} FAIL${NC}  $1"; FAILED=1; }
warn(){ echo "${YEL} warn${NC}  $1"; }
FAILED=0

echo "── Pre-flight ─────────────────────────────────"

# 1. Files that must exist
for f in puja.html index.html favicon-puja.svg favicon.ico; do
  [ -f "$f" ] && ok "$f present" || bad "$f MISSING"
done

# 2. Secrets must stay out of the deploy. These leak Ads/GA4 IDs, the Sheet ID
#    and the lead-form spam defenses (honeypot name, time trap, token).
for pat in '*.md' '*.csv' '*.bak' 'apps-script'; do
  grep -qxF "$pat" .vercelignore && ok ".vercelignore blocks $pat" \
    || bad ".vercelignore is MISSING '$pat' — internal files would go public"
done

# 3. Cheap HTML sanity checks on the landing page
if grep -q '__LOGO__' puja.html; then bad "puja.html has an unsubstituted __LOGO__ placeholder"; else ok "no placeholders"; fi
if grep -q '{{' puja.html; then warn "puja.html contains '{{' — check for unrendered template syntax"; else ok "no template leakage"; fi
for tag in '</html>' '</body>' '</script>'; do
  grep -q -- "$tag" puja.html && ok "closing $tag found" || bad "puja.html missing $tag"
done

# 4. Render it headlessly and fail on real page JS errors
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ -x "$CHROME" ]; then
  TMP=$(mktemp -d)
  if "$CHROME" --headless=new --disable-gpu --virtual-time-budget=8000 \
       --dump-dom "file://$PWD/puja.html" >"$TMP/dom.html" 2>"$TMP/err.log"; then
    # grep -o counts occurrences, not matching lines (the DOM dump puts many on one line).
    # Patterns are exact so they can't be inflated by CSS rules or child classnames
    # like .dcard-pin. Each count includes 1 for the JS template literal, hence the -1.
    ROWS=$(grep -o '<td class="td-date"' "$TMP/dom.html" | wc -l | tr -d ' ')
    CARDS=$(grep -o 'class="dcard rv"' "$TMP/dom.html" | wc -l | tr -d ' ')
    VIDS=$(grep -o 'class="vframe"' "$TMP/dom.html" | wc -l | tr -d ' ')
    [ "$ROWS"  -ge 17 ] && ok "booking table rendered ($((ROWS-1))/16 rows)"    || bad "booking table did not render (got $((ROWS-1)))"
    [ "$CARDS" -ge 13 ] && ok "destinations rendered ($((CARDS-1))/12 cards)"   || bad "destinations did not render (got $((CARDS-1)))"
    [ "$VIDS"  -ge 7  ] && ok "video gallery rendered ($((VIDS-1))/6 videos)"   || bad "video gallery did not render (got $((VIDS-1)))"
    # Review cards and dots are both generated from the REVIEWS array, so a
    # mismatch means the slider rendered wrong — dots that point nowhere.
    REVS=$(( $(grep -o 'class="rcard rv"' "$TMP/dom.html" | wc -l | tr -d ' ') - 1 ))
    DOTS=$(( $(grep -o 'class="rev-dot"'  "$TMP/dom.html" | wc -l | tr -d ' ') - 1 ))
    if [ "$REVS" -ge 3 ] && [ "$REVS" -eq "$DOTS" ]; then
      ok "review slider rendered ($REVS reviews, $DOTS dots)"
      [ "$REVS" -lt 10 ] && warn "only $REVS reviews — the slider is designed for 10"
    else
      bad "review slider mismatch ($REVS cards vs $DOTS dots)"
    fi
  else
    warn "headless render failed to run — skipping render checks"
  fi
  rm -rf "$TMP"
else
  warn "Chrome not found — skipping render checks"
fi

if [ "$FAILED" -ne 0 ]; then
  echo; echo "${RED}Pre-flight failed. Nothing deployed.${NC}"; exit 1
fi
echo "${GREEN}Pre-flight passed.${NC}"

if [ "${1:-}" = "--check" ]; then echo "(--check: stopping before deploy)"; exit 0; fi

echo
echo "── Deploying ──────────────────────────────────"
npx vercel --prod --yes

echo
echo "── Verifying live ─────────────────────────────"
sleep 3
for url in "https://www.nesthomes.in/puja.html" \
           "https://landing.nesthomes.in/puja.html" \
           "https://www.nesthomes.in/"; do
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 20 "$url" || echo 000)
  [ "$code" = "200" ] && ok "$code  $url" || bad "$code  $url"
done

# Discovery files must be reachable. They're .txt, which .vercelignore blocks by
# default, so a stray edit to that file silently delists the whole site.
for f in "robots.txt" "sitemap.xml" "llms.txt"; do
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "https://www.nesthomes.in/$f" || echo 000)
  [ "$code" = "200" ] && ok "200  $f" || bad "$code  $f NOT SERVED — check .vercelignore negations"
done

# Internal files must NOT be reachable
for f in "SESSION-LOG-2026-06.md" "GOOGLE-ADS-LAUNCH-CHECKLIST.md" "index.html.bak" \
         "htaccess_Backup_for_nesthomes.in.txt" "user.ini_Backup_for_nesthomes.in.txt"; do
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "https://www.nesthomes.in/$f" || echo 000)
  [ "$code" = "404" ] && ok "404  $f (correctly hidden)" || bad "$code  $f IS PUBLIC — fix .vercelignore"
done

echo
[ "$FAILED" -eq 0 ] && echo "${GREEN}Done — live at https://www.nesthomes.in/puja.html${NC}" \
                    || { echo "${RED}Deployed, but verification failed above.${NC}"; exit 1; }

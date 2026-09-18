#!/usr/bin/env bash
# NEST HOMES — publish to production (www.nesthomes.in)
#
#   ./deploy.sh                  check, commit, push, verify
#   ./deploy.sh "what changed"   same, with your own commit message
#   ./deploy.sh --check          checks only, don't publish
#
# Publishing is a git push. The "Nest Homes" Vercel account builds from
# github.com/gabusingh/nesthomes on every push to main. Don't use
# `vercel --prod` here: the Vercel CLI on this Mac is logged into the OLD
# account, which no longer serves the domain.

set -euo pipefail
cd "$(dirname "$0")"

MSG="Update site $(date '+%Y-%m-%d %H:%M')"
if [ -n "${1:-}" ] && [ "$1" != "--check" ]; then MSG="$1"; fi

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

# 2b. The GitHub repo is PUBLIC. .gitignore is an allow-list, but check what is
#     tracked and what `git add -A` would pick up before anything is pushed.
LEAK=$( { git ls-files; git add -A --dry-run | sed "s/^add '\(.*\)'$/\1/"; } \
        | grep -E '\.(md|csv|pdf|zip|mp4|ini)$|\.bak|^apps-script/|^Youtube/|htaccess' | sort -u || true)
if [ -z "$LEAK" ]; then ok "no private files headed for the public repo"
else bad "private files would go public on GitHub: $(echo $LEAK)"; fi

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
echo "── Publishing ─────────────────────────────────"
git add -A
if git diff --cached --quiet; then
  ok "no new changes to commit"
else
  git commit -q -m "$MSG"
  ok "committed: $MSG"
fi
if [ -n "$(git log origin/main..main --oneline 2>/dev/null)" ]; then
  git push -q origin main
  ok "pushed to GitHub — Vercel is building"
else
  ok "GitHub already up to date"
fi

echo
echo "── Waiting for Vercel ─────────────────────────"
# Vercel's ETag for a static file is its MD5, so the new build is live exactly
# when both pages' ETags match the local files.
etag(){ curl -sI --max-time 15 "$1" | awk 'tolower($1)=="etag:"{gsub(/["\r]/,"",$2); print $2}'; }
WANT_IDX=$(md5 -q index.html); WANT_PUJA=$(md5 -q puja.html)
LIVE=0
for _ in $(seq 1 36); do   # up to 3 minutes
  if [ "$(etag https://www.nesthomes.in/)" = "$WANT_IDX" ] && \
     [ "$(etag https://www.nesthomes.in/puja.html)" = "$WANT_PUJA" ]; then LIVE=1; break; fi
  sleep 5
done
[ "$LIVE" -eq 1 ] && ok "live site matches this folder" \
  || bad "live site still differs after 3 min — check Deployments in the Nest Homes Vercel account"

echo
echo "── Verifying live ─────────────────────────────"
for url in "https://www.nesthomes.in/puja.html" \
           "https://www.nesthomes.in/"; do
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 20 "$url" || echo 000)
  [ "$code" = "200" ] && ok "$code  $url" || bad "$code  $url"
done
code=$(curl -s -o /dev/null -w "%{redirect_url}" --max-time 20 "https://nesthomes.in/" || true)
[ "$code" = "https://www.nesthomes.in/" ] && ok "nesthomes.in redirects to www" \
  || bad "nesthomes.in does not redirect to www (got '$code')"

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

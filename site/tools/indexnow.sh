#!/bin/bash
# Submit every URL in public/sitemap.xml to IndexNow (Bing, Yandex, Seznam, Naver…).
# The key lives in site/indexnow.key and must be served at https://instablock.app/<key>.txt
# (deploy after changing it). Usage: tools/indexnow.sh
set -euo pipefail
cd "$(dirname "$0")/.."
KEY="$(tr -d '[:space:]' < indexnow.key)"
HOST="instablock.app"
URLS="$(grep -o '<loc>[^<]*</loc>' public/sitemap.xml | sed 's/<[^>]*>//g' | python3 -c 'import sys,json;print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
BODY="$(python3 -c "import json,sys;print(json.dumps({'host':'$HOST','key':'$KEY','keyLocation':'https://$HOST/$KEY.txt','urlList':json.loads(sys.argv[1])}))" "$URLS")"
echo "Submitting $(echo "$URLS" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))') URLs to IndexNow…"
curl -s -o /dev/null -w "IndexNow response: HTTP %{http_code}\n" -X POST "https://api.indexnow.org/indexnow" -H "Content-Type: application/json; charset=utf-8" --data "$BODY"

#!/usr/bin/env bash
# 在 hub 上把待批准的新设备逐台批掉。
# 设备用密钥派生 id，换身份后每台都会以 pending 出现一次。
set -u
export PATH="/c/Windows/System32:/c/Windows:/c/Program Files/Git/bin:/c/Program Files/Git/cmd:/usr/bin:/bin:$PATH"

KEY=$(ls ~/.ssh/*174 2>/dev/null | head -1)
SSH="/usr/bin/ssh -o ConnectTimeout=12 -p 9527 -i $KEY -o IdentitiesOnly=yes"

echo "== 待批准 =="
PENDING=$($SSH root@106.55.177.19 'docker exec peer-directory python -c "
import sqlite3
db=sqlite3.connect(\"/data/peer-directory.db\")
for r in db.execute(\"select id, os, name from devices where approved=0\"):
    print(f\"{r[0]}|{r[1] or \"\"}|{r[2] or \"\"}\")
"' 2>/dev/null | grep -av Pseudo | grep "|")

if [ -z "$PENDING" ]; then
  echo "  没有待批准的设备"
  exit 0
fi

echo "$PENDING" | while IFS='|' read -r ID OS NAME; do
  [ -z "$ID" ] && continue
  echo "  批准 $ID  ($OS $NAME)"
  $SSH root@106.55.177.19 "curl -s -o /dev/null -w '    %{http_code}\n' -X POST http://127.0.0.1/api/approve -H 'content-type: application/json' -d '{\"id\":\"$ID\"}'" 2>/dev/null | grep -av Pseudo
done

echo "== 批准后 =="
$SSH root@106.55.177.19 'docker exec peer-directory python -c "
import sqlite3, time
db=sqlite3.connect(\"/data/peer-directory.db\")
now=int(time.time()*1000)
ap=[r[0] for r in db.execute(\"select id from devices where approved=1\")]
print(\"  已批准:\", \" \".join(ap))
for r in db.execute(\"select id, updated_at from nodes order by id\"):
    print(f\"  node {r[0]:14s} age={int((now-r[1])/1000)}s\")
"' 2>/dev/null | grep -av Pseudo

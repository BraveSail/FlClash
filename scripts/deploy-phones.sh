#!/usr/bin/env bash
# 装 APK 到两台手机、用广播开 VPN、核对是否报到 hub。
# 用法: ./deploy-phones.sh <apk路径>
set -u
export PATH="/c/Windows/System32:/c/Windows:/c/Program Files/Git/bin:/c/Program Files/Git/cmd:/usr/bin:/bin:$PATH"

APK="${1:?需要 APK 路径}"
[ -f "$APK" ] || { echo "  APK 不存在: $APK"; exit 1; }

hub_ages() {
  local KEY
  KEY=$(ls ~/.ssh/*174 2>/dev/null | head -1)
  /usr/bin/ssh -o ConnectTimeout=10 -p 9527 -i "$KEY" -o IdentitiesOnly=yes root@106.55.177.19 \
    'docker exec peer-directory python -c "
import sqlite3, time
db=sqlite3.connect(\"/data/peer-directory.db\")
now=int(time.time()*1000)
print(\"  \" + \"  \".join(f\"{r[0]}:{int((now-r[1])/1000)}s\" for r in db.execute(\"select id, updated_at from nodes order by id\")))
"' 2>/dev/null | grep -av Pseudo | tail -1
}

echo "== 连接中的设备 =="
adb devices | awk 'NR>1 && $2=="device"{print "  "$1}'

for DEV in $(adb devices | awk 'NR>1 && $2=="device"{print $1}'); do
  echo "== $DEV =="
  adb -s "$DEV" push "$APK" /data/local/tmp/flclash.apk >/dev/null 2>&1
  adb -s "$DEV" shell pm install -r /data/local/tmp/flclash.apk 2>&1 | tail -1
  adb -s "$DEV" shell "pm dump com.follow.clash | grep -m1 lastUpdateTime" 2>&1 | tail -1

  adb -s "$DEV" shell "am broadcast -a com.follow.clash.intent.action.VPN_START_REQUESTED -n com.follow.clash/.ServiceBroadcastReceiver" >/dev/null 2>&1
done

echo "== 等待隧道与核心 =="
sleep 35

PORT=19090
for DEV in $(adb devices | awk 'NR>1 && $2=="device"{print $1}'); do
  VPN=$(adb -s "$DEV" shell "dumpsys connectivity | grep -c VpnTransportInfo" 2>/dev/null | tr -d '\r')
  adb -s "$DEV" forward --remove-all >/dev/null 2>&1
  adb -s "$DEV" forward tcp:$PORT tcp:9090 >/dev/null 2>&1
  sleep 1
  VER=$(curl -s -m 6 "http://127.0.0.1:$PORT/version" | head -c 60)
  echo "  $DEV  vpn=$VPN  version=${VER:-无应答}"
  PORT=$((PORT+1))
done

echo "== hub 四台的新鲜度 =="
hub_ages

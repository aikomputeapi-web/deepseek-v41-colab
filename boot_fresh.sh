#!/bin/bash
set -e
echo "=== Hardware ==="
nvidia-smi --query-gpu=name,memory.total,compute_cap --format=csv,noheader
free -h | head -2
df -h /content | tail -1
echo "CPUs: $(nproc)"

echo "=== Fetching deepseek-v41-colab ==="
rm -rf /content/deepseek-colab /content/vm
git clone --depth 1 https://github.com/aikomputeapi-web/deepseek-v41-colab.git /content/deepseek-colab
cp -a /content/deepseek-colab/vm /content/vm
chmod +x /content/vm/*.sh

mkdir -p /content/secrets /content/res
if [ -n "${DS41_API_KEY:-}" ]; then
  printf '%s' "$DS41_API_KEY" > /content/secrets/key
elif [ ! -s /content/secrets/key ]; then
  python3 -c 'import secrets; print("sk-ds41-" + secrets.token_hex(24))' > /content/secrets/key
fi

echo "=== Booting DeepSeek V4.1 Flash (Abliterated) (~4 min) ==="
pkill -f llama-server 2>/dev/null || true
pkill -f /content/vm/gate.py 2>/dev/null || true
: > /content/res/timeline.txt
CTX=524288 UBATCH=2048 MMPROJ=1 MOE_CACHE_MIB=70430 DYN=110 DMA=0 DRAFT=1 UNCENSOR=1 WORKERS=64 bash /content/vm/boot.sh &
BPID=$!
SEEN=0
while kill -0 "$BPID" 2>/dev/null; do
  LINES=$(wc -l < /content/res/timeline.txt 2>/dev/null || echo 0)
  if [ "$LINES" -gt "$SEEN" ]; then
    sed -n "$((SEEN+1)),${LINES}p" /content/res/timeline.txt
    SEEN=$LINES
  fi
  sleep 2
done
wait "$BPID"
RC=$?
LINES=$(wc -l < /content/res/timeline.txt 2>/dev/null || echo 0)
[ "$LINES" -gt "$SEEN" ] && sed -n "$((SEEN+1)),${LINES}p" /content/res/timeline.txt
[ "$RC" -eq 0 ] || { echo "boot.sh failed ($RC)"; tail -n 30 /content/res/build.txt /content/res/server.log /content/res/fetch.log 2>/dev/null; exit "$RC"; }

echo "=== Starting Cloudflare Tunnel ==="
if ! command -v cloudflared >/dev/null 2>&1; then
  curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared
fi
pkill -f 'cloudflared tunnel' 2>/dev/null || true
if [ -n "${CF_TUNNEL_TOKEN:-}" ]; then
  nohup cloudflared tunnel --no-autoupdate run --token "$CF_TUNNEL_TOKEN" --url http://127.0.0.1:18080 > /content/res/cloudflared.log 2>&1 &
  sleep 4
  URL="${CF_TUNNEL_URL:-https://ds41.nowrouter.store}"
else
  nohup cloudflared tunnel --url http://127.0.0.1:18080 --no-autoupdate > /content/res/cloudflared.log 2>&1 &
  for i in $(seq 1 30); do
    URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /content/res/cloudflared.log 2>/dev/null | head -1)
    [ -n "$URL" ] && break
    sleep 1
  done
fi

echo ""
echo "============================================================"
echo "READY - DeepSeek V4.1 Flash (Abliterated)"
echo "  Base URL : ${URL}/v1"
echo "  API Key  : $(cat /content/secrets/key)"
echo "  Models   : ds41 (effort 50), ds41-max (effort max)"
echo "============================================================"

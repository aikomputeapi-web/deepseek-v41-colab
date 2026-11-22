#!/bin/bash
set -e
export PATH=/usr/local/cuda/bin:$PATH
S=/content/src/llama.cpp
D=/content/llama/bin
ARCH=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d '. ')
[ -n "$ARCH" ] || ARCH=80

echo "=== Building llama-server (arch=$ARCH, no WebUI) ==="
rm -rf "$S/build/tools/ui/dist"
sed -i 's/FATAL_ERROR/STATUS/g' "$S/scripts/ui-assets.cmake" 2>/dev/null || true
cmake -S "$S" -B "$S/build" \
  -DGGML_CUDA=ON \
  -DCMAKE_CUDA_ARCHITECTURES="$ARCH" \
  -DLLAMA_BUILD_TESTS=ON \
  -DLLAMA_CURL=OFF \
  -DLLAMA_OPENSSL=ON \
  -DLLAMA_BUILD_UI=OFF \
  -DCMAKE_BUILD_TYPE=Release
nice -n 5 cmake --build "$S/build" -j "$(nproc)" --target llama-server
mkdir -p "$D"
cp -a "$S/build/bin/"* "$D/"
find "$S/build" -name "*.so*" -exec cp -a {} "$D/" \;
for l in libcudart.so libcublas.so libcublasLt.so; do
  cp -a /usr/local/cuda/lib64/$l* "$D/" 2>/dev/null || true
done
echo '#!/bin/bash' > /content/vm/build.sh
chmod +x /content/vm/build.sh

echo "=== Booting DeepSeek V4.1 Flash (Abliterated) ==="
: > /content/res/timeline.txt
( tail -F /content/res/timeline.txt 2>/dev/null ) &
TPID=$!
trap "kill $TPID 2>/dev/null || true" EXIT
CTX=524288 UBATCH=2048 MMPROJ=1 MOE_CACHE_MIB=70430 DYN=110 DMA=0 DRAFT=1 UNCENSOR=1 WORKERS=64 bash /content/vm/boot.sh
kill $TPID 2>/dev/null || true

echo "=== Starting Cloudflare Tunnel ==="
if ! command -v cloudflared >/dev/null 2>&1; then
  curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared
fi
pkill -f 'cloudflared tunnel' 2>/dev/null || true
nohup cloudflared tunnel --url http://127.0.0.1:18080 --no-autoupdate > /content/res/cloudflared.log 2>&1 &
for i in $(seq 1 30); do
  URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /content/res/cloudflared.log 2>/dev/null | head -1)
  [ -n "$URL" ] && break
  sleep 1
done

echo ""
echo "============================================================"
echo "READY - DeepSeek V4.1 Flash (Abliterated)"
echo "  Base URL : ${URL}/v1"
echo "  API Key  : $(cat /content/secrets/key)"
echo "  Models   : ds41 (effort 50), ds41-max (effort max)"
echo "============================================================"

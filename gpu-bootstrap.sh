#!/usr/bin/env bash
# gpu-bootstrap.sh — tự cài Tailscale + Ollama + DeepSeek trên VM Massed Compute mới.
# Chạy bởi cron (/etc/cron.d/gpu-bootstrap, tải về bằng Startup Command).
# Env vars: TS_AUTHKEY (bắt buộc), TS_APIKEY (nên có — dọn node Tailscale cũ để giữ tên gpu-deepseek). Cần biến môi trường TS_AUTHKEY (Massed Compute ghi vào ~/.env).
# Log: /var/log/gpu-bootstrap.log
set -euo pipefail

LOG=/var/log/gpu-bootstrap.log
exec > >(tee -a "$LOG") 2>&1
echo "=== bootstrap start $(date -u) ==="

# ---- 1. Đọc biến môi trường từ ~/.env (Massed Compute ghi vào home của user) ----
for f in /home/Ubuntu/.env /home/ubuntu/.env /root/.env "${HOME:-/root}/.env"; do
  if [ -f "$f" ]; then set -a; . "$f"; set +a; echo "env loaded from $f"; break; fi
done
: "${TS_AUTHKEY:?Thiếu TS_AUTHKEY trong Environment Variables}"
MODELS="${MODELS:-deepseek-r1:32b-qwen-distill-q4_K_M qwen3:32b huihui_ai/deepseek-r1-abliterated:32b-qwen-distill-q4_K_M huihui_ai/qwen3-abliterated:32b-q4_K_M}"
HOSTNAME_TS="${TS_HOSTNAME:-gpu-deepseek}"

# ---- 2. Tailscale: xoá node cũ cùng tên (VM đã Delete), cài, join bằng auth key ----
if [ -n "${TS_APIKEY:-}" ]; then
  curl -fsS -u "$TS_APIKEY:" "https://api.tailscale.com/api/v2/tailnet/-/devices" \
  | python3 -c "
import sys, json
want = '$HOSTNAME_TS'
for d in json.load(sys.stdin).get('devices', []):
    n = d.get('name', '').split('.')[0]
    if n == want or n.startswith(want + '-'):
        print(d['id'])
" | while read -r id; do
      curl -fsS -X DELETE -u "$TS_APIKEY:" "https://api.tailscale.com/api/v2/device/$id" \
        && echo "removed stale tailscale node $id" || echo "could not remove node $id"
    done
else
  echo "TS_APIKEY không có — bỏ qua bước dọn node cũ (có thể bị đặt tên ${HOSTNAME_TS}-1)"
fi
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
fi
tailscale up --authkey "$TS_AUTHKEY" --hostname "$HOSTNAME_TS" --reset
echo "tailscale ip: $(tailscale ip -4)"

# ---- 3. Firewall: chỉ nhận SSH từ ngoài, mọi thứ khác chỉ qua Tailscale ----
apt-get install -y -qq ufw >/dev/null
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow in on tailscale0
ufw --force enable
ufw status verbose

# ---- 4. Ollama: cài + cấu hình tối ưu cho RTX 6000 Ada 48GB ----
if ! command -v ollama >/dev/null 2>&1; then
  curl -fsSL https://ollama.com/install.sh | sh
fi
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/override.conf <<'EOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_CONTEXT_LENGTH=32768"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
Environment="OLLAMA_KEEP_ALIVE=30m"
EOF
systemctl daemon-reload
systemctl enable ollama >/dev/null
systemctl restart ollama
for i in $(seq 1 30); do
  curl -sf http://127.0.0.1:11434/ >/dev/null && break
  sleep 2
done
curl -sf http://127.0.0.1:11434/ || { echo "Ollama không phản hồi"; journalctl -u ollama --no-pager | tail -30; exit 1; }

# ---- 5. Tải model + nạp sẵn vào VRAM ----
for m in $MODELS; do ollama pull "$m"; done
ollama list
curl -s http://127.0.0.1:11434/api/generate -d "{\"model\":\"${MODELS%% *}\",\"prompt\":\"hi\",\"stream\":false}" >/dev/null || true
ollama ps

echo "=== bootstrap done $(date -u) — models [$MODELS] sẵn sàng tại http://$HOSTNAME_TS:11434 ==="

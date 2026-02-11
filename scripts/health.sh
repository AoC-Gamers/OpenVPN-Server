#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$BASE_DIR"

load_env() {
  if [[ -f ./.env ]]; then
    set -a
    # shellcheck disable=SC1091
    source ./.env
    set +a
  fi
}

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "No se encontró '$1' en PATH."
}

need_docker_compose() {
  need_cmd docker
  docker compose version >/dev/null 2>&1 || die "Docker Compose (plugin) no está disponible: usa 'docker compose ...'"
}

load_env

OVPN_PORT="${OVPN_PORT:-1194}"
VPN_INTERFACE="${VPN_INTERFACE:-tun0}"

need_docker_compose

# 1) Contenedor arriba
if ! docker compose ps --services --filter "status=running" 2>/dev/null | grep -qx "openvpn"; then
  docker compose ps openvpn || true
  die "El servicio 'openvpn' no está corriendo."
fi

echo "[OK] docker compose: openvpn running"

# 2) Interfaz VPN presente en el host
need_cmd ip
if ! ip -br a 2>/dev/null | grep -Eq "^${VPN_INTERFACE}\\b"; then
  ip -br a | grep -E 'tun|tap' || true
  die "No aparece ${VPN_INTERFACE} en el host."
fi

echo "[OK] interfaz: ${VPN_INTERFACE} presente"

# 3) Puerto UDP escuchando en el host
if command -v ss >/dev/null 2>&1; then
  # Con UDP normalmente se ve ":1194" o "[::]:1194"; usar borde evita falsos positivos (p.ej. 11940).
  if ! ss -ulnp 2>/dev/null | grep -Eq "[:\\]]${OVPN_PORT}\\b"; then
    ss -ulnp | grep -E "[:\\]]${OVPN_PORT}\\b|openvpn" || true
    die "No se ve el puerto UDP ${OVPN_PORT} escuchando (ss)."
  fi
else
  # Fallback para sistemas viejos.
  if command -v netstat >/dev/null 2>&1; then
    if ! netstat -anu 2>/dev/null | grep -Eq "(:|\\])${OVPN_PORT}\\b"; then
      netstat -anu | grep -E "(:|\\])${OVPN_PORT}\\b|openvpn" || true
      die "No se ve el puerto UDP ${OVPN_PORT} escuchando (netstat)."
    fi
  else
    echo "[WARN] 'ss' no está disponible; omitiendo check de puerto."
  fi
fi

echo "[OK] puerto UDP: ${OVPN_PORT} escuchando"

echo "[HEALTH] OK"

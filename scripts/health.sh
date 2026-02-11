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

load_env

OVPN_PORT="${OVPN_PORT:-1194}"

# 1) Contenedor arriba
if ! docker compose ps --status running openvpn >/dev/null 2>&1; then
  docker compose ps openvpn || true
  die "El servicio 'openvpn' no está corriendo."
fi

echo "[OK] docker compose: openvpn running"

# 2) tun0 presente en el host
if ! ip -br a 2>/dev/null | grep -q "^tun0"; then
  ip -br a | grep tun || true
  die "No aparece tun0 en el host."
fi

echo "[OK] interfaz: tun0 presente"

# 3) Puerto UDP escuchando en el host
if command -v ss >/dev/null 2>&1; then
  if ! ss -ulnp 2>/dev/null | grep -q ":${OVPN_PORT} "; then
    ss -ulnp | grep -E ":${OVPN_PORT} |openvpn" || true
    die "No se ve el puerto UDP ${OVPN_PORT} escuchando (ss)."
  fi
else
  echo "[WARN] 'ss' no está disponible; omitiendo check de puerto."
fi

echo "[OK] puerto UDP: ${OVPN_PORT} escuchando"

echo "[HEALTH] OK"

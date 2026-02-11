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

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

validate_client_name() {
  local client="$1"
  [[ -n "$client" ]] || die "Falta nombre de cliente."
  if ! [[ "$client" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    die "Nombre inválido. Usa solo letras/números/._-"
  fi
}

ensure_initialized() {
  [[ -d "./ovpn-data/pki" ]] || die "No existe ./ovpn-data/pki. Ejecuta primero ovpn_genconfig + ovpn_initpki."
}

compose() {
  docker compose "$@"
}

clients_dir() {
  echo "${CLIENTS_DIR:-./clients}"
}

packages_dir() {
  echo "${PACKAGES_DIR:-./packages}"
}

sha256_file() {
  local file="$1"
  if have_cmd sha256sum; then
    sha256sum "$file" | awk '{print $1}'
    return 0
  fi
  if have_cmd shasum; then
    shasum -a 256 "$file" | awk '{print $1}'
    return 0
  fi
  die "No se encontró sha256sum ni shasum para calcular hashes."
}

client_create() {
  local client="$1"
  local with_pass="${2:-}"

  validate_client_name "$client"
  ensure_initialized

  if [[ "$with_pass" == "--pass" ]]; then
    echo "[+] Creando cliente CON password: $client"
    compose run --rm openvpn easyrsa build-client-full "$client"
  else
    echo "[+] Creando cliente SIN password: $client"
    compose run --rm openvpn easyrsa build-client-full "$client" nopass
  fi
}

client_export() {
  local client="$1"
  local out_path="${2:-}"

  validate_client_name "$client"
  ensure_initialized

  local out_dir
  out_dir="$(clients_dir)"
  mkdir -p "$out_dir"

  if [[ -z "$out_path" ]]; then
    out_path="${out_dir}/${client}.ovpn"
  fi

  echo "[+] Exportando perfil: $out_path"
  compose run --rm openvpn ovpn_getclient "$client" > "$out_path"
  echo "[OK] Generado: $out_path"
}

client_qr() {
  local client="$1"
  local out_path="${2:-}"

  validate_client_name "$client"
  ensure_initialized
  have_cmd qrencode || die "No se encontró 'qrencode'. Instala el paquete 'qrencode'."

  local out_dir
  out_dir="$(clients_dir)"
  mkdir -p "$out_dir"

  local ovpn_path="${out_dir}/${client}.ovpn"
  if [[ ! -f "$ovpn_path" ]]; then
    client_export "$client" "$ovpn_path"
  fi

  if [[ -z "$out_path" ]]; then
    out_path="${out_dir}/${client}.png"
  fi

  echo "[+] Generando QR: $out_path"
  qrencode -o "$out_path" < "$ovpn_path"
  echo "[OK] QR generado: $out_path"
}

client_package() {
  local client="$1"
  local with_pass="${2:-}"

  validate_client_name "$client"
  ensure_initialized
  have_cmd zip || die "No se encontró 'zip'. Instala el paquete 'zip'."
  have_cmd qrencode || die "No se encontró 'qrencode'. Instala el paquete 'qrencode'."

  local out_clients
  out_clients="$(clients_dir)"
  mkdir -p "$out_clients"

  local ovpn_path="${out_clients}/${client}.ovpn"
  if [[ ! -f "$ovpn_path" ]]; then
    client_create_and_export "$client" "$with_pass"
  fi

  local qr_path="${out_clients}/${client}.png"
  if [[ ! -f "$qr_path" ]]; then
    client_qr "$client" "$qr_path"
  fi

  local out_packages
  out_packages="$(packages_dir)"
  mkdir -p "$out_packages"

  local ts
  ts="$(date +"%Y%m%d-%H%M%S")"
  local zip_path="${out_packages}/${client}-${ts}.zip"

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  cp "$ovpn_path" "$tmp/${client}.ovpn"
  cp "$qr_path" "$tmp/${client}.png"

  local ovpn_hash qr_hash
  ovpn_hash="$(sha256_file "$tmp/${client}.ovpn")"
  qr_hash="$(sha256_file "$tmp/${client}.png")"

  cat > "$tmp/metadata.json" <<EOF
{
  "client": "${client}",
  "generated_at": "${ts}",
  "files": [
    {"name": "${client}.ovpn", "sha256": "${ovpn_hash}"},
    {"name": "${client}.png", "sha256": "${qr_hash}"}
  ]
}
EOF

  if have_cmd sha256sum; then
    (cd "$tmp" && sha256sum "${client}.ovpn" "${client}.png" "metadata.json" > SHA256SUMS)
  elif have_cmd shasum; then
    (cd "$tmp" && shasum -a 256 "${client}.ovpn" "${client}.png" "metadata.json" > SHA256SUMS)
  fi

  echo "[+] Creando paquete: $zip_path"
  (cd "$tmp" && zip -q -9 "$zip_path" "${client}.ovpn" "${client}.png" metadata.json SHA256SUMS 2>/dev/null || \
    cd "$tmp" && zip -q -9 "$zip_path" "${client}.ovpn" "${client}.png" metadata.json)

  if have_cmd sha256sum; then
    sha256sum "$zip_path" > "${zip_path}.sha256"
  elif have_cmd shasum; then
    shasum -a 256 "$zip_path" > "${zip_path}.sha256"
  fi

  echo "[OK] Paquete generado: $zip_path"
}

client_create_and_export() {
  local client="$1"
  local with_pass="${2:-}"
  client_create "$client" "$with_pass"
  client_export "$client"
}

client_revoke() {
  local client="$1"
  local remove_mode="${2:-}"

  validate_client_name "$client"
  ensure_initialized

  if [[ "$remove_mode" == "--remove" ]]; then
    echo "[+] Revocando y removiendo cliente: $client"
    compose run --rm openvpn ovpn_revokeclient "$client" remove
  else
    echo "[+] Revocando cliente: $client"
    compose run --rm openvpn ovpn_revokeclient "$client"
  fi

  # Intentar reiniciar para aplicar CRL (si el servicio existe)
  compose restart openvpn >/dev/null 2>&1 || true
  echo "[OK] Cliente revocado: $client"
}

index_file() {
  echo "./ovpn-data/pki/index.txt"
}

client_list() {
  ensure_initialized

  local idx
  idx="$(index_file)"
  [[ -f "$idx" ]] || die "No existe $idx"

  echo "STATUS\tEXPIRY\t\tCN"
  awk -F'\t' '
    /^[VR]/ {
      status=$1
      exp=$2
      cn=$6
      sub(/^\/CN=/, "", cn)
      printf "%s\t%s\t%s\n", status, exp, cn
    }
  ' "$idx" | sort -k3,3
}

client_show() {
  local client="$1"
  validate_client_name "$client"
  ensure_initialized

  local idx
  idx="$(index_file)"
  [[ -f "$idx" ]] || die "No existe $idx"

  local line
  line="$(awk -F'\t' -v c="/CN=${client}" '($6==c){print; exit 0}' "$idx" || true)"
  [[ -n "$line" ]] || die "No existe un certificado con CN=${client}"

  local status exp
  status="$(awk -F'\t' '{print $1}' <<<"$line")"
  exp="$(awk -F'\t' '{print $2}' <<<"$line")"

  case "$status" in
    V) echo "[OK] Cliente: $client (Válido)" ;;
    R) echo "[WARN] Cliente: $client (Revocado)" ;;
    *) echo "[INFO] Cliente: $client (Estado: $status)" ;;
  esac
  echo "Expira: $exp"
}

print_help() {
  cat <<'EOF'
Uso:
  ./scripts/ovpn.sh <comando> [opciones]

Comandos (clientes):
  menu
  create <nombre> [--pass]
  export <nombre> [--out <ruta>]
  create-export <nombre> [--pass]
  qr <nombre> [--out <ruta.png>]
  package <nombre> [--pass]
  revoke <nombre> [--remove]
  list
  show <nombre>

Ejemplos:
  ./scripts/ovpn.sh create-export lechuga
  ./scripts/ovpn.sh qr lechuga
  ./scripts/ovpn.sh package lechuga
  ./scripts/ovpn.sh revoke lechuga --remove
  ./scripts/ovpn.sh export lechuga --out ./clients/lechuga.ovpn
+EOF
}

menu() {
  load_env
  while true; do
    echo
    echo "OpenVPN - Gestión de clientes"
    echo "1) Crear cliente (nopass)"
    echo "2) Crear cliente (con password)"
    echo "3) Exportar .ovpn"
    echo "4) Crear + exportar (nopass)"
    echo "5) Revocar cliente"
    echo "6) Listar clientes"
    echo "7) Ver estado de cliente"
    echo "8) Generar QR (.png)"
    echo "9) Empaquetar ZIP (ovpn + qr + hashes)"
    echo "0) Salir"
    echo
    read -r -p "> " choice

    case "$choice" in
      1)
        read -r -p "Nombre cliente: " client
        client_create "$client" ""
        ;;
      2)
        read -r -p "Nombre cliente: " client
        client_create "$client" "--pass"
        ;;
      3)
        read -r -p "Nombre cliente: " client
        client_export "$client"
        ;;
      4)
        read -r -p "Nombre cliente: " client
        client_create_and_export "$client" ""
        ;;
      5)
        read -r -p "Nombre cliente: " client
        read -r -p "¿Remover archivos del cliente? (s/N): " remove
        if [[ "${remove,,}" == "s" || "${remove,,}" == "si" || "${remove,,}" == "sí" ]]; then
          client_revoke "$client" "--remove"
        else
          client_revoke "$client" ""
        fi
        ;;
      6)
        client_list
        ;;
      7)
        read -r -p "Nombre cliente: " client
        client_show "$client"
        ;;
      8)
        read -r -p "Nombre cliente: " client
        client_qr "$client" ""
        ;;
      9)
        read -r -p "Nombre cliente: " client
        read -r -p "¿Cliente con password? (s/N): " pass
        if [[ "${pass,,}" == "s" || "${pass,,}" == "si" || "${pass,,}" == "sí" ]]; then
          client_package "$client" "--pass"
        else
          client_package "$client" ""
        fi
        ;;
      0)
        echo "Bye."
        return 0
        ;;
      *)
        echo "Opción inválida."
        ;;
    esac
  done
}

main() {
  need_cmd docker
  load_env

  local cmd="${1:-menu}"
  shift || true

  case "$cmd" in
    -h|--help|help)
      print_help
      ;;
    menu)
      menu
      ;;
    create)
      client_create "${1:-}" "${2:-}"
      ;;
    export)
      local client="${1:-}"
      shift || true
      local out=""
      if [[ "${1:-}" == "--out" ]]; then
        out="${2:-}"
      fi
      client_export "$client" "$out"
      ;;
    qr)
      local client="${1:-}"
      shift || true
      local out=""
      if [[ "${1:-}" == "--out" ]]; then
        out="${2:-}"
      fi
      client_qr "$client" "$out"
      ;;
    package)
      client_package "${1:-}" "${2:-}"
      ;;
    create-export)
      client_create_and_export "${1:-}" "${2:-}"
      ;;
    revoke)
      client_revoke "${1:-}" "${2:-}"
      ;;
    list)
      client_list
      ;;
    show)
      client_show "${1:-}"
      ;;
    *)
      echo "Comando desconocido: $cmd" >&2
      print_help >&2
      exit 2
      ;;
  esac
}

main "$@"

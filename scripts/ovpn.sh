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

have_realpath_m() {
  have_cmd realpath && realpath -m . >/dev/null 2>&1
}

need_docker_compose() {
  need_cmd docker
  docker compose version >/dev/null 2>&1 || die "Docker Compose (plugin) no está disponible: usa 'docker compose ...'"
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

validate_out_path() {
  local out_dir="$1"
  local out_path="$2"

  [[ -n "$out_path" ]] || die "Ruta de salida vacía."
  [[ "$out_path" != -* ]] || die "La ruta de salida no puede comenzar con '-': $out_path"

  # Evita escribir fuera por path traversal.
  if [[ "$out_path" == /* ]]; then
    die "La ruta de salida no puede ser absoluta: $out_path"
  fi
  if [[ "$out_path" == *".."* ]]; then
    die "La ruta de salida no puede contener '..': $out_path"
  fi

  # Si existe realpath -m, verifica que el destino esté dentro de out_dir.
  if have_realpath_m; then
    local out_dir_real out_path_real
    out_dir_real="$(realpath -m "$out_dir")"
    out_path_real="$(realpath -m "$out_path")"
    case "$out_path_real" in
      "$out_dir_real"/*) ;;
      *) die "La ruta de salida debe estar dentro de $out_dir (recibido: $out_path)" ;;
    esac
  else
    # Fallback simple: exige que la ruta empiece por el directorio de salida.
    local out_dir_norm="${out_dir#./}"
    local out_path_norm="${out_path#./}"
    case "$out_path_norm" in
      "$out_dir_norm"/*) ;;
      *) die "La ruta de salida debe estar dentro de ./$out_dir_norm (recibido: $out_path)" ;;
    esac
  fi
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
  local force="${3:-}"

  validate_client_name "$client"
  ensure_initialized
  assert_client_exportable "$client"

  local out_dir
  out_dir="$(clients_dir)"
  mkdir -p "$out_dir"

  if [[ -z "$out_path" ]]; then
    out_path="${out_dir}/${client}.ovpn"
  else
    validate_out_path "$out_dir" "$out_path"
  fi

  [[ "$out_path" == *.ovpn ]] || die "El output de export debe terminar en .ovpn"

  if [[ -e "$out_path" && "$force" != "--force" ]]; then
    die "Ya existe: $out_path (usa --force para sobrescribir)"
  fi

  echo "[+] Exportando perfil: $out_path"
  (
    local tmp
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT
    compose run --rm openvpn ovpn_getclient "$client" > "$tmp"
    mv -f "$tmp" "$out_path"
  )
  echo "[OK] Generado: $out_path"
}

client_package() {
  local client="$1"
  local with_pass=""
  local force=""

  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pass)
        with_pass="--pass"
        ;;
      --force)
        force="--force"
        ;;
      *)
        die "Flag desconocida en package: $1"
        ;;
    esac
    shift || true
  done

  validate_client_name "$client"
  ensure_initialized
  have_cmd zip || die "No se encontró 'zip'. Instala el paquete 'zip'."

  # Si el cliente no existe aún, lo creamos aquí.
  local status
  status="$(client_cert_status "$client")"
  if [[ -z "$status" ]]; then
    client_create "$client" "$with_pass"
    status="$(client_cert_status "$client")"
  fi
  if [[ "$status" == "R" ]]; then
    die "El cliente '${client}' está revocado. Crea uno nuevo para empaquetar credenciales."
  fi

  local out_clients
  out_clients="$(clients_dir)"
  mkdir -p "$out_clients"

  local ovpn_path="${out_clients}/${client}.ovpn"
  if [[ ! -f "$ovpn_path" || "$force" == "--force" ]]; then
    # Re-exporta desde el certificado existente. '--force' solo significa sobrescribir el archivo.
    client_export "$client" "$ovpn_path" "$force"
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

  local ovpn_hash
  ovpn_hash="$(sha256_file "$tmp/${client}.ovpn")"

  cat > "$tmp/metadata.json" <<EOF
{
  "client": "${client}",
  "generated_at": "${ts}",
  "files": [
    {"name": "${client}.ovpn", "sha256": "${ovpn_hash}"}
  ]
}
EOF

  if have_cmd sha256sum; then
    (cd "$tmp" && sha256sum "${client}.ovpn" "metadata.json" > SHA256SUMS)
  elif have_cmd shasum; then
    (cd "$tmp" && shasum -a 256 "${client}.ovpn" "metadata.json" > SHA256SUMS)
  fi

  echo "[+] Creando paquete: $zip_path"
  (cd "$tmp" && zip -q -9 "$zip_path" "${client}.ovpn" metadata.json SHA256SUMS 2>/dev/null || \
    cd "$tmp" && zip -q -9 "$zip_path" "${client}.ovpn" metadata.json)

  if have_cmd sha256sum; then
    sha256sum "$zip_path" > "${zip_path}.sha256"
  elif have_cmd shasum; then
    shasum -a 256 "$zip_path" > "${zip_path}.sha256"
  fi

  echo "[OK] Paquete generado: $zip_path"

  # Evitar que el trap quede activo en modo menú.
  trap - EXIT
  rm -rf "$tmp" || true
}

client_create_and_export() {
  local client="$1"
  local with_pass="${2:-}"
  client_create "$client" "$with_pass"
  client_export "$client" "" "--force"
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

client_cert_status() {
  local client="$1"
  local idx
  idx="$(index_file)"
  [[ -f "$idx" ]] || die "No existe $idx"

  awk -F'\t' -v c="/CN=${client}" '($6==c){print $1; exit 0}' "$idx" || true
}

assert_client_exportable() {
  local client="$1"
  local status
  status="$(client_cert_status "$client")"
  [[ -n "$status" ]] || die "No existe un certificado con CN=${client}"
  if [[ "$status" == "R" ]]; then
    die "El cliente '${client}' está revocado. Crea uno nuevo si necesitas credenciales."
  fi
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
  export <nombre> [--out <ruta>] [--force]
  create-export <nombre> [--pass]
  package <nombre> [--pass] [--force]
  revoke <nombre> [--remove]
  list
  show <nombre>

Notas:
  --force sobrescribe el archivo de salida (.ovpn). No recrea credenciales.
  Para rotar credenciales: revoke --remove + create-export

Ejemplos:
  ./scripts/ovpn.sh create-export lechuga
  ./scripts/ovpn.sh package lechuga
  ./scripts/ovpn.sh revoke lechuga --remove
  ./scripts/ovpn.sh export lechuga --out ./clients/lechuga.ovpn
EOF
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
    echo "8) Empaquetar ZIP (ovpn + hashes)"
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
  need_docker_compose
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
      local client=""
      local with_pass=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --pass)
            with_pass="--pass"
            shift || true
            ;;
          -* )
            die "Flag desconocida en create: $1"
            ;;
          *)
            [[ -z "$client" ]] || die "Argumento extra en create: $1"
            client="$1"
            shift || true
            ;;
        esac
      done
      client_create "$client" "$with_pass"
      ;;
    export)
      local client="${1:-}"
      shift || true

      local out=""
      local force=""

      while [[ $# -gt 0 ]]; do
        case "$1" in
          --out)
            out="${2:-}"
            [[ -n "$out" ]] || die "Falta ruta después de --out"
            shift 2 || true
            ;;
          --force)
            force="--force"
            shift || true
            ;;
          *)
            die "Flag desconocida en export: $1"
            ;;
        esac
      done

      client_export "$client" "$out" "$force"
      ;;
    package)
      local client="${1:-}"
      shift || true
      client_package "$client" "$@"
      ;;
    create-export)
      local client=""
      local with_pass=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --pass)
            with_pass="--pass"
            shift || true
            ;;
          -* )
            die "Flag desconocida en create-export: $1"
            ;;
          *)
            [[ -z "$client" ]] || die "Argumento extra en create-export: $1"
            client="$1"
            shift || true
            ;;
        esac
      done
      client_create_and_export "$client" "$with_pass"
      ;;
    revoke)
      local client=""
      local remove_mode=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --remove)
            remove_mode="--remove"
            shift || true
            ;;
          -* )
            die "Flag desconocida en revoke: $1"
            ;;
          *)
            [[ -z "$client" ]] || die "Argumento extra en revoke: $1"
            client="$1"
            shift || true
            ;;
        esac
      done
      client_revoke "$client" "$remove_mode"
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

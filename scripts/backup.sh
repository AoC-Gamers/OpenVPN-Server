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

backup_dir() {
  echo "${BACKUPS_DIR:-./backups}"
}

ensure_initialized() {
  [[ -d "./ovpn-data" ]] || die "No existe ./ovpn-data. ¿Inicializaste OpenVPN (ovpn_genconfig/ovpn_initpki)?"
}

timestamp() {
  date +"%Y%m%d-%H%M%S"
}

backup_default_name() {
  echo "openvpn-$(timestamp).tar.gz"
}

backup_create() {
  ensure_initialized

  local out_dir
  out_dir="$(backup_dir)"
  mkdir -p "$out_dir"

  local name="${1:-}"
  if [[ -z "$name" ]]; then
    name="$(backup_default_name)"
  fi

  # Permitir pasar nombre sin extensión
  if [[ "$name" != *.tar.gz ]]; then
    name="${name}.tar.gz"
  fi

  local out_path="${out_dir}/${name}"
  [[ ! -e "$out_path" ]] || die "Ya existe: $out_path"

  echo "[+] Creando backup: $out_path"
  tar -czf "$out_path" "./ovpn-data"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$out_path" > "${out_path}.sha256"
  fi

  echo "[OK] Backup creado: $out_path"
}

backup_list() {
  local out_dir
  out_dir="$(backup_dir)"
  mkdir -p "$out_dir"

  echo "Backups en: $out_dir"
  ls -1t "$out_dir"/*.tar.gz 2>/dev/null || echo "(sin backups)"
}

backup_verify() {
  local file="$1"
  [[ -n "$file" ]] || die "Falta archivo de backup."
  [[ -f "$file" ]] || die "No existe: $file"

  echo "[+] Verificando integridad: $file"
  tar -tzf "$file" >/dev/null

  if [[ -f "${file}.sha256" ]] && command -v sha256sum >/dev/null 2>&1; then
    (cd "$(dirname "$file")" && sha256sum -c "$(basename "${file}.sha256")")
  fi

  echo "[OK] Backup válido"
}

backup_delete() {
  local file="$1"
  [[ -n "$file" ]] || die "Falta archivo de backup."
  [[ -f "$file" ]] || die "No existe: $file"

  echo "[!] Eliminará: $file"
  read -r -p "¿Confirmas? (escribe 'delete'): " confirm
  [[ "$confirm" == "delete" ]] || die "Cancelado."

  rm -f "$file" "${file}.sha256" || true
  echo "[OK] Eliminado"
}

backup_restore() {
  local file="$1"
  local force="${2:-}"

  [[ -n "$file" ]] || die "Falta archivo de backup."
  [[ -f "$file" ]] || die "No existe: $file"

  backup_verify "$file"

  if [[ "$force" != "--force" ]]; then
    echo "[!] Restaurar reemplazará ./ovpn-data (certs/keys)."
    read -r -p "¿Confirmas? (escribe 'restore'): " confirm
    [[ "$confirm" == "restore" ]] || die "Cancelado."
  fi

  local bak="./ovpn-data.bak-$(timestamp)"

  echo "[+] Deteniendo stack (si aplica)"
  docker compose down >/dev/null 2>&1 || true

  if [[ -d "./ovpn-data" ]]; then
    echo "[+] Moviendo ovpn-data actual a: $bak"
    mv "./ovpn-data" "$bak"
  fi

  echo "[+] Extrayendo backup"
  tar -xzf "$file" -C .

  [[ -d "./ovpn-data" ]] || die "Restore falló: no apareció ./ovpn-data tras extraer."

  echo "[+] Levantando stack"
  docker compose up -d

  echo "[OK] Restore completado"
  echo "     Backup anterior guardado en: $bak"
}

print_help() {
  cat <<'EOF'
Uso:
  ./scripts/backup.sh <comando> [opciones]

Comandos:
  menu
  create [--name <nombre>]
  list
  verify <archivo.tar.gz>
  restore <archivo.tar.gz> [--force]
  delete <archivo.tar.gz>

Notas:
  - Por defecto guarda en ./backups (configurable con BACKUPS_DIR).
  - El backup contiene ./ovpn-data (incluye PKI/CA: trátalo como secreto).

Ejemplos:
  ./scripts/backup.sh create --name pre-upgrade
  ./scripts/backup.sh list
  ./scripts/backup.sh restore ./backups/openvpn-20260101-120000.tar.gz
EOF
}

menu() {
  load_env
  while true; do
    echo
    echo "OpenVPN - Backups"
    echo "1) Crear backup"
    echo "2) Listar backups"
    echo "3) Verificar backup"
    echo "4) Restaurar backup"
    echo "5) Eliminar backup"
    echo "0) Salir"
    echo
    read -r -p "> " choice

    case "$choice" in
      1)
        read -r -p "Nombre (opcional, sin .tar.gz): " name
        backup_create "$name"
        ;;
      2)
        backup_list
        ;;
      3)
        read -r -p "Ruta archivo .tar.gz: " file
        backup_verify "$file"
        ;;
      4)
        read -r -p "Ruta archivo .tar.gz: " file
        backup_restore "$file" ""
        ;;
      5)
        read -r -p "Ruta archivo .tar.gz: " file
        backup_delete "$file"
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
  need_cmd tar
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
      local name=""
      if [[ "${1:-}" == "--name" ]]; then
        name="${2:-}"
      fi
      backup_create "$name"
      ;;
    list)
      backup_list
      ;;
    verify)
      backup_verify "${1:-}"
      ;;
    restore)
      backup_restore "${1:-}" "${2:-}"
      ;;
    delete)
      backup_delete "${1:-}"
      ;;
    *)
      echo "Comando desconocido: $cmd" >&2
      print_help >&2
      exit 2
      ;;
  esac
}

main "$@"

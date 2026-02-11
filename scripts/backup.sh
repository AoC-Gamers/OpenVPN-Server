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

need_docker_compose() {
  need_cmd docker
  docker compose version >/dev/null 2>&1 || die "Docker Compose (plugin) no está disponible: usa 'docker compose ...'"
}

validate_backup_dir() {
  local dir="$1"
  [[ -n "$dir" ]] || die "BACKUPS_DIR está vacío."
  [[ "$dir" != -* ]] || die "BACKUPS_DIR no puede comenzar con '-': $dir"
  if [[ "$dir" == *".."* ]]; then
    die "BACKUPS_DIR no puede contener '..': $dir"
  fi
}

backup_dir() {
  local dir
  dir="${BACKUPS_DIR:-./backups}"
  validate_backup_dir "$dir"
  echo "$dir"
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
  # Preferir --numeric-owner si está disponible (mejor portabilidad entre hosts)
  if tar --help 2>/dev/null | grep -q -- '--numeric-owner'; then
    tar --numeric-owner -czf "$out_path" "./ovpn-data"
  else
    tar -czf "$out_path" "./ovpn-data"
  fi

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
  # Evita problemas cuando el glob no hace match.
  local listing
  listing="$(find "$out_dir" -maxdepth 1 -type f -name "*.tar.gz" -printf "%T@ %p\n" 2>/dev/null \
    | sort -nr \
    | cut -d' ' -f2- || true)"

  if [[ -n "$listing" ]]; then
    echo "$listing"
  else
    echo "(sin backups)"
  fi
}

tar_validate_paths() {
  local file="$1"

  # Solo permitimos entradas bajo ovpn-data/ y sin rutas absolutas ni '..'
  tar -tzf "$file" | awk '
    BEGIN { bad=0 }
    {
      p=$0
      if (p ~ /^\//) { bad=1 }
      if (p ~ /(^|\/)\.\.($|\/)/) { bad=1 }
      # Bloquea formas raras que pueden normalizarse a otra ruta.
      if (p ~ /\/\.(\/|$)/) { bad=1 }
      if (p ~ /\/\//) { bad=1 }
      if (p !~ /^ovpn-data\// && p !~ /^ovpn-data$/) { bad=1 }
    }
    END { exit bad }
  ' || die "El tar contiene rutas fuera de ovpn-data/ (posible path traversal)."
}

backup_verify() {
  local file="$1"
  [[ -n "$file" ]] || die "Falta archivo de backup."
  [[ -f "$file" ]] || die "No existe: $file"

  echo "[+] Verificando integridad: $file"
  tar -tzf "$file" >/dev/null
  tar_validate_paths "$file"

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

  echo "[+] Extrayendo backup (modo seguro)"
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  # Extrae a tmp y luego mueve solo ovpn-data/
  tar -xzf "$file" -C "$tmp"
  [[ -d "$tmp/ovpn-data" ]] || die "Restore falló: el backup no contiene ovpn-data/."

  mv "$tmp/ovpn-data" ./ovpn-data

  # Limpieza del trap: evitar que el cleanup quede activo globalmente.
  trap - EXIT
  rm -rf "$tmp" || true

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
      local name=""
      if [[ "${1:-}" == "--name" ]]; then
        name="${2:-}"
        shift 2 || true
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

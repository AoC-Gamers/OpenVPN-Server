#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$BASE_DIR"

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "No se encontró '$1' en PATH."
}

validate_client_name() {
  local client="$1"
  [[ -n "$client" ]] || die "Falta nombre de cliente."
  [[ "$client" =~ ^[a-zA-Z0-9._-]+$ ]] || die "Nombre inválido. Usa solo letras/números/._-"
}

timestamp() {
  date +"%Y%m%d-%H%M%S"
}

sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
    return 0
  fi
  die "No se encontró sha256sum ni shasum."
}

client_vpn_ip() {
  local client="$1"
  local ccd_file="./ovpn-data/ccd/${client}"
  if [[ -f "$ccd_file" ]]; then
    awk '$1=="ifconfig-push"{print $2; exit 0}' "$ccd_file"
  fi
}

render_readme() {
  local client="$1"
  local vpn_ip="$2"
  local out="$3"

  cat > "$out" <<EOF
# ${client} S2S Bundle

Bundle listo para desplegar el cliente OpenVPN site-to-site de \`${client}\`.

## Contenido

- \`docker-compose.s2s.yml\`
- \`ovpn-s2s-data/client.conf\`
- \`ovpn-s2s-data/${client}.ovpn\`

## Despliegue

\`\`\`bash
cd ${client}-s2s-bundle
docker compose -f docker-compose.s2s.yml up -d
\`\`\`

## Verificación

\`\`\`bash
docker compose -f docker-compose.s2s.yml ps
docker compose -f docker-compose.s2s.yml logs -f --tail=100 openvpn-s2s
\`\`\`

EOF

  if [[ -n "$vpn_ip" ]]; then
    cat >> "$out" <<EOF
## Datos esperados

- Cliente VPN: \`${client}\`
- IP VPN esperada: \`${vpn_ip}\`

EOF
  fi

  cat >> "$out" <<'EOF'
## Nota

`client.conf` ya apunta al perfil embebido correcto, así que no hay que editar rutas para levantarlo.
EOF
}

main() {
  need_cmd tar
  local client="${1:-}"
  shift || true

  validate_client_name "$client"

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
        force="1"
        shift || true
        ;;
      *)
        die "Flag desconocida: $1"
        ;;
    esac
  done

  local profile="./clients/${client}.ovpn"
  [[ -f "$profile" ]] || die "No existe perfil exportado: $profile"

  mkdir -p ./packages
  if [[ -z "$out" ]]; then
    out="./packages/${client}-s2s-$(timestamp).tar.gz"
  fi

  [[ "$out" == *.tar.gz ]] || die "La salida debe terminar en .tar.gz"
  if [[ -e "$out" && "$force" != "1" ]]; then
    die "Ya existe: $out (usa --force para sobrescribir)"
  fi

  local vpn_ip bundle_name bundle_dir readme_path
  local cleanup_dir=""
  vpn_ip="$(client_vpn_ip "$client" || true)"
  bundle_name="${client}-s2s-bundle"
  cleanup_dir="$(mktemp -d)"
  trap 'rm -rf -- "$cleanup_dir"' EXIT

  bundle_dir="${cleanup_dir}/${bundle_name}"
  mkdir -p "${bundle_dir}/ovpn-s2s-data"

  cp ./docker-compose.s2s.yml "${bundle_dir}/docker-compose.s2s.yml"
  cp "$profile" "${bundle_dir}/ovpn-s2s-data/${client}.ovpn"
  cp "$profile" "${bundle_dir}/ovpn-s2s-data/client.conf"

  readme_path="${bundle_dir}/README.md"
  render_readme "$client" "$vpn_ip" "$readme_path"

  tar -czf "$out" -C "$cleanup_dir" "$bundle_name"

  local digest
  digest="$(sha256_file "$out")"
  printf '%s  %s\n' "$digest" "$out" > "${out}.sha256"

  echo "[OK] Bundle generado: $out"
  echo "[OK] SHA256: $digest"
  trap - EXIT
  rm -rf -- "$cleanup_dir"
}

main "$@"

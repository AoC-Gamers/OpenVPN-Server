# OpenVPN-Server

Servidor OpenVPN usando Docker (imagen `kylemanna/openvpn`) y Docker Compose.

## Requisitos

- Docker + Docker Compose v2 (`docker compose`).
- Ejecutar estos comandos en el host donde corre Docker (típicamente tu Debian/Ubuntu).

Dependencias opcionales (automatizaciones):

- Para generar QR y empaquetar `.zip`: `qrencode`, `zip`.
- Para backups/restore: `tar` (normalmente ya viene instalado).
- Para hashes: `sha256sum` (en Debian/Ubuntu viene en `coreutils`).

En Debian/Ubuntu:

```bash
sudo apt update
sudo apt install -y qrencode zip
```

> Nota: el servicio usa `network_mode: host`, así que el contenedor expone OpenVPN directamente en el host.

## Configuración

Edita el archivo `.env` con tus valores:

- `PUBLIC_ENDPOINT`: endpoint público donde se conectarán los clientes (IP pública o DDNS). Formato esperado por OpenVPN: `udp://host:puerto`.
- `OVPN_PORT` / `OVPN_PROTO`: puerto y protocolo (típicamente `1194/udp`).
- `LAN_SUBNET` / `LAN_MASK`: red LAN a la que quieres dar acceso desde la VPN (ruta a empujar al cliente).

Ejemplo:

```dotenv
PUBLIC_ENDPOINT=udp://tu-dominio-ddns:1194
OVPN_PORT=1194
OVPN_PROTO=udp
LAN_SUBNET=192.168.1.0
LAN_MASK=255.255.255.0
```

## Inicializar configuración (una sola vez)

Esto genera la configuración base y el PKI en `./ovpn-data/`.

Si estás en bash, puedes cargar variables desde `.env` para no reescribirlas:

```bash
set -a
source ./.env
set +a
```

Generar config (ajusta rutas si tu LAN es distinta):

```bash
docker compose run --rm openvpn ovpn_genconfig \
	-u "$PUBLIC_ENDPOINT" \
	-p "route ${LAN_SUBNET} ${LAN_MASK}"
```

Inicializar PKI/CA (te pedirá passphrase para la CA):

```bash
docker compose run --rm openvpn ovpn_initpki
```

## Levantar OpenVPN

```bash
docker compose up -d
```

Verificar interfaz TUN:

```bash
ip -br a | grep tun
```

Debería aparecer `tun0`.

Verificar puerto UDP:

```bash
sudo ss -ulnp | grep "$OVPN_PORT"
```

Chequeo de salud (2 niveles):

- Docker healthcheck (estado `healthy/unhealthy`):

```bash
docker inspect -f '{{.State.Health.Status}}' openvpn
```

- Health del host (túnel + puerto):

```bash
make health
```

> Tip: si tu interfaz VPN no es `tun0`, puedes definir `VPN_INTERFACE` en tu `.env` (ej: `VPN_INTERFACE=tun1`).

## Crear usuario cliente

Hay 2 formas: manual o usando el script.

### Opción A: usando el script con menú/subcomandos (recomendado)

El script valida el nombre, crea/revoca/lista clientes y exporta perfiles a `./clients/<cliente>.ovpn`.

Menú interactivo:

```bash
./scripts/ovpn.sh
```

Ejemplos no interactivos (útil para Make):

```bash
./scripts/ovpn.sh create-export lechuga
./scripts/ovpn.sh create lechuga --pass
./scripts/ovpn.sh export lechuga --out ./clients/lechuga.ovpn
./scripts/ovpn.sh qr lechuga
./scripts/ovpn.sh package lechuga
./scripts/ovpn.sh list
./scripts/ovpn.sh show lechuga
./scripts/ovpn.sh revoke lechuga
```

Notas de seguridad / overwrite:

- `export` y `qr` no sobrescriben archivos existentes a menos que uses `--force`.
- Si usas `--out`, la ruta debe quedar dentro de `./clients` (el script rechaza rutas absolutas o con `..`).

Ejemplos con `--force`:

```bash
./scripts/ovpn.sh export lechuga --out ./clients/lechuga.ovpn --force
./scripts/ovpn.sh qr lechuga --out ./clients/lechuga.png --force
./scripts/ovpn.sh package lechuga --force
```

Cliente sin password:

```bash
./scripts/ovpn.sh create-export lechuga
```

Cliente con password (interactivo):

```bash
./scripts/ovpn.sh create-export lechuga --pass
```

### Opción B: manual

```bash
docker compose run --rm openvpn easyrsa build-client-full lechuga nopass
docker compose run --rm openvpn ovpn_getclient lechuga > lechuga.ovpn
```

Luego copia el archivo `.ovpn` al PC/dispositivo del usuario y conéctate usando un cliente OpenVPN.

## Backups / Restore

Los backups guardan `./ovpn-data` (incluye PKI/CA), así que trátalos como secretos.

Menú interactivo:

```bash
./scripts/backup.sh
```

Ejemplos no interactivos (útil para Make):

```bash
./scripts/backup.sh create --name pre-upgrade
./scripts/backup.sh list
./scripts/backup.sh verify ./backups/openvpn-YYYYmmdd-HHMMSS.tar.gz
./scripts/backup.sh restore ./backups/openvpn-YYYYmmdd-HHMMSS.tar.gz
```

## Notas

- Si `./ovpn-data/pki` no existe, primero debes correr la inicialización (sección “Inicializar configuración”).
- Para que los clientes accedan a tu LAN, además de empujar la ruta, el host debe permitir forwarding y (según tu caso) NAT/reglas firewall. Esto depende de tu distro/topología.
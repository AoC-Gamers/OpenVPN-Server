# OpenVPN-Server

Servidor OpenVPN usando Docker (imagen `kylemanna/openvpn`) y Docker Compose.

Además del servidor principal, este proyecto incluye un stack separado para cliente OpenVPN site-to-site (`docker-compose.s2s.yml`).

## Requisitos

- Docker + Docker Compose v2 (`docker compose`).
- Ejecutar estos comandos en el host donde corre Docker (típicamente tu Debian/Ubuntu).

Dependencias opcionales (automatizaciones):

- Para empaquetar `.zip`: `zip`.
- Para usar el Makefile (`make health`, `make client-export`, etc.): `make`.
- Para backups/restore: `tar` (normalmente ya viene instalado).
- Para hashes: `sha256sum` (en Debian/Ubuntu viene en `coreutils`).

En Debian/Ubuntu:

```bash
sudo apt update
sudo apt install -y zip make
```

> Nota: el servicio usa `network_mode: host`, así que el contenedor expone OpenVPN directamente en el host.

## Estructura de stacks

- Servidor OpenVPN (PKI/CA propia): `docker-compose.yml` + `ovpn-data/`
- Cliente site-to-site (separado): `docker-compose.s2s.yml` + `ovpn-s2s-data/`

Esto permite mantener en un solo proyecto los dos modos sin mezclar configuraciones.

## Configuración

Edita el archivo `.env` con tus valores:

- `PUBLIC_ENDPOINT`: endpoint público donde se conectarán los clientes (IP pública o DDNS). Formato esperado por OpenVPN: `udp://host:puerto`.
- `OVPN_PORT` / `OVPN_PROTO`: puerto y protocolo (típicamente `1194/udp`).
- `OVPN_CA_PASSPHRASE`: passphrase local de la CA para automatizaciones Easy-RSA no interactivas.
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

## Cliente Site-to-Site (stack separado)

Este stack corre un cliente OpenVPN persistente independiente del servidor.

1. Preparar configuración cliente:

```bash
cp ovpn-s2s-data/client.conf.example ovpn-s2s-data/client.conf
```

2. Copiar credenciales cliente (`ca.crt`, `*.crt`, `*.key`, `ta.key`) dentro de `ovpn-s2s-data/`.

3. Ajustar `ovpn-s2s-data/client.conf` (remote, rutas, archivos).

4. Levantar cliente S2S:

```bash
docker compose -f docker-compose.s2s.yml up -d
```

Comandos útiles:

```bash
docker compose -f docker-compose.s2s.yml ps
docker compose -f docker-compose.s2s.yml logs -f --tail=100 openvpn-s2s
make s2s-up
make s2s-status
```

Notas:
- No reutilizar PKI del servidor para el cliente S2S.
- Este modo está pensado para despliegue portable (por ejemplo, descargar en Valpo2 y levantar solo `openvpn-s2s`).

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
./scripts/ovpn.sh package lechuga
./scripts/ovpn.sh list
./scripts/ovpn.sh show lechuga
./scripts/ovpn.sh revoke lechuga
```

Notas de seguridad / overwrite:

- `export` y `qr` no sobrescriben archivos existentes a menos que uses `--force`.
- Si usas `--out`, la ruta debe quedar dentro de `./clients` (el script rechaza rutas absolutas o con `..`).
- Si usas `--out`, `export` exige que termine en `.ovpn`.
- `--force` significa "sobrescribir archivos de salida" (no recrea/rota credenciales).
- Para rotar credenciales: `revoke --remove` + `create-export`.

Ejemplos con `--force`:

```bash
./scripts/ovpn.sh export lechuga --out ./clients/lechuga.ovpn --force
./scripts/ovpn.sh package lechuga --force
```

Ejemplos usando Make (equivalentes):

```bash
make client-export name=lechuga force=1
make client-export name=lechuga out=./clients/lechuga.ovpn force=1
make client-create name=lechuga-pc ip=auto owner=lechuga device=pc
make client-create-export name=lechuga-note ip=auto owner=lechuga device=notebook
make client-package name=lechuga pass=1 force=1
```

Nota: `export`/`package` fallan con un mensaje claro si el CN no existe o está revocado.

### IP fija por perfil/dispositivo (JSON)

El proyecto puede llevar un registro de IPs fijas en `ovpn-data/ip-assignments.json`.

Comandos utiles:

```bash
./scripts/ovpn.sh ip-list
./scripts/ovpn.sh ip-assign lechuga-pc --vpn-ip auto --owner lechuga --device pc
./scripts/ovpn.sh create-export lechuga-note --vpn-ip auto --owner lechuga --device notebook
```

Equivalentes en `make`:

```bash
make client-ip-list
make client-ip-assign name=lechuga-pc ip=auto owner=lechuga device=pc
make client-create-export name=lechuga-note ip=auto owner=lechuga device=notebook
```

Notas:

- `--vpn-ip auto` toma la siguiente IP libre del rango definido en el JSON.
- La IP fija se escribe en `ovpn-data/ccd/<cliente>`.
- El JSON sirve como inventario de asignaciones por perfil/dispositivo.

Sobre `package`: genera un `.zip` con el perfil `.ovpn`, `metadata.json` y hashes (`SHA256SUMS` + hash del zip).

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

## Firewall (iptables)

Para entender y operar las reglas del host (`VPNSITE_FORWARD`, puertos permitidos, `DROP` final tun->tun, persistencia y troubleshooting), revisa:

- [`IPTABLES.md`](./IPTABLES.md)

# ovpn-s2s-data

Carpeta de configuración del cliente OpenVPN site-to-site (`openvpn-s2s`).

## Uso rápido

1. Copia la plantilla:

```bash
cp ovpn-s2s-data/client.conf.example ovpn-s2s-data/client.conf
```

2. Deja aquí los archivos necesarios del cliente (`ca.crt`, `*.crt`, `*.key`, `ta.key`) y ajusta rutas en `client.conf`.

3. Levanta el cliente S2S:

```bash
docker compose -f docker-compose.s2s.yml up -d
```

4. Revisa estado:

```bash
docker compose -f docker-compose.s2s.yml ps
docker compose -f docker-compose.s2s.yml logs -f --tail=100 openvpn-s2s
```

## Nota

- Este stack es independiente del servidor OpenVPN principal (`docker-compose.yml`).
- No mezclar llaves/PKI del servidor con llaves de cliente de S2S.

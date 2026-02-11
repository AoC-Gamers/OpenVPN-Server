.DEFAULT_GOAL := help

# Nota: pensado para ejecutarse en Linux (host del servidor).
# Uso:
#   make client-create-export name=lechuga
#   make client-revoke name=lechuga

OVPN_SCRIPT := ./scripts/ovpn.sh
BACKUP_SCRIPT := ./scripts/backup.sh

.PHONY: help menu up down restart logs status health \
	client-create client-create-pass client-export client-create-export \
	client-revoke client-revoke-remove client-list client-show client-qr client-package \
	backup-menu backup-create backup-list backup-verify backup-restore backup-delete

help:
	@echo "Targets:"
	@echo "  make up|down|restart|logs|status|health"
	@echo "  make menu"
	@echo "  make client-create name=<cliente>"
	@echo "  make client-create-pass name=<cliente>"
	@echo "  make client-export name=<cliente> [out=./clients/<cliente>.ovpn] [force=1]"
	@echo "  make client-create-export name=<cliente> [pass=1]"
	@echo "  make client-revoke name=<cliente>"
	@echo "  make client-revoke-remove name=<cliente>"
	@echo "  make client-list"
	@echo "  make client-show name=<cliente>"
	@echo "  make client-qr name=<cliente> [out=./clients/<cliente>.png] [force=1]"
	@echo "  make client-package name=<cliente> [pass=1] [force=1]"
	@echo "  (Notas: export exige .ovpn, qr exige .png; force=1 sobrescribe archivos, no recrea credenciales)"
	@echo "  make backup-menu"
	@echo "  make backup-create [name=<nombre>]"
	@echo "  make backup-list"
	@echo "  make backup-verify file=<ruta.tar.gz>"
	@echo "  make backup-restore file=<ruta.tar.gz> [force=1]"
	@echo "  make backup-delete file=<ruta.tar.gz>"

menu:
	@$(OVPN_SCRIPT) menu

up:
	docker compose up -d

down:
	docker compose down

restart:
	docker compose restart openvpn

logs:
	docker compose logs -f --tail=200 openvpn

status:
	@docker compose ps
	@echo "---"
	@ip -br a | grep tun || true

health:
	@./scripts/health.sh

client-create:
	@if [ -z "$(name)" ]; then echo "Falta: name=<cliente>"; exit 2; fi
	@$(OVPN_SCRIPT) create "$(name)"

client-create-pass:
	@if [ -z "$(name)" ]; then echo "Falta: name=<cliente>"; exit 2; fi
	@$(OVPN_SCRIPT) create "$(name)" --pass

client-export:
	@if [ -z "$(name)" ]; then echo "Falta: name=<cliente>"; exit 2; fi
	@if [ -n "$(out)" ] && [ "$(force)" = "1" ]; then \
		$(OVPN_SCRIPT) export "$(name)" --out "$(out)" --force; \
	elif [ -n "$(out)" ]; then \
		$(OVPN_SCRIPT) export "$(name)" --out "$(out)"; \
	elif [ "$(force)" = "1" ]; then \
		$(OVPN_SCRIPT) export "$(name)" --force; \
	else \
		$(OVPN_SCRIPT) export "$(name)"; \
	fi

client-create-export:
	@if [ -z "$(name)" ]; then echo "Falta: name=<cliente>"; exit 2; fi
	@if [ "$(pass)" = "1" ]; then $(OVPN_SCRIPT) create-export "$(name)" --pass; else $(OVPN_SCRIPT) create-export "$(name)"; fi

client-revoke:
	@if [ -z "$(name)" ]; then echo "Falta: name=<cliente>"; exit 2; fi
	@$(OVPN_SCRIPT) revoke "$(name)"

client-revoke-remove:
	@if [ -z "$(name)" ]; then echo "Falta: name=<cliente>"; exit 2; fi
	@$(OVPN_SCRIPT) revoke "$(name)" --remove

client-list:
	@$(OVPN_SCRIPT) list

client-show:
	@if [ -z "$(name)" ]; then echo "Falta: name=<cliente>"; exit 2; fi
	@$(OVPN_SCRIPT) show "$(name)"

client-qr:
	@if [ -z "$(name)" ]; then echo "Falta: name=<cliente>"; exit 2; fi
	@if [ -n "$(out)" ] && [ "$(force)" = "1" ]; then \
		$(OVPN_SCRIPT) qr "$(name)" --out "$(out)" --force; \
	elif [ -n "$(out)" ]; then \
		$(OVPN_SCRIPT) qr "$(name)" --out "$(out)"; \
	elif [ "$(force)" = "1" ]; then \
		$(OVPN_SCRIPT) qr "$(name)" --force; \
	else \
		$(OVPN_SCRIPT) qr "$(name)"; \
	fi

client-package:
	@if [ -z "$(name)" ]; then echo "Falta: name=<cliente>"; exit 2; fi
	@if [ "$(pass)" = "1" ] && [ "$(force)" = "1" ]; then \
		$(OVPN_SCRIPT) package "$(name)" --pass --force; \
	elif [ "$(pass)" = "1" ]; then \
		$(OVPN_SCRIPT) package "$(name)" --pass; \
	elif [ "$(force)" = "1" ]; then \
		$(OVPN_SCRIPT) package "$(name)" --force; \
	else \
		$(OVPN_SCRIPT) package "$(name)"; \
	fi

backup-menu:
	@$(BACKUP_SCRIPT) menu

backup-create:
	@if [ -n "$(name)" ]; then $(BACKUP_SCRIPT) create --name "$(name)"; else $(BACKUP_SCRIPT) create; fi

backup-list:
	@$(BACKUP_SCRIPT) list

backup-verify:
	@if [ -z "$(file)" ]; then echo "Falta: file=<ruta.tar.gz>"; exit 2; fi
	@$(BACKUP_SCRIPT) verify "$(file)"

backup-restore:
	@if [ -z "$(file)" ]; then echo "Falta: file=<ruta.tar.gz>"; exit 2; fi
	@if [ "$(force)" = "1" ]; then $(BACKUP_SCRIPT) restore "$(file)" --force; else $(BACKUP_SCRIPT) restore "$(file)"; fi

backup-delete:
	@if [ -z "$(file)" ]; then echo "Falta: file=<ruta.tar.gz>"; exit 2; fi
	@$(BACKUP_SCRIPT) delete "$(file)"

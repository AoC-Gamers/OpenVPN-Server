.DEFAULT_GOAL := help

# Nota: pensado para ejecutarse en Linux (host del servidor).
# Uso:
#   make client-create-export name=lechuga-pc ip=auto owner=lechuga device=pc
#   make client-revoke name=lechuga-pc

OVPN_SCRIPT := ./scripts/ovpn.sh
BACKUP_SCRIPT := ./scripts/backup.sh
S2S_PACKAGE_SCRIPT := ./scripts/s2s-package.sh

.PHONY: help menu up down restart logs status health s2s-up s2s-down s2s-restart s2s-logs s2s-status \
	s2s-package \
	client-create client-export client-create-export client-ip-assign client-ip-list client-ip-sync \
	client-revoke client-revoke-remove client-list client-show client-package \
	backup-menu backup-create backup-list backup-verify backup-restore backup-delete

help:
	@echo "Targets:"
	@echo "  make up|down|restart|logs|status|health"
	@echo "  make s2s-up|s2s-down|s2s-restart|s2s-logs|s2s-status"
	@echo "  make s2s-package name=<cliente-s2s> [out=./packages/<archivo>.tar.gz] [force=1]"
	@echo "  make menu"
	@echo "  make client-create name=<cliente> [ip=auto] [owner=<owner>] [device=<device>] [pass=1]"
	@echo "  make client-export name=<cliente> [out=./clients/<cliente>.ovpn] [force=1]"
	@echo "  make client-create-export name=<cliente> [ip=auto] [owner=<owner>] [device=<device>] [pass=1]"
	@echo "  make client-ip-assign name=<cliente> [ip=auto] [owner=<owner>] [device=<device>]"
	@echo "  make client-ip-list"
	@echo "  make client-ip-sync"
	@echo "  make client-revoke name=<cliente>"
	@echo "  make client-revoke-remove name=<cliente>"
	@echo "  make client-list"
	@echo "  make client-show name=<cliente>"
	@echo "  make client-package name=<cliente> [pass=1] [force=1]"
	@echo "  (Notas: export exige .ovpn; force=1 sobrescribe archivos, no recrea credenciales)"
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

s2s-up:
	docker compose -f docker-compose.s2s.yml up -d

s2s-down:
	docker compose -f docker-compose.s2s.yml down

s2s-restart:
	docker compose -f docker-compose.s2s.yml restart openvpn-s2s

s2s-logs:
	docker compose -f docker-compose.s2s.yml logs -f --tail=200 openvpn-s2s

s2s-status:
	@docker compose -f docker-compose.s2s.yml ps
	@echo "---"
	@ip -br a | grep tun || true

s2s-package:
	@if [ -z "$(name)" ]; then echo "Falta: name=<cliente-s2s>"; exit 2; fi
	@if [ -n "$(out)" ] && [ "$(force)" = "1" ]; then \
		$(S2S_PACKAGE_SCRIPT) "$(name)" --out "$(out)" --force; \
	elif [ -n "$(out)" ]; then \
		$(S2S_PACKAGE_SCRIPT) "$(name)" --out "$(out)"; \
	elif [ "$(force)" = "1" ]; then \
		$(S2S_PACKAGE_SCRIPT) "$(name)" --force; \
	else \
		$(S2S_PACKAGE_SCRIPT) "$(name)"; \
	fi

client-create:
	@if [ -z "$(name)" ]; then echo "Falta: name=<cliente>"; exit 2; fi
	@args="--vpn-ip $(if $(ip),$(ip),auto)"; \
	if [ -n "$(owner)" ]; then args="$$args --owner $(owner)"; fi; \
	if [ -n "$(device)" ]; then args="$$args --device $(device)"; fi; \
	if [ -n "$(note)" ]; then args="$$args --note \"$(note)\""; fi; \
	if [ "$(pass)" = "1" ]; then args="$$args --pass"; fi; \
	if [ "$(force)" = "1" ]; then args="$$args --force"; fi; \
	$(OVPN_SCRIPT) create "$(name)" $$args

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
	@args="--vpn-ip $(if $(ip),$(ip),auto)"; \
	if [ -n "$(owner)" ]; then args="$$args --owner $(owner)"; fi; \
	if [ -n "$(device)" ]; then args="$$args --device $(device)"; fi; \
	if [ -n "$(note)" ]; then args="$$args --note \"$(note)\""; fi; \
	if [ "$(pass)" = "1" ]; then args="$$args --pass"; fi; \
	if [ "$(force)" = "1" ]; then args="$$args --force"; fi; \
	$(OVPN_SCRIPT) create-export "$(name)" $$args

client-ip-assign:
	@if [ -z "$(name)" ]; then echo "Falta: name=<cliente>"; exit 2; fi
	@args="--vpn-ip $(if $(ip),$(ip),auto)"; \
	if [ -n "$(owner)" ]; then args="$$args --owner $(owner)"; fi; \
	if [ -n "$(device)" ]; then args="$$args --device $(device)"; fi; \
	if [ -n "$(note)" ]; then args="$$args --note \"$(note)\""; fi; \
	if [ "$(force)" = "1" ]; then args="$$args --force"; fi; \
	$(OVPN_SCRIPT) ip-assign "$(name)" $$args

client-ip-list:
	@$(OVPN_SCRIPT) ip-list

client-ip-sync:
	@$(OVPN_SCRIPT) ip-sync

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

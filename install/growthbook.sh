#!/usr/bin/env bash
# =============================================================================
#  🧪 GrowthBook – One-Click-Installer (Proxmox VE)
#  https://github.com/HatchetMan111/GrowthBook-Proxmox
#
#  Erstellt einen unprivilegierten LXC-Container und installiert darin
#  GrowthBook (https://github.com/growthbook/growthbook): die Open-Source-
#  Plattform für Feature-Flags & A/B-Testing (freier Ersatz für LaunchDarkly/
#  Optimizely) mit Web-UI, REST-API, SDK-Connections (Streaming) und MCP-
#  Support. Nach dem Vorbild der Proxmox VE Community Scripts.
#
#  Architektur im Container: Docker CE + die 2 offiziellen Images
#  (growthbook/growthbook + mongo) in einer Compose-Datei nach dem exakten
#  Template des offiziellen Repos (docker-compose.yml), gehärtet und
#  gepinnt: Mongo bleibt komplett im Container-Netz (KEIN 27017-Exposure),
#  Web-UI (Port 3000) und API/SDK-Streaming (Port 3100) sind über 0.0.0.0
#  im LAN erreichbar. KEIN Build im CT. Telemetrie standardmäßig AUS
#  (DISABLE_TELEMETRY=true – dokumentierte Option von GrowthBook).
#
#  Secrets (.env, chmod 600): MONGO_PASS, JWT_SECRET (Pflicht bei
#  NODE_ENV=production – ohne wirft GrowthBook beim Boot einen Fehler),
#  ENCRYPTION_KEY (verschlüsselt SDK-Credentials; Wechsel nur per Migration).
#  APP_ORIGIN + API_HOST werden beim Boot automatisch auf die aktuelle
#  CT-IP synchronisiert (DHCP-IP-Hüpfer überlebt damit).
#
#  Installation (auf dem Proxmox-Host als root):
#    bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/GrowthBook-Proxmox/main/install/growthbook.sh)"
#
#  Mit Optionen (direkt hinter dem schließenden Anführungszeichen):
#    ... " --id 210 --memory 4096 --port 3000 --stream-port 3100
#
#  Update / Deinstall / Status / Debug:
#    ... " --update        |  ... " --uninstall  |  ... " --status  |  ... " --debug
# =============================================================================

# shellcheck disable=SC1111  # deutsche Anführungszeichen („…“) sind Absicht
set -Eeuo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
INSTALLER_VERSION="1.0.1"   # wird in --status/-Logs ausgegeben – hilft bei Fehlersuche
APP_NAME="growthbook"
UPSTREAM_OWNER="growthbook"
UPSTREAM_REPO="growthbook"
GB_VERSION="git-6c38e93"    # Image-Pin = Docker-Hub-Tag git-<sha> (≈ v5.2.1, Master
                            # 2026-11-19); GrowthBook veröffentlicht KEINE semver-
                            # Docker-Tags, nur latest + git-<sha> – deshalb pinnen
                            # wir den Commit und nicht :latest. --version überschreibt;
                            # --update zieht den hier gepinnten Stand.
MONGO_IMAGE="mongo:8"       # offizielles Template nutzt mongo:latest – gepinnt auf
                            # Major 8 (aktuelle stabile MongoDB, von GrowthBook
                            # unterstützt; mongo:latest = bewegliches Ziel)
APP_DIR="/opt/growthbook"   # Projektverzeichnis im Container
CT_ID=""                    # leer = automatisch nächste freie ID ab ID_SCAN_START
ID_SCAN_START=200
CT_HOSTNAME="growthbook"
CT_STORAGE="local-lvm"
CT_ROOTFS=12                # GB – Docker-Images (~2,5 GB) + Mongo-Daten (Events wachsen)
CT_CORES=2                  # Next.js-Frontend + Node-API + Mongo, kein Realtime-Bedarf
CT_MEMORY=4096              # MB – GrowthBook empfiehlt ≥ 2 GB; Node+Mongo+Docker-Overhead
CT_SWAP=1024                # MB Puffer für Pull/Entpacken-Spitzen
CT_BRIDGE="vmbr0"
CT_IP="dhcp"
CT_GATEWAY=""               # nur bei statischer IP nötig, z. B. 192.168.1.1
CT_PASSWORD=""              # leer = automatisch generieren
CT_SSHKEY=""                # Pfad ODER URL zu einer Public-Key-Datei (optional)
SSH_KEY_FILE=""             # aufgelöste Key-Datei für pct create
UI_PORT=3000                # Web-UI + API (Default der offiziellen Compose)
STREAM_PORT=3100            # API/SDK-Streaming-Port (Default der offiziellen Compose;
                            # SDK-Connections via Streaming & Visual-Editor-Proxy)
UNINSTALL=false
UPDATE=false
STATUS_CHECK=false
FORCE_RECREATE=false
ASSUME_YES=false
TMP_DIR=""
LOG_FILE="/tmp/${APP_NAME}-installer-$(date +%Y%m%d-%H%M%S).log"
# Der fertige Einzeiler für Hinweise/Fehlerausgaben – exakt kopierbar (Optionen
# hinter dem schließenden Anführungszeichen; der Installer erkennt sie via $0-Fallback)
# shellcheck disable=SC2016  # Absicht: Literal, das zum Ausgeben gedacht ist
ONE_LINER='bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/GrowthBook-Proxmox/main/install/growthbook.sh)"'

# ── Farben & Logging ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

info()  { echo -e "${BLUE}ℹ${NC}  $1"; }
ok()    { echo -e "${GREEN}✔${NC}  $1"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $1"; }
err()   { echo -e "${RED}✘${NC}  $1" >&2; }
die()   { err "$1"; exit 1; }
header(){ echo -e "\n${CYAN}${BOLD}━━━ $1 ━━━${NC}"; }

# ── Vollständiges Log mitschneiden (Debugging-Anforderung) ─────────────────
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
exec > >(tee "$LOG_FILE") 2>&1

# ── Cleanup & Fehlerkette ──────────────────────────────────────────────────
cleanup() {
    # if statt [[ ]] && – sonst gibt cleanup() bei leerem TMP_DIR Exit-Code 1
    # zurück und überschreibt den eigentlichen Exit-Status des Scripts.
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

# Gibt bei Fehlern die KOMPLETTE Fehlerkette aus: Zeile, Befehl, Exit-Code,
# letzte Logzeilen sowie Container-Logs (Setup + Docker-Compose), falls schon
# ein Container existiert.
on_error() {
    local ec=$1 line=$2 cmd=$3
    err "Installationsfehler – Exit-Code ${ec} in Zeile ${line}"
    err "Fehlgeschlagener Befehl: ${cmd}"
    if [[ -f "$LOG_FILE" ]]; then
        info "Letzte Logzeilen (${LOG_FILE}):"
        tail -n 20 "$LOG_FILE" | sed 's/^/    /' || true
    fi
    if [[ -n "${CT_ID:-}" ]] && pct status "$CT_ID" &>/dev/null; then
        info "Container-Logs (Setup + Docker):"
        pct exec "$CT_ID" -- sh -c '
            tail -n 40 /var/log/growthbook-setup.log 2>/dev/null
            echo "--- docker compose ps -a ---"
            docker compose --project-directory /opt/growthbook ps -a 2>/dev/null || true
            echo "--- docker compose logs (letzte 25 Zeilen) ---"
            docker compose --project-directory /opt/growthbook logs --tail 25 2>/dev/null || true
            echo "--- journalctl -u growthbook -u docker ---"
            journalctl -u growthbook --no-pager 2>/dev/null | tail -n 10 || true
            journalctl -u docker --no-pager 2>/dev/null | tail -n 10 || true
        ' 2>/dev/null | sed 's/^/    /' || true
        info "Container $CT_ID wurde NICHT gelöscht – Inspektion: pct enter $CT_ID"
        info "Aufräumen: pct stop $CT_ID && pct destroy $CT_ID --purge"
    fi
    info "Vollständiges Log: $LOG_FILE"
    info "Neu ausführen mit vollem bash -x-Trace (exakter Befehl):"
    echo "    ${ONE_LINER} --debug"
    exit "$ec"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# ── Debug-Modus (voller bash -x-Trace) ─────────────────────────────────────
# (Vor parse_args, damit --debug selbst noch mitgetraced wird.)
if [[ "${1:-}" == "--debug" || "$0" == "--debug" ]]; then
    set -x
fi

# ── Hilfsfunktionen ────────────────────────────────────────────────────────
ct_exists() {
    # if statt [[ ]] && … – Rückgabewert sauber halten.
    # Name ist in `pct list` IMMER die letzte Spalte (Lock kann leer sein).
    if pct list 2>/dev/null | awk '{print $NF}' | grep -qx "${1:-}"; then
        return 0
    fi
    return 1
}

find_free_id() {
    local id="$ID_SCAN_START"
    while pct list 2>/dev/null | awk '{print $1}' | grep -qx "$id"; do
        id=$((id + 1))
    done
    echo "$id"
}

find_ct_id_by_hostname() {
    pct list 2>/dev/null | awk -v h="$CT_HOSTNAME" '$NF==h {print $1; exit}'
}

get_ct_ip() {
    # Grube (pipefail): bei pct-exec-Fehlschlag stirbt die Substitution –
    # deshalb || true INNERHALB von $(). Bei statischer IP direkt nutzen.
    local ct_id="$1"
    if [[ "$CT_IP" != "dhcp" ]]; then
        echo "${CT_IP%%/*}"
        return 0
    fi
    pct exec "$ct_id" -- hostname -I 2>/dev/null | awk '{print $1}' || true
    return 0
}

wait_for_ct_network() {
    # Nach pct create --start nicht blind sleep 3 (DHCP/DNS-Race) – aktiv pollen.
    local id="$1" tries=0 ip=""
    info "Warte auf Netzwerk im Container (DHCP) ..."
    while true; do
        ip=$(pct exec "$id" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
        if [[ -n "$ip" ]]; then
            ok "Container-IP: $ip"
            return 0
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 60 ]]; then
            err "Container hat nach 60 s keine IP bekommen."
            info "Prüfe: pct exec $id -- ip a   und DHCP am Bridge-Interface ($CT_BRIDGE)"
            return 1
        fi
        sleep 1
    done
}

verify_ct_dns() {
    # IP allein reicht nicht – Docker-Images + get.docker.com brauchen Namensauflösung.
    # Live-Fund (Elmo-CT 200, 2026-11-10): DHCP-DNS ist FLAKY – ein einzelner
    # getent-Erfolg reichte, Stunden später war wieder alles tot. Deshalb:
    # 3 Erfolge in Folge verlangen; eine einzige Störung in diesem Fenster
    # → Fallback + Freeze.
    local id="$1" ok_count=0 tries=0
    info "Prüfe DNS im Container (3x hintereinander) ..."
    while true; do
        if pct exec "$id" -- getent hosts get.docker.com >/dev/null 2>&1; then
            ok_count=$((ok_count + 1))
            if [[ $ok_count -ge 3 ]]; then
                ok "DNS im Container funktioniert (3x bestätigt)"
                return 0
            fi
        else
            ok_count=0
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 10 ]]; then
            break
        fi
        sleep 2
    done
    # Fallback: DNS des Hosts (falls nicht loopback) + öffentliche Resolver eintragen
    local host_ns ns_list
    host_ns=$(grep -h '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | grep -v '^127\.' | head -1 || true)
    ns_list="1.1.1.1 8.8.8.8 9.9.9.9"
    if [[ -n "$host_ns" ]]; then
        ns_list="$host_ns $ns_list"
    fi
    warn "DNS im Container defekt – schreibe Fallback-Nameserver ($ns_list) nach /etc/resolv.conf"
    pct exec "$id" -- sh -c "printf 'nameserver %s\n' $ns_list > /etc/resolv.conf"
    # Dauerhaft: dhclient-Hook (verhindert das Überschreiben durch Lease-Renewals —
    # chattr +i funktioniert in unprivilegierten LXCs nicht) + nochmal prüfen.
    pct exec "$id" -- bash -c 'mkdir -p /etc/dhcp/dhclient-enter-hooks.d && printf "make_resolv_conf() { :; }\n" > /etc/dhcp/dhclient-enter-hooks.d/no-dns'
    if pct exec "$id" -- getent hosts get.docker.com >/dev/null 2>&1; then
        ok "DNS-Fallback aktiv und gegen DHCP-Überschreiben geschützt – Auflösung funktioniert"
        return 0
    fi
    die "DNS im Container weiterhin ohne Funktion (auch mit Fallback).\n  Prüfe: pct exec $id -- cat /etc/resolv.conf && pct exec $id -- ping -c2 1.1.1.1\n  Firewall/Router: ausgehende DNS-Anfragen (Port 53) am Bridge-Netz erlauben."
}

ensure_ct_running() {
    # Update-/Verwaltungs-Pfade müssen einen GESTOPPTEN CT selbst starten –
    # pct exec auf gestopptem CT scheitert kryptisch (Exit 255).
    local ct_id="$1"
    local state
    state=$(pct status "$ct_id" 2>/dev/null || echo "unknown")
    # pct status liefert "status: <wert>" – Prefix abschneiden für saubere Meldungen
    state="${state#status: }"
    if [[ "$state" == *"running"* ]]; then
        return 0
    fi
    warn "Container $ct_id läuft nicht (Status: ${state}) – starte ihn ..."
    if ! pct start "$ct_id" 2>&1 | tail -2; then
        die "Container $ct_id konnte nicht gestartet werden.\n  Manuell prüfen: pct start $ct_id && pct status $ct_id"
    fi
    info "Warte auf Netzwerk des Containers ..."
    local i ip=""
    for i in $(seq 1 60); do
        ip=$(pct exec "$ct_id" -- hostname -I 2>/dev/null | tr -d ' \n' || true)
        if [[ -n "$ip" ]]; then
            ok "Container läuft (IP: ${ip%% *})"
            return 0
        fi
        sleep 1
    done
    die "Container $ct_id hat nach 60 s keine IP (Bridge/Netz prüfen: pct exec $ct_id -- ip a)"
}

# ── Argumente parsen ───────────────────────────────────────────────────────
parse_args() {
    # Grube (bash -c): `bash -c "$(wget -qLO - URL)" --id 5` belegt das ERSTE
    # Argument nach dem Script-String mit $0, nicht $1 – die Option würde
    # still geschluckt. Fallback: startet $0 mit "-", ist es eine Option.
    local args=("$@")
    if [[ "$0" == -* ]]; then
        args=("$0" "$@")
    fi
    local i=0
    while [[ $i -lt ${#args[@]} ]]; do
        case "${args[$i]}" in
            --id)              CT_ID="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --hostname)        CT_HOSTNAME="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --storage)         CT_STORAGE="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --rootfs)          CT_ROOTFS="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --cores)           CT_CORES="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --memory)          CT_MEMORY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --swap)            CT_SWAP="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --bridge)          CT_BRIDGE="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --ip)              CT_IP="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --gateway)         CT_GATEWAY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --password)        CT_PASSWORD="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --sshkey)          CT_SSHKEY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --port)            UI_PORT="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --stream-port)     STREAM_PORT="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --version)         GB_VERSION="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --force)           FORCE_RECREATE=true; i=$((i+1)) ;;
            --yes|-y)          ASSUME_YES=true; i=$((i+1)) ;;
            --update)          UPDATE=true; i=$((i+1)) ;;
            --uninstall)       UNINSTALL=true; i=$((i+1)) ;;
            --status)          STATUS_CHECK=true; i=$((i+1)) ;;
            --debug)           set -x; i=$((i+1)) ;;
            --help|-h)         print_help; exit 0 ;;
            *) die "Unbekannte Option: ${args[$i]}  (--help zeigt alle Optionen)" ;;
        esac
    done
    # Ports hart validieren – sie landen direkt in der Compose-Config im Container.
    if ! [[ "$UI_PORT" =~ ^[0-9]+$ ]] || [[ "$UI_PORT" -lt 1 || "$UI_PORT" -gt 65535 ]]; then
        die "Ungültiger Port: '$UI_PORT' (1–65535 erwartet, z. B. --port 3000)"
    fi
    if ! [[ "$STREAM_PORT" =~ ^[0-9]+$ ]] || [[ "$STREAM_PORT" -lt 1 || "$STREAM_PORT" -gt 65535 ]]; then
        die "Ungültiger Stream-Port: '$STREAM_PORT' (1–65535 erwartet, z. B. --stream-port 3100)"
    fi
    if [[ "$STREAM_PORT" == "$UI_PORT" ]]; then
        die "Web-UI-Port und Stream-Port dürfen nicht identisch sein ($UI_PORT).\n  GrowthBook braucht zwei Ports: Web-UI (3000) + API/Streaming (3100)."
    fi
    # Image-Pin: Docker-Hub-Tag (z. B. git-6c38e93 oder Semver) – nur sichere Zeichen,
    # er landet direkt im Image-Reference im Container.
    if ! [[ "$GB_VERSION" =~ ^[0-9A-Za-z._-]+$ ]]; then
        die "Ungültige Versions-Pin-Angabe: '$GB_VERSION' (erwartet z. B. git-6c38e93)"
    fi
}

print_help() {
    cat <<'EOF'
🧪 GrowthBook – Proxmox-Installer (Feature-Flags & A/B-Testing, growthbook/growthbook)

Installation:   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/GrowthBook-Proxmox/main/install/growthbook.sh)"

Optionen (hinter dem schließenden Anführungszeichen anhängen, z. B. ... " --id 210):
  --id ID            Container-ID (Default: nächste freie ab 200)
  --hostname NAME    Container-Hostname (Default: growthbook)
  --storage NAME     Storage für rootfs (Default: local-lvm)
  --rootfs GB        Disk-Größe (Default: 12 – Docker-Images + Mongo-Daten)
  --cores N          vCPUs (Default: 2)
  --memory MB        RAM (Default: 4096 – GrowthBook empfiehlt ≥ 2 GB)
  --swap MB          Swap (Default: 1024)
  --bridge BR        Netzwerk-Bridge (Default: vmbr0)
  --ip CIDR          Statt DHCP, z. B. 192.168.1.50/24 (+ --gateway 192.168.1.1)
                     Empfehlenswert: feste IP (oder DHCP-Reservierung), damit die
                     APP_ORIGIN/API_HOST dauerhaft stimmen (Boot-Sync vorhanden).
  --gateway GW       Gateway für statische IP
  --password PW      Root-Passwort (Default: automatisch generiert)
  --sshkey PFAD      Public-Key-Datei oder URL – ssh-key-Login als root im CT
  --port PORT        Web-UI-Port (Default: 3000 – Default der offiziellen Compose)
  --stream-port PORT API/SDK-Streaming-Port (Default: 3100 – offizielle Compose)
  --version V        Image-Pin überschreiben (Default: git-6c38e93 ≈ v5.2.1;
                     GrowthBook-Docker-Tags sind git-<sha>, kein Semver)
  --force            Vorhandenen Container mit gleichem Hostname löschen und neu anlegen
  --yes / -y         Rückfragen überspringen
  --update           GrowthBook im bestehenden Container aktualisieren (.env bleibt)
  --uninstall        Container stoppen und löschen (ALLE Daten gehen verloren!)
  --status           Status anzeigen
  --debug            Vollständiges bash -x-Trace

  Modus:  Install (Default) / --update / --uninstall / --status / --debug
EOF
}

# ── In-Container-Setup-Script (idempotent) ─────────────────────────────────
# ACHTUNG: QUOTETER Heredoc ('INNEREOF') – nichts wird vom HOST-Script expandiert.
# Alle Werte (Ports, Version, DNS) kommen als Umgebungsvariablen via
# `pct exec -- env …` in den Container. Das vermeidet die Escaping-Grube bei
# Compose-/Shell-Sonderzeichen komplett.
write_inner_script() {
    cat > "$TMP_DIR/setup-inner.sh" <<'INNEREOF'
#!/usr/bin/env bash
# =============================================================================
# GrowthBook In-Container-Setup (idempotent – safe für Update & Re-Run)
# Variablen via env: APP_DIR, GB_VERSION, MONGO_IMAGE, UI_PORT, STREAM_PORT,
#                    HOST_DNS
# =============================================================================
set -Eeuo pipefail
trap 'echo "✘ Setup-Fehler: exit $? in Zeile $LINENO: $BASH_COMMAND" >&2' ERR
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C   # verhindert perl/locale-Warnungen im frischen Debian-CT

err(){ echo "✘ $1" >&2; }
ok(){ echo "✔ $1"; }
warn(){ echo "⚠ $1"; }
die(){ err "$1"; exit 1; }

: "${APP_DIR:?APP_DIR fehlt (env)}"
: "${GB_VERSION:?GB_VERSION fehlt (env)}"
: "${MONGO_IMAGE:?MONGO_IMAGE fehlt (env)}"
: "${UI_PORT:?UI_PORT fehlt (env)}"
: "${STREAM_PORT:?STREAM_PORT fehlt (env)}"

echo ">>> curl sicherstellen (nacktes Debian-Template hat KEIN curl) ..."
if ! command -v curl >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates >/dev/null
fi

echo ">>> DNS festschreiben (DHCP-DNS des Netzes ist unzuverlässig) ..."
# dhclient-Hook: verhindert, dass Lease-Renewals /etc/resolv.conf überschreiben.
# (chattr +i funktioniert in unprivilegierten LXCs nicht – fehlendes Capability,
#  Live-Fund 2026-11-10: CT-DNS war nach Stunden wieder kaputt.)
mkdir -p /etc/dhcp/dhclient-enter-hooks.d
printf '# GrowthBook: resolv.conf nicht von DHCP überschreiben lassen\nmake_resolv_conf() { :; }\n' > /etc/dhcp/dhclient-enter-hooks.d/no-dns
printf 'domain home.arpa\nsearch home.arpa\nnameserver %s\nnameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 9.9.9.9\n' "${HOST_DNS}" > /etc/resolv.conf

echo ">>> Docker installieren / prüfen ..."
if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL --retry 3 "https://get.docker.com" -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh >/dev/null 2>&1 || sh /tmp/get-docker.sh
else
    echo "    Docker bereits vorhanden: $(docker --version 2>/dev/null || echo 'unbekannt')"
fi
if ! docker compose version >/dev/null 2>&1; then
    die "docker compose (v2-Plugin) fehlt – get.docker.com hätte es installieren müssen.\n  Debug: docker --version; ls /usr/libexec/docker/cli-plugins/"
fi
# Docker-Daemon muss laufen (Debian startet ihn bei apt-Install meist schon)
systemctl enable docker >/dev/null 2>&1 || true
if ! docker info >/dev/null 2>&1; then
    systemctl start docker
    for _ in $(seq 1 30); do
        if docker info >/dev/null 2>&1; then break; fi
        sleep 1
    done
    docker info >/dev/null 2>&1 || die "Docker-Daemon startet nicht.\n  Debug: journalctl -u docker -e"
fi

echo ">>> Compose-Datei schreiben (offizielles docker-compose.yml-Template, gehärtet) ..."
#  - Image-Pins via GB_VERSION/MONGO_IMAGE (KEIN :latest – Updates laufen gezielt
#    über den Installer (--update), nicht unbemerkt beim Boot)
#  - Mongo OHNE ports-Block: bleibt komplett im internen Compose-Netz (die
#    offizielle Vorlage exponiert ihn nicht, wir halten das explizit fest)
#  - Mongo-Healthcheck (mongosh ping) + growthbook startet erst bei
#    service_healthy → kein First-Boot-Race bei der Mongo-Verbindung
#  - MONGO_INITDB_ROOT_PASSWORD: ${MONGO_PASS} interpoliert Compose aus .env
#    (MONGODB_URI in .env trägt DASSELBE generierte Passwort – einmalig
#    erzeugt, danach unverändert, sonst lehnt der initialisierte Mongo-Volume
#    neue Credentials ab)
#  - restart: unless-stopped auf beiden Services → Überleben nach Reboot/Crash
#    (docker-seitig; zusätzlich überwacht systemd den ganzen Stack)
mkdir -p "$APP_DIR"
cat > "$APP_DIR/docker-compose.yaml" <<COMPEOF
name: growthbook

services:
  mongo:
    image: ${MONGO_IMAGE}
    restart: unless-stopped
    environment:
      MONGO_INITDB_ROOT_USERNAME: root
      MONGO_INITDB_ROOT_PASSWORD: \${MONGO_PASS}
    volumes:
      - mongodata:/data/db
    healthcheck:
      test: ["CMD-SHELL", "mongosh --quiet --eval \\"db.adminCommand('ping')\\""]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
  growthbook:
    image: growthbook/growthbook:${GB_VERSION}
    restart: unless-stopped
    env_file:
      - path: .env
        required: true
    ports:
      - "${UI_PORT}:3000"
      - "${STREAM_PORT}:3100"
    depends_on:
      mongo:
        condition: service_healthy
    volumes:
      - uploads:/usr/local/src/app/packages/back-end/uploads

volumes:
  uploads:
  mongodata:
COMPEOF
cd "$APP_DIR"

# ── .env: Secrets idempotent erzeugen (bestehende bleiben erhalten) ─────────
generate_secret() {
    # lange Zufalls-Hex-Strings (JWT_SECRET / ENCRYPTION_KEY / MONGO_PASS)
    if command -v openssl >/dev/null 2>&1; then openssl rand -hex 32; return 0; fi
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
}
generate_secret_short() {
    if command -v openssl >/dev/null 2>&1; then openssl rand -hex 16; return 0; fi
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
}
dotenv_get() {
    # Wert eines Keys aus .env lesen (leer, wenn nicht vorhanden)
    local key=$1 line
    [[ -f .env ]] || { return 0; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            "$key"=*) printf '%s' "${line#*=}"; return 0 ;;
        esac
    done < .env
    return 0
}
dotenv_set() {
    # Key setzen/ersetzen; fehlende .env wird erzeugt
    local key=$1 value=$2 tmp=".env.tmp.$$" line updated=false
    if [[ -f .env ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            case "$line" in
                "$key"=*) printf '%s=%s\n' "$key" "$value"; updated=true ;;
                *) printf '%s\n' "$line" ;;
            esac
        done < .env > "$tmp"
        if [[ "$updated" != "true" ]]; then
            printf '%s=%s\n' "$key" "$value" >> "$tmp"
        fi
    else
        printf '%s=%s\n' "$key" "$value" > "$tmp"
    fi
    mv -f "$tmp" .env
}

echo ">>> .env erzeugen/prüfen (Secrets bleiben bei Update erhalten) ..."
# MONGO_PASS: einmal generiert und FESTGEHALTEN – der Mongo-Volume initialisiert
# sich mit den Credentials des ERSTEN Boots; eine spätere Änderung würde die
# Verbindung brechen (Mongo akzeptiert nur die initialen Root-Credentials).
if [[ -z "$(dotenv_get MONGO_PASS)" ]]; then
    dotenv_set MONGO_PASS "$(generate_secret_short)"
    echo "    MONGO_PASS erzeugt"
fi
# MONGODB_URI aus MONGO_PASS abgeleitet – nur ERSTBELEGUNG; ein bestehender Wert
# (z. B. externes Mongo) wird nicht überschrieben.
[[ -n "$(dotenv_get MONGODB_URI)" ]] || \
    dotenv_set MONGODB_URI "mongodb://root:$(dotenv_get MONGO_PASS)@mongo:27017/growthbook?authSource=admin"
if [[ -z "$(dotenv_get JWT_SECRET)" ]]; then
    # NODE_ENV=production OHNE JWT_SECRET wirft beim Boot einen Fehler (Docs) –
    # deshalb immer setzen.
    dotenv_set JWT_SECRET "$(generate_secret)"
    echo "    JWT_SECRET erzeugt"
fi
if [[ -z "$(dotenv_get ENCRYPTION_KEY)" ]]; then
    # verschlüsselt SDK-Credentials (Data-Source-Keys) – Wechsel erfordert
    # Migrations-Script, deshalb einmalig und dann unverändert.
    dotenv_set ENCRYPTION_KEY "$(generate_secret)"
    echo "    ENCRYPTION_KEY erzeugt"
fi
[[ -n "$(dotenv_get NODE_ENV)" ]]       || dotenv_set NODE_ENV "production"
[[ -n "$(dotenv_get UPLOAD_METHOD)" ]]  || dotenv_set UPLOAD_METHOD "local"
# Telemetrie: dokumentierte Option – standardmäßig AUS (Privacy-first).
# Zum Wiedereinschalten in .env auf "false" setzen und den Stack neu starten.
if [[ -z "$(dotenv_get DISABLE_TELEMETRY)" ]]; then
    dotenv_set DISABLE_TELEMETRY "true"
    echo "    DISABLE_TELEMETRY=true gesetzt (Telemetrie aus)"
fi
# APP_ORIGIN (Frontend) / API_HOST (API+SDK-Streaming) werden unten
# (sync-app-url.sh) auf die aktuelle CT-IP gesetzt bzw. aktualisiert –
# nur der ERSTE Eintrag kommt hier als Fallback rein:
[[ -n "$(dotenv_get APP_ORIGIN)" ]] || dotenv_set APP_ORIGIN "http://127.0.0.1:${UI_PORT}"
[[ -n "$(dotenv_get API_HOST)" ]]   || dotenv_set API_HOST "http://127.0.0.1:${STREAM_PORT}"
chmod 600 .env

echo ">>> Compose-Konfiguration validieren ..."
docker compose config -q || die "docker compose config meldet Fehler (Compose-Datei/.env prüfen).\n  Debug: cd $APP_DIR && docker compose config"

echo ">>> APP-URL-Sync-Script schreiben (passt .env bei IP-Wechsel an) ..."
cat > "${APP_DIR}/sync-app-url.sh" <<SYNCEOF
#!/usr/bin/env bash
# Synchronisiert die IP-abhängigen Einträge in .env mit der aktuellen CT-IP.
# Läuft als ExecStartPre vor jedem GrowthBook-Start – DHCP-IP-Hüpfer brechen
# damit APP_ORIGIN/API_HOST nicht mehr (SDK-Instructions & Cookies hängen
# daran). Domain-Modus: beginnt APP_ORIGIN mit https://, greift der Sync
# NICHT mehr (Reverse-Proxy/Domain-Eintrag bleibt erhalten).
set -euo pipefail
SELF_DIR=\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)
cd "\$SELF_DIR"
set_key() { # KEY VALUE – ersetzen oder anhängen (idempotent)
    if /bin/grep -q "^\$1=" .env; then
        /bin/sed -i "s|^\$1=.*|\$1=\$2|" .env
    else
        printf '%s=%s\n' "\$1" "\$2" >> .env
    fi
}
CURRENT=\$(sed -n 's/^APP_ORIGIN=//p' .env 2>/dev/null | head -1 || true)
case "\$CURRENT" in
    https://*) echo "growthbook-sync: Domain-Modus (APP_ORIGIN=\$CURRENT) – kein IP-Sync"; exit 0 ;;
esac
IP=\$(ip -4 addr show eth0 scope global 2>/dev/null | awk '/inet /{print \$2; exit}' | cut -d/ -f1 || true)
[[ -n "\$IP" ]] || { echo "growthbook-sync: keine globale IPv4 an eth0 – .env bleibt unverändert"; exit 0; }
WANT_ORIGIN="http://\${IP}:${UI_PORT}"
WANT_API="http://\${IP}:${STREAM_PORT}"
if [[ "\$CURRENT" != "\$WANT_ORIGIN" ]]; then
    echo "growthbook-sync: CT-IP geändert (\${CURRENT:-unbekannt} → \${IP}) – aktualisiere .env"
else
    echo "growthbook-sync: CT-IP unverändert (\${IP})"
fi
set_key APP_ORIGIN "\$WANT_ORIGIN"
set_key API_HOST "\$WANT_API"
SYNCEOF
chmod +x "${APP_DIR}/sync-app-url.sh"

echo ">>> systemd-Unit 'growthbook' schreiben (Restart=always) ..."
cat > /etc/systemd/system/growthbook.service <<'UNITEOF'
[Unit]
Description=GrowthBook Feature-Flags & A/B-Testing (docker compose)
Wants=network-online.target
After=network-online.target docker.service
Requires=docker.service

[Service]
# Attached `docker compose up`: systemd überwacht den Compose-Prozess,
# Restart=always startet den Stack bei Crash/Abbruch neu. Die Container
# tragen zusätzlich restart: unless-stopped (in der Compose-Datei).
Type=simple
WorkingDirectory=/opt/growthbook
ExecStartPre=/opt/growthbook/sync-app-url.sh
ExecStart=/usr/bin/docker compose --project-directory /opt/growthbook up --pull=missing
ExecStop=/usr/bin/docker compose --project-directory /opt/growthbook stop
Restart=always
RestartSec=15
TimeoutStopSec=90

[Install]
WantedBy=multi-user.target
UNITEOF
systemctl daemon-reload
systemctl enable growthbook >/dev/null 2>&1 || true

echo ">>> IP-abhängige .env-Einträge synchronisieren ..."
"${APP_DIR}/sync-app-url.sh"

echo ">>> Docker-Images ziehen (growthbook/growthbook + ${MONGO_IMAGE}) ..."
systemctl stop growthbook >/dev/null 2>&1 || true
docker compose pull

echo ">>> GrowthBook-Stack starten (docker compose up -d) ..."
docker compose up -d

echo ">>> systemd-Service starten (übernimmt den laufenden Stack) ..."
systemctl start growthbook

echo ">>> Warte auf Web-UI (http://127.0.0.1:${UI_PORT}/) ..."
WEB_OK=""
code="000"
for _ in $(seq 1 60); do
    code=$(curl -s -o /dev/null --max-time 3 -w '%{http_code}' \
           "http://127.0.0.1:${UI_PORT}/" || true)
    # 2xx/3xx: die Landingpage darf auf Signup/Onboarding umleiten
    if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
        WEB_OK=1
        break
    fi
    sleep 5
done
if [[ -z "$WEB_OK" ]]; then
    die "Web-UI antwortet nicht (letzter HTTP-Code: ${code:-keiner}).\n  Debug: cd $APP_DIR && docker compose ps -a && docker compose logs --tail 50 growthbook"
fi
ok "Web-UI antwortet (HTTP ${code})"

echo ">>> Prüfe API/SDK-Streaming-Port ${STREAM_PORT} ..."
scode="000"
scode=$(curl -s -o /dev/null --max-time 3 -w '%{http_code}' \
        "http://127.0.0.1:${STREAM_PORT}/" || true)
if [[ "$scode" != "000" ]]; then
    ok "API/Streaming-Port antwortet (HTTP ${scode})"
else
    warn "API/Streaming-Port ${STREAM_PORT} antwortet nicht – Web-UI funktioniert trotzdem;"
    warn "SDK-Connections via Streaming sind dann nicht nutzbar."
    warn "Logs: docker compose logs --tail 50 growthbook"
fi

echo ">>> Aufräumen ..."
rm -f /tmp/get-docker.sh

echo ">>> Setup abgeschlossen."
INNEREOF
}

run_inner_setup() {
    local ct_id="$1"
    header "⚙️  Installiere GrowthBook im Container $ct_id"
    # DNS des Hosts in den Container bringen (dort resolvert das Setup garantiert –
    # der DHCP-DNS des Zielnetzes war live unzuverlässig, siehe verify_ct_dns)
    HOST_DNS=$(grep -h '^nameserver' /etc/resolv.conf 2>/dev/null \
               | awk '{print $2}' | grep -v '^127\.' | head -1 || true)
    write_inner_script
    pct push "$ct_id" "$TMP_DIR/setup-inner.sh" /root/setup-inner.sh
    # Variablen via env in den Container (kein Expansion-Heredoc → keine
    # Escaping-Gruben). set -o pipefail: ein Crash im Inner-Script darf nicht
    # durch `tee` maskiert werden (Grube 14).
    pct exec "$ct_id" -- env APP_DIR="$APP_DIR" GB_VERSION="$GB_VERSION" \
        MONGO_IMAGE="$MONGO_IMAGE" UI_PORT="$UI_PORT" STREAM_PORT="$STREAM_PORT" \
        HOST_DNS="${HOST_DNS:-1.1.1.1}" \
        bash -c 'set -o pipefail; bash /root/setup-inner.sh 2>&1 | tee /var/log/growthbook-setup.log'
}

# ── Verifikation ───────────────────────────────────────────────────────────
verify_installation() {
    local ct_id="$1" tries=0 code=""

    header "✅ Verifikation"

    # systemd-Service aktiv?
    while true; do
        if pct exec "$ct_id" -- systemctl is-active --quiet growthbook 2>/dev/null; then
            ok "Service growthbook läuft (systemctl is-active)"
            break
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
            die "Service growthbook läuft nicht.\n  Debug: pct exec $ct_id -- journalctl -u growthbook -e && pct exec $ct_id -- systemctl status growthbook"
        fi
        sleep 1
    done

    # Compose-Services oben? (Mongo-Healthcheck gate't growthbook – ist
    # growthbook running, war auch mongo healthy.)
    local ps_out=""
    ps_out=$(pct exec "$ct_id" -- docker compose --project-directory "$APP_DIR" ps --format '{{.Service}} {{.State}}' 2>/dev/null || true)
    local missing=""
    for svc in mongo growthbook; do
        if ! grep -q "^${svc} " <<<"$ps_out"; then
            missing+="${svc} "
        fi
    done
    if [[ -n "$missing" ]]; then
        die "Compose-Services fehlen oder sind nicht hochgekommen: ${missing}\n  Debug: pct exec $ct_id -- docker compose --project-directory $APP_DIR ps -a\n  Logs:  pct exec $ct_id -- docker compose --project-directory $APP_DIR logs --tail 50"
    fi
    ok "Compose-Services laufen (mongo, growthbook)"

    # Web-UI antwortet? (Grube: curl -w gibt bei Verbindungsfehler bereits
    # 000 aus – NIE zusätzlich || echo 000 anhängen, sonst falsch-positiv.)
    tries=0
    code="000"
    while true; do
        code=$(pct exec "$ct_id" -- curl -s -o /dev/null --max-time 3 -w '%{http_code}' \
               "http://127.0.0.1:${UI_PORT}/" || true)
        if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
            ok "Web-UI antwortet (HTTP ${code} auf Port ${UI_PORT})"
            break
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
            die "Web-UI antwortet nicht (letzter HTTP-Code: ${code:-unbekannt}).\n  Debug: pct exec $ct_id -- docker compose --project-directory $APP_DIR logs --tail 50 growthbook"
        fi
        sleep 2
    done

    # API/Streaming-Port im CT (non-fatal – Secondary-Port)
    local scode=""
    scode=$(pct exec "$ct_id" -- curl -s -o /dev/null --max-time 3 -w '%{http_code}' \
            "http://127.0.0.1:${STREAM_PORT}/" || true)
    if [[ "$scode" != "000" ]]; then
        ok "API/Streaming-Port antwortet (HTTP ${scode} auf Port ${STREAM_PORT})"
    else
        warn "API/Streaming-Port ${STREAM_PORT} antwortet nicht (HTTP 000) – Web-UI/Features laufen trotzdem;"
        warn "nur SDK-Connections via Streaming sind eingeschränkt. Logs: docker compose logs growthbook"
    fi

    # Erreichbarkeit vom PROXMOX-HOST aus (die Nutzer-URL läuft über die CT-IP;
    # im CT-Loopback kann alles OK sein, während eine Firewall draußen blockt).
    local ct_ip="" host_code=""
    ct_ip=$(get_ct_ip "$ct_id")
    if [[ -n "$ct_ip" ]]; then
        host_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
                    "http://${ct_ip}:${UI_PORT}/" || true)
        if [[ "$host_code" =~ ^[23][0-9][0-9]$ ]]; then
            ok "Vom Host erreichbar: http://${ct_ip}:${UI_PORT} (HTTP ${host_code})"
        else
            warn "Im CT OK, aber vom Proxmox-Host nicht erreichbar (HTTP ${host_code:-000} über http://${ct_ip}:${UI_PORT})."
            info "Prüfe CT-Firewall (pct config $ct_id | grep -E 'net0|firewall') und Bridge-Setup."
        fi
    fi
}

# ── Zusammenfassung ────────────────────────────────────────────────────────
print_summary() {
    header "🧪  GrowthBook ist bereit!"

    local ct_ip=""
    ct_ip=$(get_ct_ip "$CT_ID")
    if [[ -z "$ct_ip" ]]; then
        ct_ip="<IP-ADRESSE>"
    fi

    echo ""
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}  🌐 Web-UI:    http://${ct_ip}:${UI_PORT}${NC}"
    echo -e "  ${GREEN}  🔌 API/SDK:   http://${ct_ip}:${STREAM_PORT}${NC}"
    echo -e "  ${GREEN}  🐚 Terminal:  pct enter ${CT_ID}${NC}"
    if [[ -n "$CT_PASSWORD" ]]; then
        echo -e "  ${GREEN}  🔑 Root-PW:   ${CT_PASSWORD}${NC}"
    fi
    echo -e "  ${GREEN}  🔧 Installer: v${INSTALLER_VERSION} (upstream ${UPSTREAM_OWNER}/${UPSTREAM_REPO})${NC}"
    echo -e "  ${GREEN}  📦 Image-Pin: growthbook/growthbook:${GB_VERSION}  +  ${MONGO_IMAGE}${NC}"
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${CYAN}Erste Schritte:${NC}"
    echo "  1. http://${ct_ip}:${UI_PORT} öffnen – der ERSTE registrierte Account"
    echo "     wird Organisations-Admin (lokale Instanz, keine Cloud nötig)"
    echo "  2. SDK-Connections anlegen: die UI zeigt als Host automatisch"
    echo "     http://${ct_ip}:${STREAM_PORT} (API_HOST wurde auf die CT-IP gesetzt)"
    echo "  3. Datensysteme (Warehouse/BigQuery etc.) verbinden, wenn du"
    echo "     Experiment-Auswertung nutzen willst – Feature-Flags laufen sofort"
    echo ""
    echo -e "  ${CYAN}Nützliche Befehle (exakt kopierbar):${NC}"
    echo "  Status:    ${ONE_LINER} --status"
    echo "  Update:    ${ONE_LINER} --update"
    echo "  Deinstall: ${ONE_LINER} --uninstall"
    echo "  Stack-Logs: pct exec ${CT_ID} -- docker compose --project-directory ${APP_DIR} logs -f"
    echo ""
    warn "Telemetrie ist standardmäßig AUS (DISABLE_TELEMETRY=true in ${APP_DIR}/.env)."
    warn "Daten (Mongo mit Flags/Experimenten + Uploads) liegen in Docker-Volumes"
    warn "im CT – ein --update erhält sie, pct destroy löscht sie."
    warn "Für Backups: pct backup / vzdump."
    if [[ "$CT_IP" == "dhcp" ]]; then
        warn "CT hat DHCP – bei IP-Wechsel sync'd das System APP_ORIGIN/API_HOST beim"
        warn "Boot selbst, trotzdem empfohlen: DHCP-Reservierung im Router (oder --ip)."
    fi
}

# ── Install ────────────────────────────────────────────────────────────────
do_install() {
    header "🧪 Installiere GrowthBook (LXC)"
    info "Installer-Version: v${INSTALLER_VERSION}"

    if [[ $EUID -ne 0 ]]; then
        die "Bitte als root ausführen (auf dem Proxmox-Host)."
    fi
    if ! command -v pct >/dev/null 2>&1; then
        die "pct nicht gefunden – das Script muss auf einem Proxmox-VE-Host laufen."
    fi

    # Bereits vorhanden?
    local existing
    existing=$(find_ct_id_by_hostname || true)
    if [[ -n "$existing" ]]; then
        if $FORCE_RECREATE; then
            warn "Container $existing ($CT_HOSTNAME) existiert – --force: lösche und lege neu an."
            pct stop "$existing" || true
            pct destroy "$existing" --purge
        else
            die "Container $existing mit Hostname '$CT_HOSTNAME' existiert bereits.\n  Update:  ${ONE_LINER} --update\n  Neu aufsetzen:  ${ONE_LINER} --force"
        fi
    fi

    # Debian-Template sicherstellen (13 bevorzugt – Docker unterstützt trixie;
    # rV-Sortierung nimmt 13 vor 12, Fallback bleibt)
    # ARCH-BEWUSST (Live-Fund ProxSmartHome, CT 210): im Template-Cache können
    # amd64 UND arm64 liegen – sort -rV würde _arm64 vor _amd64 wählen und ein
    # arm64-Rootfs startet auf amd64-Hosts NICHT (sync_wait: Failed to spawn).
    # Filter strikt auf die Host-Architektur.
    header "🧱 Container-Template"
    local host_arch=""
    host_arch=$(dpkg --print-architecture 2>/dev/null || uname -m || true)
    case "$host_arch" in
        x86_64|amd64)   host_arch="amd64" ;;
        aarch64|arm64)  host_arch="arm64" ;;
        *) die "Nicht unterstützte Host-Architektur: '${host_arch}' (amd64/arm64 erwartet)" ;;
    esac
    info "Host-Architektur: ${host_arch}"
    local template=""
    template=$(pveam list local 2>/dev/null | awk '{print $1}' | grep -o "debian-1[23]-standard[^ ]*_${host_arch}\.tar\.zst" | sort -rV | head -1 || true)
    if [[ -z "$template" ]]; then
        info "Kein Debian-12/13-${host_arch}-Template vorhanden – lade es herunter ..."
        pveam update
        template=$(pveam available --section system 2>/dev/null | grep -o "debian-1[23]-standard[^ ]*_${host_arch}\.tar\.zst" | sort -rV | head -1 || true)
        if [[ -z "$template" ]]; then
            die "Kein debian-12/13-standard_${host_arch}-Template gefunden (pveam available leer oder ohne diese Architektur?)."
        fi
        pveam download local "$template"
    fi
    ok "Template: $template (arch ${host_arch})"

    # ID & Passwort
    if [[ -z "$CT_ID" ]]; then
        CT_ID=$(find_free_id)
        info "Nächste freie CT-ID: $CT_ID"
    fi
    if [[ -z "$CT_PASSWORD" ]]; then
        CT_PASSWORD=$(openssl rand -base64 12 2>/dev/null || true)
        if [[ -z "$CT_PASSWORD" ]]; then
            CT_PASSWORD="growthbook-$(date +%s)"
        fi
    fi

    # Container anlegen
    header "🚀 Erzeuge Container $CT_ID ($CT_HOSTNAME)"
    local net0="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP}"
    if [[ -n "$CT_GATEWAY" ]]; then
        net0+=",gateway=${CT_GATEWAY}"
    fi
    net0+=",firewall=0"
    local ssh_keys_args=()
    if [[ -n "$CT_SSHKEY" ]]; then
        if [[ "$CT_SSHKEY" == http://* || "$CT_SSHKEY" == https://* ]]; then
            info "Lade SSH-Public-Key herunter ..."
            wget -q --tries=3 -O "$TMP_DIR/sshkey.pub" "$CT_SSHKEY" || die "SSH-Key-URL nicht ladbar: $CT_SSHKEY"
        elif [[ -f "$CT_SSHKEY" ]]; then
            cp "$CT_SSHKEY" "$TMP_DIR/sshkey.pub"
        else
            die "SSH-Key-Datei nicht gefunden: $CT_SSHKEY"
        fi
        if [[ ! -s "$TMP_DIR/sshkey.pub" ]]; then
            die "SSH-Key-Datei ist leer: $CT_SSHKEY"
        fi
        SSH_KEY_FILE="$TMP_DIR/sshkey.pub"
        ok "SSH-Public-Key wird in den Container installiert (ssh-key-Login als root)"
        ssh_keys_args=(--ssh-public-keys "$SSH_KEY_FILE")
    fi
    pct create "$CT_ID" "local:vztmpl/${template}" \
        --hostname "$CT_HOSTNAME" \
        --cores "$CT_CORES" \
        --memory "$CT_MEMORY" \
        --swap "$CT_SWAP" \
        --rootfs "${CT_STORAGE}:${CT_ROOTFS}" \
        --net0 "$net0" \
        --unprivileged 1 \
        --features nesting=1,keyctl=1 \
        --onboot 1 \
        --start 1 \
        --password "$CT_PASSWORD" \
        "${ssh_keys_args[@]}"

    # STARTVERIFIKATION (Live-Fund ProxSmartHome, CT 210): pct create --start 1
    # meldet gescheiterten Spawn NICHT über den Exit-Code (sync_wait-Fehler nur
    # auf stderr, "✔ Container erstellt und gestartet" wäre gelogen) – Status
    # aktiv verifizieren, bevor es weitergeht.
    local start_ok="" i
    for i in $(seq 1 15); do
        if [[ "$(pct status "$CT_ID" 2>/dev/null | awk '{print $2}')" == "running" ]]; then
            start_ok=1
            break
        fi
        sleep 1
    done
    if [[ -z "$start_ok" ]]; then
        die "Container $CT_ID startet nicht (pct create --start lief trotzdem Exit 0).\n\n  Häufigste Ursache: Template-Architektur passt nicht zum Host.\n  Prüfe: pct config $CT_ID | grep arch && dpkg --print-architecture\n  Aufräumen: pct destroy $CT_ID --purge\n  Neu (löscht den kaputten CT selbst):  ${ONE_LINER} --force"
    fi
    ok "Container $CT_ID erstellt und gestartet"

    wait_for_ct_network "$CT_ID"
    verify_ct_dns "$CT_ID"

    run_inner_setup "$CT_ID"
    verify_installation "$CT_ID"
    print_summary
}

# ── Update ─────────────────────────────────────────────────────────────────
do_update() {
    header "🔄 Update GrowthBook (Images ${GB_VERSION} ziehen, .env bleibt erhalten)"

    local ct_id
    ct_id=$(find_ct_id_by_hostname || true)
    if [[ -z "$ct_id" ]]; then
        die "Kein Container mit Hostname '$CT_HOSTNAME' gefunden.\n  Erst installieren:  ${ONE_LINER}"
    fi
    CT_ID="$ct_id"

    ensure_ct_running "$ct_id"
    verify_ct_dns "$ct_id"

    run_inner_setup "$ct_id"
    verify_installation "$ct_id"

    ok "Update abgeschlossen – Daten (Mongo-/Upload-Volumes) blieben erhalten."
    print_summary
}

# ── Uninstall ──────────────────────────────────────────────────────────────
do_uninstall() {
    header "🗑️  Deinstalliere GrowthBook"

    local ct_id
    ct_id=$(find_ct_id_by_hostname || true)
    if [[ -z "$ct_id" ]]; then
        warn "Kein Container mit Hostname '$CT_HOSTNAME' gefunden – nichts zu tun."
        return 0
    fi
    CT_ID="$ct_id"

    warn "Container $ct_id ($CT_HOSTNAME) wird GESTOPPT und GELÖSCHT."
    warn "ALLE Daten gehen verloren: Flags, Experimente, SDK-Keys (Mongo),"
    warn "hochgeladene Dateien (Uploads-Volume)."
    if ! $ASSUME_YES; then
        local answer=""
        if ! read -r -t 60 -p "Wirklich löschen? (ja/NEIN): " answer; then
            die "Keine Bestätigung erhalten (nicht-interaktiv?) – nichts gelöscht.\n  Erzwingen:  ${ONE_LINER} --uninstall --yes"
        fi
        if [[ "$answer" != "ja" ]]; then
            info "Abgebrochen – nichts gelöscht."
            return 0
        fi
    fi
    pct stop "$ct_id" || true
    pct destroy "$ct_id" --purge
    ok "Container $ct_id entfernt."
}

# ── Status ─────────────────────────────────────────────────────────────────
do_status() {
    header "📊 Status GrowthBook"
    info "Installer-Version: v${INSTALLER_VERSION} | Image-Pin (Script-Default): ${GB_VERSION}"

    local ct_id
    ct_id=$(find_ct_id_by_hostname || true)
    if [[ -z "$ct_id" ]]; then
        warn "Kein Container mit Hostname '$CT_HOSTNAME' gefunden."
        info "Installieren:  ${ONE_LINER}"
        return 0
    fi
    CT_ID="$ct_id"

    pct list 2>/dev/null | awk -v id="$ct_id" '$1==id {print "Container:  " $1 " (" $2 ") – " $NF}'

    # Gestoppten CT nicht als "Service läuft nicht" fehldeklarieren
    local state
    state=$(pct status "$ct_id" 2>/dev/null | awk '{print $2}' || true)
    if [[ "$state" != "running" ]]; then
        warn "Container $ct_id ist nicht gestartet (${state:-unbekannt}) – Service/Stack/Web-UI ohne Start nicht prüfbar."
        info "Starten:    pct start $ct_id"
        return 0
    fi

    if pct exec "$ct_id" -- systemctl is-active --quiet growthbook 2>/dev/null; then
        ok "Service:   growthbook läuft (systemctl is-active)"
    else
        err "Service:   growthbook läuft NICHT"
        info "Logs:      pct exec $ct_id -- journalctl -u growthbook -e"
    fi

    local ps_out=""
    ps_out=$(pct exec "$ct_id" -- docker compose --project-directory "$APP_DIR" ps --format '{{.Service}} {{.State}}' 2>/dev/null || true)
    if [[ -n "$ps_out" ]]; then
        info "Stack:     $(echo "$ps_out" | tr '\n' ' ' | sed 's/ $//')"
    else
        warn "Stack:     docker compose ps lieferte nichts (Stack noch nie gestartet?)"
    fi

    # Konfiguration (ohne Secrets auszugeben)
    local app_origin api_host tel pin=""
    app_origin=$(pct exec "$ct_id" -- sed -n 's/^APP_ORIGIN=//p' "${APP_DIR}/.env" 2>/dev/null | head -1 || true)
    api_host=$(pct exec "$ct_id" -- sed -n 's/^API_HOST=//p' "${APP_DIR}/.env" 2>/dev/null | head -1 || true)
    tel=$(pct exec "$ct_id" -- sed -n 's/^DISABLE_TELEMETRY=//p' "${APP_DIR}/.env" 2>/dev/null | head -1 || true)
    pin=$(pct exec "$ct_id" -- sed -n 's|^[[:space:]]*image: growthbook/growthbook:|STILL|p' "${APP_DIR}/docker-compose.yaml" 2>/dev/null | head -1 || true)
    if [[ -n "$app_origin" ]]; then
        info "APP_ORIGIN: $app_origin"
    fi
    if [[ -n "$api_host" ]]; then
        info "API_HOST:   $api_host"
    fi
    if [[ -n "$pin" ]]; then
        info "Image:      growthbook/growthbook:${pin#STILL}"
    fi
    if [[ "$tel" == "true" ]]; then
        ok "Telemetrie: AUS (DISABLE_TELEMETRY=true)"
    else
        warn "Telemetrie: AKTIV (DISABLE_TELEMETRY=${tel:-unset}) – in .env auf true setzen + --update."
    fi

    local ip code=""
    ip=$(get_ct_ip "$ct_id")
    if [[ -n "$ip" ]]; then
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${ip}:${UI_PORT}/" || true)
        if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
            ok "Web-UI:    http://${ip}:${UI_PORT}  (HTTP ${code})"
        else
            warn "Web-UI:    HTTP-Code ${code:-unbekannt} von http://${ip}:${UI_PORT}"
        fi
    else
        warn "Container hat keine IP (läuft er?)."
    fi
}

# ── Main ───────────────────────────────────────────────────────────────────
parse_args "$@"

TMP_DIR=$(mktemp -d)

if $UNINSTALL; then
    do_uninstall
elif $UPDATE; then
    do_update
elif $STATUS_CHECK; then
    do_status
else
    do_install
fi

#!/usr/bin/env bash
# =============================================================================
#  🧪 GrowthBook-Proxmox – Mock-Harness
#  Testet install/growthbook.sh End-to-End gegen gemockte Proxmox-/Docker-Umgebung:
#   - `unshare -rm` mappt den Harness-User auf root (EUID-Prüfung des Scripts)
#   - pct/pveam/curl/apt/docker/systemctl/ip/hostname/getent als Mocks (Fakebin)
#   - Inner-Script läuft ECHT (nur Pfade auf Mock-Root umgeschrieben, Docker &
#     systemctl gemockt) – inkl. Bootstrap-Reihenfolge (nacktes Debian: kein
#     curl, kein docker → apt "installiert" curl, get.docker.com docker)
#  Usage: bash harness/run.sh [-v]   (Exit 0 = alle Cases grün)
# =============================================================================
set -u
SCRIPT="/home/phil/Proxmox-Scripts/GrowthBook-Proxmox/install/growthbook.sh"
[[ -f "$SCRIPT" ]] || { echo "✘ Installer nicht gefunden: $SCRIPT"; exit 1; }

MK=$(mktemp -d /tmp/growthbook-harness.XXXXXX)
KEEP="${HARNESS_KEEP:-0}"
trap 'if [[ "$KEEP" == "1" ]]; then echo "(Behalten: $MK)"; else rm -rf "$MK"; fi' EXIT
HS="$MK/state"                       # Mock-Status (ct_list, Calls, Hebel)
HOSTBIN="$MK/bin-host"               # Mocks für das HOST-Script
INNERBIN="$MK/bin-inner"             # Mocks für pct-exec (im CT)
CASES="$MK/cases"; mkdir -p "$HS" "$HOSTBIN" "$INNERBIN" "$CASES" \
    "$MK/etc" "$MK/opt" "$MK/root" "$MK/var/log" "$MK/tmp"
CT_IP="10.120.5.42"
VER="git-6c38e93"                    # Image-Pin (wie im Installer als Default)

echo "$CT_IP" > "$HS/ct_ip"
: > "$HS/ct_list"                    # Zeilen: "VMID Status Lock-Name(=Name letztes Feld)"
echo "getent_mode=ok" > "$HS/getent_mode"

PASSED=0; FAILED=0; CUR_NAME=""; CUR_DIR=""

pass() { PASSED=$((PASSED+1)); echo "  ✔ $CUR_NAME – $1"; }
fail() { FAILED=$((FAILED+1)); echo "  ✘ $CUR_NAME – $1"; [[ -n "${2:-}" ]] && echo "      ↳ $2"; }

t()    { CUR_NAME="$1"; CUR_DIR=$(mktemp -d "$CASES/case.XXXXXX"); }
assert_exit() {
    local want="$1" got="$2"
    if [[ "$got" == "$want" ]]; then pass "exit=$got (erwartet $want)"
    else fail "exit=$got, erwartet $want"; fi
}
assert_out() {
    if /bin/grep -qF -- "$1" "$CUR_DIR/out.log" 2>/dev/null; then pass "Ausgabe enthält: $1"
    else fail "Ausgabe enthält NICHT: $1"; fi
}
assert_no_out() {
    if /bin/grep -qF -- "$1" "$CUR_DIR/out.log" 2>/dev/null; then fail "Ausgabe enthält (sollte nicht): $1"
    else pass "Ausgabe enthält nicht (korrekt): $1"; fi
}
assert_file() {
    if [[ -f "$1" ]]; then pass "Datei: $1"
    else fail "Datei fehlt: $1"; fi
}
# shellcheck disable=SC2329  # Debug-Helfer, absichtlich in Reserve
assert_no_file() {
    if [[ -f "$1" ]]; then fail "Datei existiert (sollte nicht): $1"
    else pass "Datei fehlt (korrekt): $1"; fi
}
assert_fcontains() {
    if [[ -f "$1" ]] && /bin/grep -qF -- "$2" "$1"; then pass "$1 enthält: $2"
    else fail "$1 enthält NICHT: $2"; fi
}
assert_fregex() {
    if [[ -f "$1" ]] && /bin/grep -qE -- "$2" "$1"; then pass "$1 matcht: $2"
    else fail "$1 matcht NICHT: $2"; fi
}
assert_no_fcontains() {
    if [[ -f "$1" ]] && /bin/grep -qF -- "$2" "$1"; then fail "$1 enthält (sollte nicht): $2"
    else pass "$1 enthält nicht (korrekt): $2"; fi
}
assert_calls() { # COUNT needle in mock-calls log (host-mocks: pct/systemctl/apt)
    local want="$1" needle="$2" got
    got=$(/bin/grep -cF -- "$needle" "$HS/calls.log" 2>/dev/null || true)
    if [[ "$got" -ge "$want" ]]; then pass "Calls ≥$want: $needle (ist $got)"
    else fail "Calls <$want: $needle (ist $got)"; fi
}
assert_docker() { # COUNT needle in docker_calls.log (docker compose …)
    local want="$1" needle="$2" got
    got=$(/bin/grep -cF -- "$needle" "$HS/docker_calls.log" 2>/dev/null || true)
    if [[ "$got" -ge "$want" ]]; then pass "Docker-Calls ≥$want: $needle (ist $got)"
    else fail "Docker-Calls <$want: $needle (ist $got)"; fi
}
# shellcheck disable=SC2329  # Debug-Helfer, absichtlich in Reserve
dump_case() {
    echo "---- out.log ($CUR_NAME) ----"; tail -n 40 "$CUR_DIR/out.log" 2>/dev/null
    echo "---- calls.log ----"; tail -n 25 "$HS/calls.log" 2>/dev/null
}

# ── Mock-Umgebung bauen (env -i: Profil-Funktionen wie grep→ugrep meiden) ──
realbin() { env -i /bin/sh -c "command -v $1" || { echo "✘ real binary fehlt: $1"; exit 1; }; }
link_real() { # echte Binaries per Symlink verfügbar halten (Shadowing via PATH-Reihenfolge)
    local dest="$1"; shift
    local b
    for b in "$@"; do ln -sf "$(realbin "$b")" "$dest/$b"; done
}
link_real "$HOSTBIN" bash sh env awk sed grep cut head tail tr od mktemp tee openssl \
    seq cat mv cp rm mkdir chmod dirname basename sort uniq readlink date printf ls touch \
    stat id uname hostname
ln -sf "$MK/mock-curl"  "$HOSTBIN/curl"
ln -sf "$MK/mock-pct"   "$HOSTBIN/pct"
ln -sf "$MK/mock-pveam" "$HOSTBIN/pveam"
ln -sf "$MK/mock-sleep" "$HOSTBIN/sleep"
ln -sf "$MK/mock-sleep" "$INNERBIN/sleep"

# ── Inner-Fakebin: nacktes Debian simulieren (KEIN curl, KEIN docker) ──────
# PATH im Inner ist AUSSCHLIESSLICH $INNERBIN (kein /usr/bin!) – sonst würde
# ein echtes curl/docker des Desktops das Bootstrap-Design aushebeln.
link_real "$INNERBIN" bash sh env awk sed grep cut head tail tr od seq cat mv cp rm \
    mkdir chmod dirname basename sort uniq printf ls touch readlink stat uname \
    tee openssl wc ln base64
ln -sf "$MK/mock-aptget"    "$INNERBIN/apt-get"
ln -sf "$MK/mock-systemctl" "$INNERBIN/systemctl"
ln -sf "$MK/mock-ip"        "$INNERBIN/ip"
ln -sf "$MK/mock-hostname"  "$INNERBIN/hostname"
ln -sf "$MK/mock-getent"    "$INNERBIN/getent"

seed_inner_tools() { # simuliert bereits installiertes curl+docker (Update-Pfad)
    ln -sf "$MK/mock-curl"   "$INNERBIN/curl"
    ln -sf "$MK/mock-docker" "$INNERBIN/docker"
}
unseed_inner_tools() {
    rm -f "$INNERBIN/curl" "$INNERBIN/docker"
}

# ══════════════════════════ Mock-Binaries ══════════════════════════════════
cat > "$MK/mock-sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$MK/mock-pct" <<'EOF'
#!/usr/bin/env bash
# pct-Mock: State in $HARNESS_STATE, Mock-Root = dirname davon
set -u
HS="${HARNESS_STATE:?HARNESS_STATE fehlt}"
MK="$(dirname "$HS")"
echo "pct $*" >> "$HS/calls.log"
cmd="${1:-}"; id="${2:-}"
if [[ $# -gt 0 ]]; then shift; fi
if [[ $# -gt 0 ]]; then shift; fi

case "$cmd" in
    list)
        printf 'VMID       Status     Lock Name\n'
        [[ -s "$HS/ct_list" ]] && cat "$HS/ct_list"
        exit 0 ;;
    status)
        f="$HS/ct_${id}.status"
        [[ -f "$f" ]] || exit 2
        echo "status: $(cat "$f")"; exit 0 ;;
    create)
        # pct create ID TEMPLATE --flags...
        echo "pct $*" >> "$HS/calls.log"
        if [[ -f "$HS/create_fail" ]]; then echo "mock: create fehlgeschlagen" >&2; exit 255; fi
        tmpl="$1"; shift
        tmpl_base="${tmpl##*/}"
        if [[ ! -f "$HS/templates/$tmpl_base" ]]; then
            echo "mock: Template $tmpl nicht vorhanden" >&2; exit 2
        fi
        { echo "TEMPLATE=$tmpl"; echo "ARGS=$*"; } > "$HS/ct_${id}.create"
        hostname="ct-$id"
        prev=""
        for a in "$@"; do
            if [[ "$prev" == "--hostname" ]]; then hostname="$a"; fi
            prev="$a"
        done
        echo "$id running $hostname" >> "$HS/ct_list"
        echo "running" > "$HS/ct_${id}.status"
        echo "$hostname" > "$HS/ct_${id}.hostname"
        exit 0 ;;
    start)
        [[ -f "$HS/ct_${id}.status" ]] || { echo "mock: CT $id unbekannt" >&2; exit 2; }
        echo "running" > "$HS/ct_${id}.status"
        /bin/sed -i "s|^$id .*|$id running $(cat "$HS/ct_${id}.hostname" 2>/dev/null || echo ct-$id)|" "$HS/ct_list"
        exit 0 ;;
    stop)
        [[ -f "$HS/ct_${id}.status" ]] || { echo "mock: CT $id unbekannt" >&2; exit 2; }
        echo "stopped" > "$HS/ct_${id}.status"
        /bin/sed -i "s|^$id .*|$id stopped $(cat "$HS/ct_${id}.hostname" 2>/dev/null || echo ct-$id)|" "$HS/ct_list"
        exit 0 ;;
    destroy)
        /bin/sed -i "/^$id /d" "$HS/ct_list"
        rm -f "$HS/ct_${id}".status "$HS/ct_${id}".create "$HS/ct_${id}.hostname"
        exit 0 ;;
    push)
        src="$1"; dst="$2"; shift 2
        mkdir -p "$MK$(dirname "$dst")"
        # Inner-Script: /etc/ und /tmp/-Pfade auf Mock-Root umschreiben.
        # Reihenfolge WICHTIG: /tmp zuerst – die /etc-Ersetzung injiziert selbst
        # ein /tmp/ (Mock-Root liegt unter /tmp) und würde doppelt umgeschrieben.
        /bin/sed -e "s|/tmp/|$MK/tmp/|g" -e "s|/etc/|$MK/etc/|g" "$src" > "$MK$dst"
        exit 0 ;;
    exec)
        # pct exec ID -- env K=V... cmd...   (Grube 10: gestoppter CT → Exit 255)
        [[ "${1:-}" == "--" ]] && shift
        envs=()
        if [[ "${1:-}" == "env" ]]; then
            shift
            while [[ "${1:-}" == *=* && "${1:-}" != -* ]]; do envs+=("$1"); shift; done
        fi
        if [[ ! -f "$HS/ct_${id}.status" || "$(cat "$HS/ct_${id}.status" 2>/dev/null)" != "running" ]]; then
            echo "mock: CT $id läuft nicht" >&2
            echo "pct exec $id (ABGELEHNT – CT gestoppt)" >> "$HS/calls.log"
            exit 255
        fi
        if [[ -f "$HS/exec_fail" ]]; then
            echo "mock: exec erzwingt Fehler" >&2
            exit 255
        fi
        # Quoted-Heredoc: INNERBIN erst zur LAUFZEIT ableiten ($MK = dirname($HS))
        INNERBIN="$MK/bin-inner"
        # Pfad-Umschreibung: Kommando-Args UND env-Args (Mock-Root).
        # /etc auch umschreiben – sonst schreibt der DNS-Fallback des Installers
        # ins echte /etc der Sandbox!
        rewrite_path() {
            local a="$1"
            a="${a//\/opt\/growthbook/$MK/opt/growthbook}"
            a="${a//\/root\//$MK/root/}"
            a="${a//\/var\/log/$MK/var/log}"
            a="${a//\/etc\//$MK/etc/}"
            printf '%s' "$a"
        }
        newargs=()
        for a in "$@"; do
            newargs+=("$(rewrite_path "$a")")
        done
        newenvs=()
        for a in ${envs[@]+"${envs[@]}"}; do
            newenvs+=("$(rewrite_path "$a")")
        done
        exec env -i PATH="$INNERBIN" \
            HARNESS_STATE="$HS" MKROOT="$MK" \
            HOME=/root TERM=dumb LANG=C.UTF-8 \
            ${newenvs[@]+"${newenvs[@]}"} \
            "${newargs[@]}"
        ;;
    enter|config|rollback|clone|resume|suspend|reboot|snapshot|delvolume|mount|resize|move|reindex|set)
        exit 0 ;;
    *)
        echo "mock-pct: unbekannter Befehl $cmd" >&2; exit 1 ;;
esac
EOF

cat > "$MK/mock-pveam" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
echo "pveam $*" >> "$HS/calls.log"
TMPL="local:vztmpl/debian-13-standard_13.2-1_amd64.tar.zst"
case "${1:-}" in
    list)
        if [[ -f "$HS/template_downloaded" && ! -f "$HS/pveam_empty" ]]; then
            echo "$TMPL  123456789"
        fi
        exit 0 ;;
    available)
        if [[ ! -f "$HS/pveam_empty" ]]; then
            echo "system          $TMPL  123456789"
        fi
        exit 0 ;;
    update)   exit 0 ;;
    download)
        mkdir -p "$HS/templates"
        touch "$HS/templates/debian-13-standard_13.2-1_amd64.tar.zst"
        touch "$HS/template_downloaded"
        exit 0 ;;
esac
exit 0
EOF

cat > "$MK/mock-curl" <<'EOF'
#!/usr/bin/env bash
# curl-Mock: Health-/HTTP-Checks → 200/302/000; Downloads → Stub-Dateien
set -u
HS="${HARNESS_STATE:?}"
MK="$(dirname "$HS")"
url=""; outfile=""
prev=""
for a in "$@"; do
    if [[ "$prev" == "-o" ]]; then outfile="$a"; fi
    case "$a" in http://*|https://*) url="$a" ;; esac
    prev="$a"
done
echo "curl $*" >> "$HS/calls.log" 2>/dev/null || true

case "$url" in
    https://get.docker.com)
        # get.docker.com-Stub: "installiert" docker + compose-plugin (Mock)
        [[ -n "$outfile" ]] || { echo "curl mock: get.docker.com ohne -o" >&2; exit 1; }
        cat > "$outfile" <<'STUB'
#!/usr/bin/env bash
# get.docker.com-Mock-Stub: installiert docker-CLI + compose-plugin
INNERBIN_DIR="${MKROOT:?MKROOT fehlt}/bin-inner"
ln -sf "$MKROOT/mock-docker" "$INNERBIN_DIR/docker" 2>/dev/null
exit 0
STUB
        chmod +x "$outfile"
        exit 0 ;;
esac

# Health-/HTTP-Checks (Web-UI/API; 2xx/3xx zählen beide als "antwortet")
code="200"
if [[ -f "$HS/host_curl_fail" && -z "${MKROOT:-}" ]]; then
    code="000"
fi
if [[ -n "${MKROOT:-}" ]]; then
    # Inner-Ebene (Setup-Health-Checks + Verifikation über pct exec)
    [[ -f "$HS/fail_web"  ]] && code="000"
    [[ -f "$HS/web_302"   ]] && code="302"
    # API/Streaming-Port (3100 im Default) gezielt tot setzen (non-fatal-Warnung)
    if [[ "$url" == *":3100"* && -f "$HS/stream_fail" ]]; then
        code="000"
    fi
fi
echo "$code"
[[ "$code" == "000" ]] && exit 7 || exit 0
EOF

cat > "$MK/mock-docker" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
echo "docker $*" >> "$HS/docker_calls.log"
sub="${1:-}"
case "$sub" in
    --version|-v) echo "Docker version 27.5.1, build mock"; exit 0 ;;
    info) exit 0 ;;
    compose)
        shift  # "compose"
        # globale Flags mit Werten überspringen (--project-directory DIR, --file F)
        while [[ "${1:-}" == --* ]]; do
            case "$1" in
                --project-directory|--file|-f) shift 2 ;;
                *) shift ;;
            esac
        done
        c="${1:-}"
        case "$c" in
            version) echo "Docker Compose version v2.39.2"; exit 0 ;;
            config)
                [[ -f "$HS/docker_config_fail" ]] && exit 1
                exit 0 ;;
            pull)   exit 0 ;;
            up)     touch "$HS/stack_up"; exit 0 ;;
            stop)   rm -f "$HS/stack_up"; exit 0 ;;
            ps)
                [[ -f "$HS/ps_empty" ]] && exit 0
                if [[ -f "$HS/stack_up" ]]; then
                    # gb_down-Hebel: growthbook fehlt komplett → Verifikation muss die()
                    if [[ -f "$HS/gb_down" ]]; then
                        printf 'mongo running\n'
                    else
                        printf 'mongo running\ngrowthbook running\n'
                    fi
                fi
                exit 0 ;;
            logs)   echo "mock-compose-log-line"; exit 0 ;;
            *)      exit 0 ;;
        esac ;;
    *) echo "mock-docker: $sub (ignored)"; exit 0 ;;
esac
EOF

cat > "$MK/mock-systemctl" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
MK="$(dirname "$HS")"
echo "systemctl $*" >> "$HS/calls.log"
MKDIR_MOCK="$MK"
unitdir="$MKDIR_MOCK/etc/systemd/system"
sub="${1:-}"
case "$sub" in
    daemon-reload) exit 0 ;;
    enable)
        mkdir -p "$unitdir"; echo "${2:-}" >> "$HS/enabled_units"; exit 0 ;;
    start)
        if [[ "${2:-}" == "growthbook" ]]; then
            [[ -f "$unitdir/growthbook.service" ]] || { echo "mock: growthbook.service fehlt" >&2; exit 1; }
            touch "$HS/gb_active"
        elif [[ "${2:-}" == "docker" ]]; then
            touch "$HS/docker_active"
        fi
        exit 0 ;;
    stop)
        rm -f "$HS/gb_active" "$HS/docker_active"; exit 0 ;;
    is-active)
        svc="${3:-${2:-}}"
        if [[ "$svc" == "growthbook" && -f "$HS/gb_active" ]]; then exit 0; fi
        if [[ "$svc" == "docker" && -f "$HS/docker_active" ]]; then exit 0; fi
        exit 3 ;;
    status) echo "mock: ${2:-} active-ish"; exit 0 ;;
    *) exit 0 ;;
esac
EOF

cat > "$MK/mock-ip" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
if [[ -f "$HS/no_ip" ]]; then exit 0; fi
IP=$(cat "$HS/ct_ip" 2>/dev/null || echo "10.120.5.42")
printf '2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq state UP group default qlen 1000\n'
printf '    inet %s/24 scope global eth0\n       valid_lft forever preferred_lft forever\n' "$IP"
exit 0
EOF

cat > "$MK/mock-hostname" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
if [[ -f "$HS/no_hostname_ip" ]]; then exit 0; fi
IP=$(cat "$HS/ct_ip" 2>/dev/null || echo "10.120.5.42")
if [[ "${1:-}" == "-I" ]]; then printf '%s 2601:db8::1 \n' "$IP"; exit 0; fi
echo "growthbook"; exit 0
EOF

cat > "$MK/mock-getent" <<'EOF'
#!/usr/bin/env bash
# DNS-Mock: ok | fail | flaky (jeder 4. failt) | fail_then_ok (9x fail, dann ok)
set -u
HS="${HARNESS_STATE:?}"
mode="ok"
[[ -f "$HS/getent_mode" ]] && mode=$(/bin/sed -n 's/^getent_mode=//p' "$HS/getent_mode")
case "$mode" in
    ok) exit 0 ;;
    fail) exit 2 ;;
    flaky)
        n=$(cat "$HS/getent_count" 2>/dev/null || echo 0)
        n=$((n+1)); echo "$n" > "$HS/getent_count"
        if [[ $((n % 4)) -eq 0 ]]; then exit 2; fi
        exit 0 ;;
    fail_then_ok)
        n=$(cat "$HS/getent_count" 2>/dev/null || echo 0)
        n=$((n+1)); echo "$n" > "$HS/getent_count"
        # 9x fail → Loop bricht bei Try 10 ab → Fallback → Post-Check (Call 10) erfolgreich
        [[ "$n" -le 9 ]] && exit 2
        exit 0 ;;
esac
exit 0
EOF

cat > "$MK/mock-aptget" <<'EOF'
#!/usr/bin/env bash
# apt-Mock: installiert curl real in der Inner-Fakebin (Bootstrap-Reihenfolge)
set -u
HS="${HARNESS_STATE:?}"
MK="$(dirname "$HS")"
INNERBIN_DIR="$MK/bin-inner"
echo "apt-get $*" >> "$HS/calls.log"
if [[ "${1:-}" == "install" ]]; then
    for a in "$@"; do
        if [[ "$a" == "curl" && ! -e "$INNERBIN_DIR/curl" ]]; then
            ln -sf "$MK/mock-curl" "$INNERBIN_DIR/curl"
        fi
        if [[ "$a" == docker* && ! -e "$INNERBIN_DIR/docker" ]]; then
            ln -sf "$MK/mock-docker" "$INNERBIN_DIR/docker"
        fi
    done
fi
exit 0
EOF

chmod +x "$MK"/mock-* "$MK"/bin-host/* "$MK"/bin-inner/* 2>/dev/null

# ── Runner ─────────────────────────────────────────────────────────────────
reset_state() {
    rm -rf "$HS"; mkdir -p "$HS" "$HS/templates" "$MK/etc/systemd/system" "$MK/etc/dhcp" \
        "$MK/opt" "$MK/root" "$MK/var/log" "$MK/tmp"
    echo "$CT_IP" > "$HS/ct_ip"
    : > "$HS/ct_list"
    echo "getent_mode=ok" > "$HS/getent_mode"
    unseed_inner_tools   # Inner-Fakebin wieder auf "nacktes Debian" zurücksetzen
}
run_installer() {
    ( unshare -rm env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" \
        HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
        bash "$SCRIPT" "$@" > "$CUR_DIR/out.log" 2>&1 )
    echo $?
}
run_installer_stdin() {
    local input="$1"; shift
    ( printf '%s\n' "$input" | unshare -rm env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" \
        HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
        bash "$SCRIPT" "$@" > "$CUR_DIR/out.log" 2>&1 )
    echo $?
}
run_installer_devnull() {
    ( unshare -rm env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" \
        HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
        bash "$SCRIPT" "$@" < /dev/null > "$CUR_DIR/out.log" 2>&1 )
    echo $?
}
run_installer_bash_c() { # ECHTES bash -c-Muster: Option wird als $0 geliefert
    # Wie `bash -c "$(wget -qLO - URL)" --status`: der Script-TEXT ist der -c-String,
    # "--status" belegt $0 (nicht $1!) – genau das muss der $0-Fallback erkennen.
    ( unshare -rm env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" \
        HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
        bash -c "$(cat "$SCRIPT")" "--status" > "$CUR_DIR/out.log" 2>&1 )
    echo $?
}
seed_ct() { # laufender CT mit installiertem Stack
    reset_state
    echo "200 running growthbook" > "$HS/ct_list"
    echo "running" > "$HS/ct_200.status"
    echo "growthbook" > "$HS/ct_200.hostname"
    mkdir -p "$MK/opt/growthbook" "$MK/etc/systemd/system" "$MK/etc" "$MK/var/log"
    seed_inner_tools
    touch "$HS/stack_up" "$HS/gb_active" "$HS/template_downloaded"
    touch "$HS/templates/debian-13-standard_13.2-1_amd64.tar.zst"
    touch "$MK/etc/systemd/system/growthbook.service"
    cat > "$MK/opt/growthbook/docker-compose.yaml" <<COMPOSESEED
name: growthbook

services:
  mongo:
    image: mongo:8
  growthbook:
    image: growthbook/growthbook:${VER}
COMPOSESEED
    cat > "$MK/opt/growthbook/.env" <<ENVSEED
MONGO_PASS=aaaabbbbccccdddd1111222233334444
MONGODB_URI=mongodb://root:aaaabbbbccccdddd1111222233334444@mongo:27017/growthbook?authSource=admin
JWT_SECRET=1111222233334444555566667777888899990000aaaabbbbccccddddeeeeffff
ENCRYPTION_KEY=aaaabbbbccccddddeeeeffff0000111122223333444455556666777788889999
NODE_ENV=production
UPLOAD_METHOD=local
DISABLE_TELEMETRY=true
APP_ORIGIN=http://10.120.5.42:3000
API_HOST=http://10.120.5.42:3100
ENVSEED
}

ENV_PATH="$MK/opt/growthbook/.env"
COMPOSE_PATH="$MK/opt/growthbook/docker-compose.yaml"
UNIT_PATH="$MK/etc/systemd/system/growthbook.service"
SYNC_PATH="$MK/opt/growthbook/sync-app-url.sh"

echo "════════════════════════════════════════════════════════════"
echo " 🧪 GrowthBook-Proxmox Harness – $(date +%H:%M:%S)"
echo "════════════════════════════════════════════════════════════"

# ════════════════ A. Argumente & Grundlagen ════════════════
t "--help"
ec=$(run_installer --help); assert_exit 0 "$ec"
assert_out "GrowthBook – Proxmox-Installer"
assert_out "--update"

t "unbekannte Option"
ec=$(run_installer --schnulli); assert_exit 1 "$ec"
assert_out "Unbekannte Option: --schnulli"

t "--port ungültig"
ec=$(run_installer --port abc); assert_exit 1 "$ec"
assert_out "Ungültiger Port: 'abc'"

t "--stream-port ungültig"
ec=$(run_installer --stream-port abc); assert_exit 1 "$ec"
assert_out "Ungültiger Stream-Port: 'abc'"

t "--stream-port == --port (zwei Ports Pflicht)"
ec=$(run_installer --port 3000 --stream-port 3000); assert_exit 1 "$ec"
assert_out "dürfen nicht identisch sein"

t "--version ungültig (Sonderzeichen)"
ec=$(run_installer --version "git-abc rm -rf"); assert_exit 1 "$ec"
assert_out "Ungültige Versions-Pin-Angabe"

t "\$0-Fallback (bash -c-Muster: Option als \$0)"
ec=$(run_installer_bash_c); assert_exit 0 "$ec"
assert_out "Status GrowthBook"

t "nächste freie CT-ID (200-202 belegt)"
reset_state
printf '200 running foo\n201 running bar\n202 running baz\n' > "$HS/ct_list"
seed_inner_tools
touch "$HS/template_downloaded"
touch "$HS/templates/debian-13-standard_13.2-1_amd64.tar.zst"
ec=$(run_installer); assert_exit 0 "$ec"
assert_out "Nächste freie CT-ID: 203"
assert_fcontains "$HS/ct_203.create" "hostname growthbook"

t "pct list ohne Lock-Spalte (Name \$NF)"
reset_state
printf '200 running growthbook' > "$HS/ct_list"   # keine Lock-Spalte, doppelte Leerzeichen möglich
echo "running" > "$HS/ct_200.status"
seed_inner_tools
touch "$HS/stack_up" "$HS/gb_active" "$HS/template_downloaded"
mkdir -p "$MK/opt/growthbook" "$MK/etc/systemd/system"
touch "$MK/etc/systemd/system/growthbook.service"
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_out "Container:  200 (running) – growthbook"

# ════════════════ B. Install End-to-End ════════════════
t "Install End-to-End (nacktes Debian: curl+docker bootstrappen)"
reset_state
ec=$(run_installer); assert_exit 0 "$ec"
assert_out "Container-IP: $CT_IP"
assert_out "DNS im Container funktioniert (3x bestätigt)"
assert_out "debian-13-standard_13.2"
assert_fcontains "$HS/ct_200.create" "unprivileged"
assert_fcontains "$HS/ct_200.create" "nesting=1,keyctl=1"
assert_fcontains "$HS/ct_200.create" "onboot 1"
assert_fcontains "$HS/ct_200.create" "memory 4096"
assert_fcontains "$HS/ct_200.create" "swap 1024"
assert_fregex "$HS/ct_200.create" "rootfs local-lvm:12"
assert_fcontains "$HS/ct_200.create" "firewall=0"
assert_calls 1 "apt-get install"
assert_calls 1 "https://get.docker.com"
assert_docker 1 "pull"
assert_docker 1 "up"
assert_out "🧪  GrowthBook ist bereit!"
assert_out "http://$CT_IP:3000"
assert_out "http://$CT_IP:3100"
assert_out "Service growthbook läuft (systemctl is-active)"
assert_out "Compose-Services laufen (mongo, growthbook)"
assert_out "Web-UI antwortet (HTTP 200 auf Port 3000)"
assert_out "API/Streaming-Port antwortet (HTTP 200 auf Port 3100)"
assert_out "Vom Host erreichbar: http://$CT_IP:3000 (HTTP 200)"
assert_out "Status:    bash -c"
assert_out "Update:    bash -c"
assert_out "Deinstall: bash -c"

t "Compose-Datei: Pin, Härtung, Abhängigkeiten"
assert_file "$COMPOSE_PATH"
assert_fcontains "$COMPOSE_PATH" "name: growthbook"
assert_fcontains "$COMPOSE_PATH" "image: mongo:8"
assert_fcontains "$COMPOSE_PATH" "image: growthbook/growthbook:${VER}"
assert_fcontains "$COMPOSE_PATH" 'ports:
      - "3000:3000"'
assert_fcontains "$COMPOSE_PATH" 'ports:
      - "3100:3100"'
assert_no_fcontains "$COMPOSE_PATH" "27017:27017"   # Mongo NICHT exponiert
assert_fregex "$COMPOSE_PATH" '^    restart: unless-stopped$'
assert_fcontains "$COMPOSE_PATH" 'condition: service_healthy'
assert_fcontains "$COMPOSE_PATH" 'env_file:
      - path: .env'
# Mongo-Passwort: Compose-Interpolation aus .env (MUSS literal im File stehen)
# shellcheck disable=SC2016  # Absicht: Literal – ${MONGO_PASS} darf hier NICHT expandieren
assert_fcontains "$COMPOSE_PATH" 'MONGO_INITDB_ROOT_PASSWORD: ${MONGO_PASS}'
assert_fcontains "$COMPOSE_PATH" 'mongosh --quiet --eval'
assert_fcontains "$COMPOSE_PATH" "mongodata:/data/db"
assert_fcontains "$COMPOSE_PATH" "uploads:/usr/local/src/app/packages/back-end/uploads"

t ".env vollständig & Secrets-Format"
assert_file "$ENV_PATH"
assert_fregex "$ENV_PATH" '^MONGO_PASS=[0-9a-f]{32}$'
assert_fregex "$ENV_PATH" '^MONGODB_URI=mongodb://root:[0-9a-f]{32}@mongo:27017/growthbook\?authSource=admin$'
assert_fregex "$ENV_PATH" '^JWT_SECRET=[0-9a-f]{64}$'
assert_fregex "$ENV_PATH" '^ENCRYPTION_KEY=[0-9a-f]{64}$'
assert_fcontains "$ENV_PATH" "NODE_ENV=production"
assert_fcontains "$ENV_PATH" "UPLOAD_METHOD=local"
assert_fcontains "$ENV_PATH" "DISABLE_TELEMETRY=true"
assert_fregex "$ENV_PATH" '^APP_ORIGIN=http://'"$CT_IP"':3000$'
assert_fregex "$ENV_PATH" '^API_HOST=http://'"$CT_IP"':3100$'
env_mode=$(/bin/stat -c '%a' "$ENV_PATH" 2>/dev/null || echo "?")
if [[ "$env_mode" == "600" ]]; then pass ".env chmod 600"
else fail ".env chmod 600 (ist $env_mode)"; fi

t "systemd-Unit: Restart=always + Prod-Pfade"
assert_file "$UNIT_PATH"
assert_fcontains "$UNIT_PATH" "Restart=always"
assert_fcontains "$UNIT_PATH" "RestartSec=15"
assert_fcontains "$UNIT_PATH" "ExecStartPre=/opt/growthbook/sync-app-url.sh"
assert_fcontains "$UNIT_PATH" "ExecStart=/usr/bin/docker compose --project-directory /opt/growthbook up --pull=missing"
assert_fcontains "$UNIT_PATH" "After=network-online.target docker.service"
assert_fcontains "$UNIT_PATH" "Requires=docker.service"
assert_fcontains "$UNIT_PATH" "WantedBy=multi-user.target"

t "Sync-Script: IP-Sync (APP_ORIGIN + API_HOST) + Domain-Guard"
assert_file "$SYNC_PATH"
assert_fcontains "$SYNC_PATH" 'BASH_SOURCE[0]'
assert_fcontains "$SYNC_PATH" "eth0"
assert_fcontains "$SYNC_PATH" "https://*"   # https://-APP_ORIGIN wird nicht überschrieben
assert_fcontains "$SYNC_PATH" "set_key APP_ORIGIN"
assert_fcontains "$SYNC_PATH" "set_key API_HOST"

t "Install mit --port 4545 (Stream-Port bleibt 3100)"
reset_state
ec=$(run_installer --port 4545); assert_exit 0 "$ec"
assert_fcontains "$COMPOSE_PATH" '"4545:3000"'
assert_fregex "$ENV_PATH" '^APP_ORIGIN=http://'"$CT_IP"':4545$'
assert_fregex "$ENV_PATH" '^API_HOST=http://'"$CT_IP"':3100$'
assert_out "http://$CT_IP:4545"

t "Install mit --stream-port 3200"
reset_state
ec=$(run_installer --stream-port 3200); assert_exit 0 "$ec"
assert_fcontains "$COMPOSE_PATH" '"3200:3100"'
assert_fregex "$ENV_PATH" '^API_HOST=http://'"$CT_IP"':3200$'
assert_fregex "$ENV_PATH" '^APP_ORIGIN=http://'"$CT_IP"':3000$'

t "Install mit --version git-abcdef42 (Image-Pin)"
reset_state
ec=$(run_installer --version git-abcdef42); assert_exit 0 "$ec"
assert_fcontains "$COMPOSE_PATH" "image: growthbook/growthbook:git-abcdef42"
assert_out "Image-Pin: growthbook/growthbook:git-abcdef42"

t "Install mit statischer IP (--ip)"
reset_state
echo "192.168.178.77" > "$HS/ct_ip"   # mock-ip/sync liefert die statische IP
ec=$(run_installer --ip 192.168.178.77/24 --gateway 192.168.178.1); assert_exit 0 "$ec"
assert_fcontains "$HS/ct_200.create" "ip=192.168.178.77/24,gateway=192.168.178.1"
assert_out "http://192.168.178.77:3000"
assert_fregex "$ENV_PATH" '^APP_ORIGIN=http://192.168.178.77:3000$'
assert_fregex "$ENV_PATH" '^API_HOST=http://192.168.178.77:3100$'

t "Install: Web-UI antwortet mit 302 (Redirect auf Signup) – auch ok"
reset_state
touch "$HS/web_302"
ec=$(run_installer); assert_exit 0 "$ec"
assert_out "Web-UI antwortet (HTTP 302 auf Port 3000)"

t "Install: API/Streaming-Port tot → Warnung, Installation trotzdem grün"
reset_state
touch "$HS/stream_fail"
ec=$(run_installer); assert_exit 0 "$ec"
assert_out "API/Streaming-Port 3100 antwortet nicht"
assert_out "SDK-Connections via Streaming sind dann nicht nutzbar"

t "Install: growthbook-Service fehlt im Stack → die() mit Debug-Kette"
reset_state
touch "$HS/gb_down"
ec=$(run_installer); assert_exit 1 "$ec"
assert_out "Compose-Services fehlen oder sind nicht hochgekommen: growthbook"
assert_out "--project-directory /opt/growthbook ps -a"

t "Install: Web-UI tot (Inner-Die) → komplette Fehlerkette"
reset_state
touch "$HS/fail_web"
ec=$(run_installer); assert_exit 1 "$ec"
assert_out "Web-UI antwortet nicht"
assert_out "docker compose logs --tail 50 growthbook"

t "Install: CT existiert bereits → die() mit Update-Hinweis"
reset_state
echo "200 running growthbook" > "$HS/ct_list"
ec=$(run_installer); assert_exit 1 "$ec"
assert_out "existiert bereits"
assert_out "--update"

t "Install --force: bestehender CT wird gelöscht und neu angelegt"
reset_state
echo "200 running growthbook" > "$HS/ct_list"
echo "running" > "$HS/ct_200.status"
echo "growthbook" > "$HS/ct_200.hostname"
seed_inner_tools
touch "$HS/template_downloaded"
touch "$HS/templates/debian-13-standard_13.2-1_amd64.tar.zst"
ec=$(run_installer --force); assert_exit 0 "$ec"
assert_calls 1 "pct destroy 200 --purge"
assert_out "neu an"
assert_fcontains "$HS/ct_200.create" "hostname growthbook"

t "Install: pct create schlägt fehl → komplette Fehlerkette + --debug-Hinweis"
reset_state
touch "$HS/create_fail"
ec=$(run_installer); assert_exit 255 "$ec"
assert_out "Installationsfehler – Exit-Code 255"
assert_out "Fehlgeschlagener Befehl"
assert_out "--debug"
assert_out "Neu ausführen mit vollem bash -x-Trace"

t "Install: DNS tot ohne Fallback-Erfolg → die() mit Diagnose"
reset_state
# getent_mode=fail lässt ALLE getent-Calls fehlschlagen → Fallback → Post-Check fail
# (WICHTIG: Mock parst "getent_mode=<wert>" – das Key-Präfix ist Pflicht!)
echo "getent_mode=fail" > "$HS/getent_mode"
ec=$(run_installer); assert_exit 1 "$ec"
assert_out "DNS im Container weiterhin ohne Funktion"
assert_out "Port 53"

# ════════════════ C. Update ════════════════
t "--update: Secrets + URI bleiben erhalten, Images werden neu gezogen"
seed_ct
ec=$(run_installer --update); assert_exit 0 "$ec"
assert_docker 1 "pull"
assert_fcontains "$ENV_PATH" "MONGO_PASS=aaaabbbbccccdddd1111222233334444"
assert_fcontains "$ENV_PATH" "MONGODB_URI=mongodb://root:aaaabbbbccccdddd1111222233334444@mongo:27017/growthbook?authSource=admin"
assert_fcontains "$ENV_PATH" "JWT_SECRET=1111222233334444555566667777888899990000aaaabbbbccccddddeeeeffff"
assert_fcontains "$ENV_PATH" "ENCRYPTION_KEY=aaaabbbbccccddddeeeeffff0000111122223333444455556666777788889999"
assert_fcontains "$ENV_PATH" "DISABLE_TELEMETRY=true"
assert_fregex "$ENV_PATH" '^APP_ORIGIN=http://'"$CT_IP"':3000$'
assert_fregex "$ENV_PATH" '^API_HOST=http://'"$CT_IP"':3100$'
assert_out "Update abgeschlossen – Daten (Mongo-/Upload-Volumes) blieben erhalten."

t "--update auf gestopptem CT → startet ihn selbst (Grube 10)"
seed_ct
echo "stopped" > "$HS/ct_200.status"
/bin/sed -i 's/^200 running/200 stopped/' "$HS/ct_list"
ec=$(run_installer --update); assert_exit 0 "$ec"
assert_calls 1 "pct start 200"
assert_out "läuft nicht (Status: stopped) – starte ihn"

t "--update --version git-999 → Compose mit neuem Pin"
seed_ct
ec=$(run_installer --update --version git-999999); assert_exit 0 "$ec"
assert_fcontains "$COMPOSE_PATH" "image: growthbook/growthbook:git-999999"
assert_out "Image-Pin: growthbook/growthbook:git-999999"

t "--update: Nutzer-Edit an DISABLE_TELEMETRY bleibt erhalten"
seed_ct
/bin/sed -i 's/^DISABLE_TELEMETRY=.*/DISABLE_TELEMETRY=false/' "$ENV_PATH"
ec=$(run_installer --update); assert_exit 0 "$ec"
assert_fcontains "$ENV_PATH" "DISABLE_TELEMETRY=false"

t "--update: Domain-Modus (APP_ORIGIN=https://) wird NICHT überschrieben"
seed_ct
/bin/sed -i 's|^APP_ORIGIN=.*|APP_ORIGIN=https://gb.example.com|' "$ENV_PATH"
/bin/sed -i 's|^API_HOST=.*|API_HOST=https://gb.example.com:3100|' "$ENV_PATH"
ec=$(run_installer --update); assert_exit 0 "$ec"
assert_fregex "$ENV_PATH" '^APP_ORIGIN=https://gb\.example\.com$'
assert_out "Domain-Modus"

t "--update ohne CT → die() mit Install-Hinweis"
reset_state
ec=$(run_installer --update); assert_exit 1 "$ec"
assert_out "Kein Container mit Hostname 'growthbook' gefunden"
assert_out "Erst installieren"

# ════════════════ D. Uninstall ════════════════
t "--uninstall --yes: CT stoppen + löschen"
seed_ct
ec=$(run_installer --uninstall --yes); assert_exit 0 "$ec"
assert_calls 1 "pct stop 200"
assert_calls 1 "pct destroy 200 --purge"
assert_no_out "200 running growthbook"
if /bin/grep -q "200" "$HS/ct_list" 2>/dev/null; then fail "CT noch in ct_list"
else pass "CT aus ct_list entfernt"; fi

t "--uninstall ohne CT → nichts zu tun (exit 0)"
reset_state
ec=$(run_installer --uninstall --yes); assert_exit 0 "$ec"
assert_out "nichts zu tun"

t "--uninstall ohne --yes, stdin 'nein' → Abbruch, CT bleibt"
seed_ct
ec=$(run_installer_stdin "nein" --uninstall); assert_exit 0 "$ec"
assert_out "Abgebrochen – nichts gelöscht"
assert_calls 0 "pct destroy 200"

t "--uninstall ohne --yes, kein stdin → die() mit --yes-Hinweis"
seed_ct
ec=$(run_installer_devnull --uninstall); assert_exit 1 "$ec"
assert_out "Keine Bestätigung erhalten"
assert_out "--uninstall --yes"

# ════════════════ E. Status ════════════════
t "--status (laufend): Service, Stack, APP_ORIGIN, Pin, Web-UI 200"
seed_ct
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_out "Container:  200 (running) – growthbook"
assert_out "Service:   growthbook läuft (systemctl is-active)"
assert_out "Stack:     mongo running growthbook running"
assert_out "APP_ORIGIN: http://10.120.5.42:3000"
assert_out "API_HOST:   http://10.120.5.42:3100"
assert_out "Image:      growthbook/growthbook:git-6c38e93"
assert_out "Telemetrie: AUS (DISABLE_TELEMETRY=true)"
assert_out "Web-UI:    http://10.120.5.42:3000  (HTTP 200)"

t "--status: Telemetrie vom Nutzer aktiviert → Warnung"
seed_ct
/bin/sed -i 's/^DISABLE_TELEMETRY=.*/DISABLE_TELEMETRY=false/' "$ENV_PATH"
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_out "Telemetrie: AKTIV"

t "--status: Host_curl_fail → Warnung mit HTTP 000"
seed_ct
touch "$HS/host_curl_fail"
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_out "HTTP-Code 000 von http://10.120.5.42:3000"

t "--status: gestoppter CT → Start-Hinweis, keine falschen Fehler"
seed_ct
echo "stopped" > "$HS/ct_200.status"
/bin/sed -i 's/^200 running/200 stopped/' "$HS/ct_list"
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_out "nicht gestartet (stopped)"
assert_out "Starten:    pct start 200"

t "--status ohne CT → Hinweis + Install-Befehl (exit 0)"
reset_state
ec=$(run_installer --status); assert_exit 0 "$ec"
assert_out "Kein Container mit Hostname 'growthbook' gefunden"

# ════════════════ Zusammenfassung ════════════════
echo "════════════════════════════════════════════════════════════"
echo " Ergebnis: $PASSED bestanden, $FAILED fehlgeschlagen"
echo "════════════════════════════════════════════════════════════"
if [[ "$FAILED" -gt 0 ]]; then
    KEEP=1   # Trap überlebt lassen – Artefakte für Fehlersuche
    echo "(Behalten für Fehlersuche: $MK)"
    exit 1
fi
exit 0

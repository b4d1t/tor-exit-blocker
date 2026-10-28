#!/bin/bash
# bloquear_tor.sh — Bloquea nodos de salida Tor (IPv4 + IPv6) con ipset + iptables.
# Autor: b4d1t
#
# Uso:  bloquear_tor.sh [update|status|remove]   (por defecto: update)
#
# Configuración opcional en /etc/default/bloquear_tor (ver bloquear_tor.conf.example).
#
# Garantías:
#   - Nunca deja los sets vacíos: descarga primero, valida y solo entonces
#     sustituye la lista de forma atómica (ipset swap).
#   - Si la descarga falla o viene corta, usa la última lista buena guardada
#     en disco; si tampoco hay, mantiene la que ya está cargada.
#   - Las reglas se revisan en cada ejecución y se recolocan arriba si alguien
#     (Docker, Tailscale...) las ha movido o borrado.
#   - Solo una ejecución a la vez (flock).

set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 077

# ------------------------------
# CONFIGURACIÓN (valores por defecto)
# ------------------------------
IPSET_V4="tor_exit_nodes"
IPSET_V6="tor_exit_nodes_v6"

# Cadenas donde se bloquea el tráfico ENTRANTE (las que no existan se saltan).
CHAINS_V4="INPUT DOCKER-USER ts-input"
CHAINS_V6="INPUT DOCKER-USER ts-input"

# Bloquear también conexiones SALIENTES hacia nodos Tor (cadena OUTPUT).
BLOCK_OUTPUT="yes"

# Fuentes. exit-addresses solo trae IPv4; las IPv6 salen de Onionoo (requiere jq).
URL_EXIT_ADDRESSES="https://check.torproject.org/exit-addresses"
URL_ONIONOO="https://onionoo.torproject.org/details?flag=Exit&running=true&fields=or_addresses,exit_addresses,exit_policy_v6_summary"

# Mínimo de IPs para aceptar una lista como válida (protege contra descargas cortadas).
MIN_V4=500
MIN_V6=50

# IPs que nunca se bloquean (separadas por espacios), por si acaso.
ALLOWLIST=""

LOG_RATE="5/min"
LOG_BURST=5
LOGFILE="/var/log/bloquear_tor.log"   # vacío = solo journal/stdout
STATE_DIR="/var/lib/bloquear_tor"
LOCKFILE="/run/lock/bloquear_tor.lock"

# Correo con msmtp (opcional). MAIL_ON: error | always | never
MAIL_TO=""
MAIL_FROM=""
MSMTP_CFG=""
MAIL_ON="error"

CONFIG_FILE="${BLOQUEAR_TOR_CONFIG:-/etc/default/bloquear_tor}"
# shellcheck source=/dev/null
[[ -r "$CONFIG_FILE" ]] && . "$CONFIG_FILE"

IPT=(iptables -w 10)
IP6T=(ip6tables -w 10)
TMPDIR_RUN=""
WARNINGS=()

# ------------------------------
# UTILIDADES
# ------------------------------
log() {
    local level="$1"; shift
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"
    echo "$line" >&2
    if [[ -n "$LOGFILE" ]]; then echo "$line" >> "$LOGFILE" 2>/dev/null || true; fi
    logger -t bloquear_tor -p "user.$( [[ $level == ERROR ]] && echo err || echo info )" -- "$*" 2>/dev/null || true
}
warn() { WARNINGS+=("$*"); log WARN "$*"; }
die()  { log ERROR "$*"; send_mail "ERROR" "$*"; exit 1; }

send_mail() {
    local status="$1" body="$2"
    [[ -n "$MAIL_TO" ]] || return 0
    case "$MAIL_ON" in
        never) return 0 ;;
        error) [[ "$status" == "ERROR" || "$status" == "WARN" ]] || return 0 ;;
    esac
    command -v msmtp >/dev/null || { log WARN "MAIL_TO definido pero msmtp no está instalado"; return 0; }
    local args=(-t); [[ -n "$MSMTP_CFG" ]] && args=(--file="$MSMTP_CFG" -t)
    {
        echo "From: ${MAIL_FROM:-$MAIL_TO}"
        echo "To: $MAIL_TO"
        echo "Subject: [bloquear_tor][$status] $(hostname) - $(date '+%d/%m %H:%M')"
        echo "Content-Type: text/plain; charset=UTF-8"
        echo
        echo "$body"
    } | msmtp "${args[@]}" || log WARN "No se pudo enviar el correo"
}

cleanup() { [[ -n "$TMPDIR_RUN" ]] && rm -rf "$TMPDIR_RUN"; return 0; }
on_error() { die "Fallo inesperado en la línea $1 (código $2)"; }

require_root() { [[ $EUID -eq 0 ]] || { echo "Este script necesita root." >&2; exit 1; }; }

require_bins() {
    local b missing=()
    for b in ipset iptables ip6tables curl awk flock; do
        command -v "$b" >/dev/null || missing+=("$b")
    done
    (( ${#missing[@]} == 0 )) || { echo "Faltan comandos: ${missing[*]}" >&2; exit 1; }
}

set_count() { ipset list -t "$1" 2>/dev/null | awk -F': ' '/^Number of entries/ {print $2}'; }

# Filtra y valida IPs (una por línea); separa en v4/v6 y aplica la allowlist.
split_and_validate() {
    local in="$1" out4="$2" out6="$3" allow="$TMPDIR_RUN/allow"
    tr ' ' '\n' <<<"$ALLOWLIST" | sed '/^$/d' > "$allow"
    awk '/^([0-9]{1,3}\.){3}[0-9]{1,3}$/' "$in" | sort -u | grep -vxFf "$allow" > "$out4" || true
    awk '/:/ && /^[0-9A-Fa-f:.]+$/' "$in" | tr 'A-F' 'a-f' | sort -u | grep -vxFf "$allow" > "$out6" || true
}

# ------------------------------
# DESCARGA
# ------------------------------
fetch() { curl -fsS --max-time 60 --retry 3 --retry-delay 5 --retry-connrefused -o "$2" "$1"; }

download_lists() {
    local raw="$TMPDIR_RUN/raw" raw6="$TMPDIR_RUN/raw6"
    : > "$raw"; : > "$raw6"
    ONIONOO_OK=0

    if fetch "$URL_EXIT_ADDRESSES" "$TMPDIR_RUN/exit-addresses"; then
        awk '/^ExitAddress/ {print $2}' "$TMPDIR_RUN/exit-addresses" >> "$raw"
    else
        warn "No se pudo descargar $URL_EXIT_ADDRESSES"
    fi

    if command -v jq >/dev/null; then
        if fetch "$URL_ONIONOO" "$TMPDIR_RUN/onionoo.json" &&
           jq -r '.relays[] |
                    (.exit_addresses // [])[],
                    ((.or_addresses // [])[] | select(startswith("[") | not) | sub(":[0-9]+$"; ""))' \
                 "$TMPDIR_RUN/onionoo.json" >> "$raw" &&
           jq -r '.relays[]
                    | select(.exit_policy_v6_summary != null
                             and .exit_policy_v6_summary != {"reject":["1-65535"]})
                    | (.or_addresses // [])[] | select(startswith("["))
                    | ltrimstr("[") | sub("\\]:[0-9]+$"; "")' \
                 "$TMPDIR_RUN/onionoo.json" >> "$raw6"; then
            ONIONOO_OK=1
        else
            warn "No se pudo descargar o leer Onionoo; IPv6 se mantiene con la lista anterior"
        fi
    else
        warn "jq no está instalado: sin Onionoo no hay lista IPv6 (apt install jq)"
    fi

    cat "$raw6" >> "$raw"
    split_and_validate "$raw" "$TMPDIR_RUN/v4.txt" "$TMPDIR_RUN/v6.txt"
}

# Elige la lista a cargar: la nueva si es válida, si no la guardada, si no ninguna.
# Deja la ruta elegida (o vacío) en CHOSEN.
choose_list() {
    local name="$1" fresh="$2" min="$3" valid="$4"
    local cache="$STATE_DIR/$name.txt" n
    CHOSEN=""
    n=$(wc -l < "$fresh")
    if [[ "$valid" == 1 ]] && (( n >= min )); then
        CHOSEN="$fresh"; return 0
    fi
    if [[ "$valid" == 1 ]]; then warn "Lista $name demasiado corta ($n < $min), se descarta"; fi
    if [[ -s "$cache" ]]; then
        warn "Usando la última lista $name guardada ($(wc -l < "$cache") IPs, del $(date -r "$cache" '+%Y-%m-%d %H:%M'))"
        CHOSEN="$cache"
    fi
    return 0
}

# ------------------------------
# IPSET (carga atómica)
# ------------------------------
load_set() {
    local set="$1" family="$2" file="$3" tmp="${1}_tmp"
    ensure_set_exists "$set" "$family"
    ipset destroy "$tmp" 2>/dev/null || true      # restos de una ejecución interrumpida
    {
        echo "create $tmp hash:ip family $family hashsize 4096 maxelem 65536"
        sed "s/^/add $tmp /" "$file"
    } > "$TMPDIR_RUN/$set.restore"

    ipset restore -exist -file "$TMPDIR_RUN/$set.restore"
    ipset swap "$tmp" "$set"
    ipset destroy "$tmp"
    log INFO "Set $set cargado: $(set_count "$set") IPs"
}

ensure_set_exists() {
    ipset list -n "$1" >/dev/null 2>&1 || ipset create "$1" hash:ip family "$2" hashsize 4096 maxelem 65536
}

# ------------------------------
# REGLAS
# ------------------------------
chain_exists() { local -n ce=$1; "${ce[@]}" -S "$2" >/dev/null 2>&1; }   # uso: chain_exists IPT CADENA

# Borra todas nuestras reglas (cualquier variante) de una cadena, por número de línea.
purge_rules() {
    local -n cmd=$1; local chain="$2" set="$3" nums n
    chain_exists "$1" "$chain" || return 0
    nums=$("${cmd[@]}" -L "$chain" -n --line-numbers 2>/dev/null \
           | awk -v s="match-set $set " 'index($0, s) {print $1}' | sort -rn)
    for n in $nums; do "${cmd[@]}" -D "$chain" "$n"; done
}

# Deja LOG (limitado) + DROP como las dos primeras reglas de la cadena.
ensure_rules() {
    local -n c=$1; local chain="$2" set="$3" dir="$4" prefix="$5"
    if ! chain_exists "$1" "$chain"; then
        log INFO "Cadena $chain no existe en ${c[0]}, se salta"
        return 0
    fi

    local log_rule=(-m set --match-set "$set" "$dir" -m limit --limit "$LOG_RATE" --limit-burst "$LOG_BURST"
                    -j LOG --log-prefix "$prefix " --log-level 4)
    local drop_rule=(-m set --match-set "$set" "$dir" -j DROP)

    # ¿Están ya bien colocadas? (reglas 1 y 2, y no hay duplicados)
    local rules ours first second
    rules=$("${c[@]}" -S "$chain" | tail -n +2)
    ours=$(grep -cF -- "--match-set $set $dir" <<<"$rules" || true)
    first=$(sed -n 1p <<<"$rules"); second=$(sed -n 2p <<<"$rules")
    if [[ "$ours" == 2 && "$first" == *"--match-set $set $dir"*"-j LOG"*"$prefix"* \
          && "$first" == *"--limit $LOG_RATE"* && "$second" == *"--match-set $set $dir -j DROP"* ]]; then
        return 0
    fi

    purge_rules "$1" "$chain" "$set"
    "${c[@]}" -I "$chain" 1 "${drop_rule[@]}"
    "${c[@]}" -I "$chain" 1 "${log_rule[@]}"
    log INFO "Reglas (re)colocadas en ${c[0]} $chain ($dir)"
}

apply_rules() {
    local ch
    # INPUT siempre existe: si no se puede leer, iptables no funciona (no confundir con "cadena ausente").
    chain_exists IPT INPUT || die "iptables no responde ($(iptables -w 10 -S INPUT 2>&1 | head -1 || true))"
    if ! chain_exists IP6T INPUT; then
        warn "ip6tables no responde: se omiten las reglas IPv6"
        CHAINS_V6=""
    fi
    for ch in $CHAINS_V4; do ensure_rules IPT  "$ch" "$IPSET_V4" src "[TOR BLOCKED V4]"; done
    for ch in $CHAINS_V6; do ensure_rules IP6T "$ch" "$IPSET_V6" src "[TOR BLOCKED V6]"; done
    if [[ "$BLOCK_OUTPUT" == "yes" ]]; then
        ensure_rules IPT  OUTPUT "$IPSET_V4" dst "[TOR BLOCKED OUT V4]"
        [[ -z "$CHAINS_V6" ]] || ensure_rules IP6T OUTPUT "$IPSET_V6" dst "[TOR BLOCKED OUT V6]"
    else
        purge_rules IPT  OUTPUT "$IPSET_V4"
        purge_rules IP6T OUTPUT "$IPSET_V6"
    fi
    return 0
}

# ------------------------------
# MODOS
# ------------------------------
cmd_update() {
    log INFO "Iniciando actualización de nodos Tor"
    TMPDIR_RUN=$(mktemp -d)
    mkdir -p "$STATE_DIR"

    download_lists

    local f4 f6
    choose_list v4 "$TMPDIR_RUN/v4.txt" "$MIN_V4" 1;             f4="$CHOSEN"
    choose_list v6 "$TMPDIR_RUN/v6.txt" "$MIN_V6" "$ONIONOO_OK"; f6="$CHOSEN"

    if [[ -n "$f4" ]]; then
        load_set "$IPSET_V4" inet "$f4"
        if [[ "$f4" == "$TMPDIR_RUN/v4.txt" ]]; then cp "$f4" "$STATE_DIR/v4.txt"; fi
    else
        ensure_set_exists "$IPSET_V4" inet
        warn "Sin lista IPv4 válida ni guardada: se mantiene el set actual ($(set_count "$IPSET_V4") IPs)"
    fi

    if [[ -n "$f6" ]]; then
        load_set "$IPSET_V6" inet6 "$f6"
        if [[ "$f6" == "$TMPDIR_RUN/v6.txt" ]]; then cp "$f6" "$STATE_DIR/v6.txt"; fi
    else
        ensure_set_exists "$IPSET_V6" inet6
        warn "Sin lista IPv6 válida ni guardada: se mantiene el set actual ($(set_count "$IPSET_V6") IPs)"
    fi

    apply_rules

    local v4 v6 summary
    v4=$(set_count "$IPSET_V4"); v6=$(set_count "$IPSET_V6")
    summary="IPv4: $v4 | IPv6: $v6"
    (( v4 > 0 )) || die "El set IPv4 está vacío: no hay bloqueo activo. $summary"

    if (( ${#WARNINGS[@]} )); then
        log WARN "Terminado con avisos. $summary"
        send_mail "WARN" "$summary"$'\n\nAvisos:\n'"$(printf -- '- %s\n' "${WARNINGS[@]}")"
    else
        log OK "Terminado. $summary"
        send_mail "OK" "Lista de nodos Tor actualizada. $summary"
    fi
}

cmd_status() {
    local s n
    for s in "$IPSET_V4" "$IPSET_V6"; do
        n=$(set_count "$s")
        if [[ -n "$n" ]]; then printf '%-22s %s IPs\n' "$s" "$n"; else printf '%-22s no existe\n' "$s"; fi
    done
    for s in v4 v6; do
        if [[ -f "$STATE_DIR/$s.txt" ]]; then echo "Lista guardada $s: $(date -r "$STATE_DIR/$s.txt" '+%Y-%m-%d %H:%M')"; fi
    done
    echo
    local ch
    for ch in $CHAINS_V4 OUTPUT; do
        chain_exists IPT "$ch" || continue
        echo "iptables $ch:";  "${IPT[@]}" -S "$ch" | grep -F -- "--match-set $IPSET_V4 " | sed 's/^/  /' || echo "  (sin reglas)"
    done
    for ch in $CHAINS_V6 OUTPUT; do
        chain_exists IP6T "$ch" || continue
        echo "ip6tables $ch:"; "${IP6T[@]}" -S "$ch" | grep -F -- "--match-set $IPSET_V6 " | sed 's/^/  /' || echo "  (sin reglas)"
    done
}

cmd_remove() {
    local ch
    for ch in $CHAINS_V4 OUTPUT; do purge_rules IPT  "$ch" "$IPSET_V4"; done
    for ch in $CHAINS_V6 OUTPUT; do purge_rules IP6T "$ch" "$IPSET_V6"; done
    ipset destroy "$IPSET_V4" 2>/dev/null || warn "No se pudo borrar $IPSET_V4 (¿lo usa otra regla?)"
    ipset destroy "$IPSET_V6" 2>/dev/null || warn "No se pudo borrar $IPSET_V6 (¿lo usa otra regla?)"
    log INFO "Reglas y sets eliminados (la caché en $STATE_DIR se conserva)"
}

# ------------------------------
# MAIN
# ------------------------------
main() {
    require_root
    require_bins
    trap cleanup EXIT
    trap 'on_error $LINENO $?' ERR

    exec 9>"$LOCKFILE"
    flock -n 9 || { log WARN "Ya hay otra ejecución en curso, salgo"; exit 0; }

    case "${1:-update}" in
        update) cmd_update ;;
        status) cmd_status ;;
        remove) cmd_remove ;;
        -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//' ;;
        *) echo "Uso: $0 [update|status|remove]" >&2; exit 2 ;;
    esac
}

main "$@"

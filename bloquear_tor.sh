#!/bin/bash
# /usr/local/bin/bloquear_tor.sh
# Actualiza ipsets Tor (IPv4 + IPv6) y aplica reglas LOG (rate-limited) + DROP
# Autor: b4d1t
#
# NOTA: la sección de envío de correo ha sido comentada por seguridad/configuración.
#       Si quieres reactivarla, descomenta las líneas pertinentes y configura msmtp.

set -euo pipefail

# ------------------------------
# CONFIG
# ------------------------------
IPSET_V4="tor_exit_nodes"
IPSET_V6="tor_exit_nodes_v6"
TOR_URL="https://check.torproject.org/exit-addresses"
TMP=$(mktemp)
LOGFILE="/var/log/bloquear_tor.log"

# -- Se comentan las variables relacionadas con el correo --
# DEST_EMAIL="email@server.com"
# MAIL_USER="Name <email@server.com>"
# MSMTP_CFG="/home/your_user/.msmtprc"

# ------------------------------
# LOGGING
# ------------------------------
exec >> "$LOGFILE" 2>&1
echo -e "\n=== $(date '+%Y-%m-%d %H:%M:%S') ==="
echo "[INFO] Iniciando actualización de nodos Tor..."

# ------------------------------
# RUTAS ABSOLUTAS
# ------------------------------
IPSET=/usr/sbin/ipset
IPTABLES=/usr/sbin/iptables
IP6TABLES=/usr/sbin/ip6tables
CURL=/usr/bin/curl
AWK=/usr/bin/awk
SORT=/usr/bin/sort
# MSMTP=/usr/bin/msmtp   # comentado porque no se usa al desactivar el envío de correo
GREP=/usr/bin/grep
RM=/usr/bin/rm

# ------------------------------
# CREAR IPSETS
# ------------------------------
$IPSET list "$IPSET_V4" >/dev/null 2>&1 || $IPSET create "$IPSET_V4" hash:ip hashsize 4096 maxelem 65536
$IPSET list "$IPSET_V6" >/dev/null 2>&1 || $IPSET create "$IPSET_V6" hash:ip family inet6 hashsize 4096 maxelem 65536

# ------------------------------
# LIMPIAR
# ------------------------------
$IPSET flush "$IPSET_V4"
$IPSET flush "$IPSET_V6"

# ------------------------------
# DESCARGAR Y CARGAR NUEVOS NODOS
# ------------------------------
$CURL -s "$TOR_URL" > "$TMP"
$AWK '/^ExitAddress/ {print $2}' "$TMP" | $SORT -u | while read -r ip; do
    if [[ "$ip" == *:* ]]; then
        $IPSET add "$IPSET_V6" "$ip" -exist
    else
        $IPSET add "$IPSET_V4" "$ip" -exist
    fi
done

# ------------------------------
# ELIMINAR REGLAS ANTIGUAS
# ------------------------------
for chain in INPUT DOCKER-USER ts-input; do
  $IPTABLES -D "$chain" -m set --match-set "$IPSET_V4" src -j LOG --log-prefix "[TOR BLOCKED V4] " --log-level 4 2>/dev/null || true
  $IPTABLES -D "$chain" -m set --match-set "$IPSET_V4" src -j DROP 2>/dev/null || true
done

$IP6TABLES -D INPUT -m set --match-set "$IPSET_V6" src -j LOG --log-prefix "[TOR BLOCKED V6] " --log-level 4 2>/dev/null || true
$IP6TABLES -D INPUT -m set --match-set "$IPSET_V6" src -j DROP 2>/dev/null || true

# ------------------------------
# AÑADIR NUEVAS REGLAS (IPv4)
# ------------------------------
for chain in INPUT DOCKER-USER ts-input; do
  $IPTABLES -C "$chain" -m set --match-set "$IPSET_V4" src -m limit --limit 5/min --limit-burst 5 -j LOG --log-prefix "[TOR BLOCKED V4] " --log-level 4 2>/dev/null || \
  $IPTABLES -I "$chain" 1 -m set --match-set "$IPSET_V4" src -m limit --limit 5/min --limit-burst 5 -j LOG --log-prefix "[TOR BLOCKED V4] " --log-level 4

  $IPTABLES -C "$chain" -m set --match-set "$IPSET_V4" src -j DROP 2>/dev/null || \
  $IPTABLES -I "$chain" 2 -m set --match-set "$IPSET_V4" src -j DROP
done

# ------------------------------
# AÑADIR NUEVAS REGLAS (IPv6)
# ------------------------------
$IP6TABLES -C INPUT -m set --match-set "$IPSET_V6" src -m limit --limit 5/min --limit-burst 5 -j LOG --log-prefix "[TOR BLOCKED V6] " --log-level 4 2>/dev/null || \
$IP6TABLES -I INPUT 1 -m set --match-set "$IPSET_V6" src -m limit --limit 5/min --limit-burst 5 -j LOG --log-prefix "[TOR BLOCKED V6] " --log-level 4
$IP6TABLES -C INPUT -m set --match-set "$IPSET_V6" src -j DROP 2>/dev/null || \
$IP6TABLES -I INPUT 2 -m set --match-set "$IPSET_V6" src -j DROP

# ------------------------------
# BLOQUEO DE SALIDA
# ------------------------------
$IPTABLES -C OUTPUT -m set --match-set "$IPSET_V4" dst -m limit --limit 5/min --limit-burst 5 -j LOG --log-prefix "[TOR BLOCKED OUT V4] " --log-level 4 2>/dev/null || \
$IPTABLES -I OUTPUT 1 -m set --match-set "$IPSET_V4" dst -m limit --limit 5/min --limit-burst 5 -j LOG --log-prefix "[TOR BLOCKED OUT V4] " --log-level 4
$IPTABLES -C OUTPUT -m set --match-set "$IPSET_V4" dst -j DROP 2>/dev/null || $IPTABLES -I OUTPUT 2 -m set --match-set "$IPSET_V4" dst -j DROP

$IP6TABLES -C OUTPUT -m set --match-set "$IPSET_V6" dst -m limit --limit 5/min --limit-burst 5 -j LOG --log-prefix "[TOR BLOCKED OUT V6] " --log-level 4 2>/dev/null || \
$IP6TABLES -I OUTPUT 1 -m set --match-set "$IPSET_V6" dst -m limit --limit 5/min --limit-burst 5 -j LOG --log-prefix "[TOR BLOCKED OUT V6] " --log-level 4
$IP6TABLES -C OUTPUT -m set --match-set "$IPSET_V6" dst -j DROP 2>/dev/null || $IP6TABLES -I OUTPUT 2 -m set --match-set "$IPSET_V6" dst -j DROP

# ------------------------------
# RESUMEN
# ------------------------------
V4_COUNT=$($IPSET list "$IPSET_V4" | $GREP -c '^[0-9]')
V6_COUNT=$($IPSET list "$IPSET_V6" | $GREP -c ':')

echo "[OK] Tor exit nodes IPv4: $V4_COUNT"
echo "[OK] Tor exit nodes IPv6: $V6_COUNT"

# ------------------------------
# EMAIL DE AVISO (DESACTIVADO)
# ------------------------------
# Si quieres reactivar el email:
# 1) Descomenta las variables al inicio (DEST_EMAIL, MAIL_USER, MSMTP_CFG).
# 2) Descomenta la línea de MSMTP en RUTAS ABSOLUTAS y la sección siguiente.
# 3) Asegúrate de que msmtp esté instalado y ~/.msmtprc configurado con permisos 600.
#
# {
#     echo "From: $MAIL_USER"
#     echo "To: $DEST_EMAIL"
#     echo "Subject: [INFO] Lista de nodos Tor actualizada - $(date '+%d/%m %H:%M')"
#     echo "Content-Type: text/plain; charset=UTF-8"
#     echo ""
#     echo "Actualización completada."
#     echo "[+] IPv4: $V4_COUNT"
#     echo "[+] IPv6: $V6_COUNT"
# } | $MSMTP --file="$MSMTP_CFG" -t

# ------------------------------
# LIMPIEZA
# ------------------------------
$RM -f "$TMP"

echo "[FIN] Script completado correctamente."
exit 0


#!/bin/sh
# TUI screen: Network interface configuration

LIBDIR="/usr/local/lib/pcd-proxy"
. "$LIBDIR/common.sh"
load_state

clear
header "Network Configuration"
echo

# Enumerate physical NICs (exclude loopback and virtual bridge interfaces)
NICS=$(ip link show | awk -F': ' '/^[0-9]+:/ && !/lo:/{gsub(/@.*/,"",$2); print $2}' \
    | grep -v '^docker\|^br-\|^virbr\|^veth')

if [ -z "$NICS" ]; then
    gum style --foreground 196 "No network interfaces detected."
    sleep 2
    return
fi

NIC_COUNT=$(echo "$NICS" | wc -l)
gum style --faint "Detected ${NIC_COUNT} interface(s). Configure each interface below."
echo

IDX=0
NEW_IFACES=""

for NIC in $NICS; do
    PREFIX="ETH${IDX}"
    KEY_IP="${PREFIX}_IP"
    KEY_PFX="${PREFIX}_PREFIX"
    KEY_GW="${PREFIX}_GW"
    KEY_MODE="${PREFIX}_MODE"

    # Current runtime IP (picks up Nova-injected static IPs)
    RUNTIME_IP=$(ip -f inet addr show "$NIC" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
    RUNTIME_PFX=$(ip -f inet addr show "$NIC" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f2)
    RUNTIME_GW=$(ip route show dev "$NIC" 2>/dev/null | awk '/^default/{print $3}' | head -1)

    # Load state values, fall back to runtime values if state is empty
    eval "CUR_IP=\${${KEY_IP}:-}"
    eval "CUR_PFX=\${${KEY_PFX}:-}"
    eval "CUR_GW=\${${KEY_GW}:-}"
    eval "CUR_MODE=\${${KEY_MODE}:-}"

    [ -z "$CUR_IP"  ] && CUR_IP="$RUNTIME_IP"
    [ -z "$CUR_PFX" ] && CUR_PFX="${RUNTIME_PFX:-24}"
    [ -z "$CUR_GW"  ] && CUR_GW="$RUNTIME_GW"

    gum style --bold "Interface ${IDX}: ${NIC}${RUNTIME_IP:+  (current: ${RUNTIME_IP})}"

    MODE=$(gum choose \
        "${CUR_MODE:-DHCP}" \
        "$([ "${CUR_MODE:-}" = "Static" ] && echo DHCP || echo Static)")
    [ $? -eq 0 ] || return
    # gum choose returns the selected item; normalize
    case "$MODE" in
        *DHCP*|*dhcp*) MODE="dhcp" ;;
        *)             MODE="static" ;;
    esac

    if [ "$MODE" = "static" ]; then
        IP=$(gum input \
            --placeholder "e.g. 10.0.0.254" \
            --value "${CUR_IP:-}" \
            --prompt "  IP address: ")
        [ $? -eq 0 ] || return
        [ -z "$IP" ] && { IDX=$((IDX+1)); continue; }

        PFX=$(gum input \
            --placeholder "e.g. 24" \
            --value "${CUR_PFX:-24}" \
            --prompt "  Prefix length: ")
        [ $? -eq 0 ] || return

        # Only prompt for gateway on first (default-route) interface
        if [ "$IDX" -eq 0 ]; then
            GW=$(gum input \
                --placeholder "e.g. 10.0.0.1" \
                --value "${CUR_GW:-}" \
                --prompt "  Default gateway: ")
            [ $? -eq 0 ] || return
        else
            GW=""
        fi

        NEW_IFACES="${NEW_IFACES}
auto ${NIC}
iface ${NIC} inet static
    address ${IP}/${PFX}$([ -n "$GW" ] && printf '\n    gateway %s' "$GW")
"
        save_state "${KEY_IP}"   "$IP"
        save_state "${KEY_PFX}"  "$PFX"
        save_state "${KEY_GW}"   "${GW:-}"
        save_state "${KEY_MODE}" "static"
    else
        NEW_IFACES="${NEW_IFACES}
auto ${NIC}
iface ${NIC} inet dhcp
"
        save_state "${KEY_IP}"   ""
        save_state "${KEY_PFX}"  ""
        save_state "${KEY_GW}"   ""
        save_state "${KEY_MODE}" "dhcp"
    fi

    echo
    IDX=$((IDX+1))
done

gum confirm "Apply network configuration?" || return

# Write /etc/network/interfaces
cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback
${NEW_IFACES}
EOF

gum spin --title "Applying network configuration..." -- \
    sh -c "ifdown -a 2>/dev/null; ifup -a 2>/dev/null"
gum style --foreground 82 "Network configuration applied."
sleep 2

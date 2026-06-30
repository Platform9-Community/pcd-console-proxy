#!/bin/sh
# Login shell replacement — PCD Console Proxy main menu
#
# When used as root's login shell, crond and other tools invoke this script
# with -c <command> for non-interactive execution. Pass those through to
# /bin/sh so cron jobs work normally; only show the TUI for real TTY logins.
case "$1" in
    -c) shift; exec /bin/sh -c "$@" ;;
    -s) exec /bin/sh -s "$@" ;;
esac
[ -t 0 ] || exec /bin/sh "$@"

# gum/Bubble Tea requires TERM; set a sane default when sshd hasn't forwarded it.
export TERM="${TERM:-xterm-256color}"
export COLORTERM="${COLORTERM:-truecolor}"

LIBDIR="/usr/local/lib/pcd-proxy"
. "$LIBDIR/common.sh"

# INT: non-destructive — Ctrl-C in sub-screens returns to main menu, not login prompt
# TERM: show timeout message then exit (used by auto-logout timer and system shutdown)
trap 'stty sane 2>/dev/null' INT
trap 'stty sane 2>/dev/null; clear; printf "\n\033[33mSession timed out — logged out.\033[0m\n\n"; sleep 2; exit 0' TERM
trap 'stty sane 2>/dev/null' EXIT

PCD_VERSION=$(cat /etc/pcd-proxy/version 2>/dev/null || echo "dev")

_TIMER_PID=""

while true; do
    load_state
    clear
    gum style \
        --border double \
        --border-foreground 33 \
        --padding "1 4" \
        --align center \
        --width "${COLUMNS:-120}" \
        --bold \
        --foreground 255 \
        "PCD Console Proxy  v${PCD_VERSION}"

    BACKEND_COUNT=0
    for _ep in $BACKEND_IPS; do BACKEND_COUNT=$((BACKEND_COUNT+1)); done
    BACKEND_DISPLAY="${BACKEND_COUNT} backend(s)"
    DOMAIN_DISPLAY="${DOMAIN:-<not set>}"

    # Per-NIC status from runtime (picks up Nova-injected IPs)
    NIC_STATUS=""
    for _NIC in $(ip link show 2>/dev/null | awk -F': ' '/^[0-9]+:/ && !/lo:/{gsub(/@.*/,"",$2); print $2}' | grep -v '^docker\|^br-\|^virbr\|^veth'); do
        _IP=$(ip -f inet addr show "$_NIC" 2>/dev/null | awk '/inet /{print $2}')
        NIC_STATUS="${NIC_STATUS}  ${_NIC}: ${_IP:-<no IP>}"
    done
    gum style --faint "${NIC_STATUS:-  (no interfaces)}  |  Backends: $BACKEND_DISPLAY  |  Domain: $DOMAIN_DISPLAY"

    if [ "$BACKEND_COUNT" -eq 0 ]; then
        echo
        gum style --foreground 214 --width "${COLUMNS:-120}" \
            "⚠  No backend configured — select 'Backend Target' to add a nova-novncproxy server."
    fi
    echo

    # Start inactivity timer — sends SIGTERM if main menu is idle for too long
    _TIMER_PID=""
    if [ "${AUTO_LOGOUT_MINUTES:-0}" -gt 0 ] 2>/dev/null; then
        ( sleep $((AUTO_LOGOUT_MINUTES * 60)) && kill -TERM $$ 2>/dev/null ) &
        _TIMER_PID=$!
    fi

    CHOICE=$(gum choose \
        --cursor "▶ " \
        --cursor.foreground 33 \
        --selected.foreground 255 \
        "Network Configuration" \
        "Backend Target" \
        "Authentication (Keystone)" \
        "TLS / Certificate" \
        "Service Management" \
        "View Logs" \
        "Change Root Password" \
        "Emergency Shell" \
        "Logout")

    # Cancel timer — user made a choice
    kill "$_TIMER_PID" 2>/dev/null; wait "$_TIMER_PID" 2>/dev/null; _TIMER_PID=""

    case "$CHOICE" in
        "Network Configuration")       sh "$LIBDIR/network.sh"  ;;
        "Backend Target")              sh "$LIBDIR/backend.sh"  ;;
        "Authentication (Keystone)")   sh "$LIBDIR/auth.sh"     ;;
        "TLS / Certificate")           sh "$LIBDIR/tls.sh"      ;;
        "Service Management")          sh "$LIBDIR/service.sh"  ;;
        "View Logs")                   sh "$LIBDIR/logs.sh"     ;;
        "Change Root Password")
            echo
            NEW1=$(gum input --password --prompt "  New password: " --width "${COLUMNS:-120}")
            [ -z "$NEW1" ] && continue
            NEW2=$(gum input --password --prompt "  Confirm password: " --width "${COLUMNS:-120}")
            if [ "$NEW1" != "$NEW2" ]; then
                gum style --foreground 196 --width "${COLUMNS:-120}" "✗  Passwords do not match."
                sleep 2; continue
            fi
            printf 'root:%s\n' "$NEW1" | chpasswd
            gum style --foreground 82 --width "${COLUMNS:-120}" "✓  Root password updated."
            sleep 2
            ;;
        "Emergency Shell")
            if gum confirm "Drop to emergency shell? Type 'exit' to return."; then
                /bin/sh
            fi
            ;;
        "Logout")
            clear
            exit 0
            ;;
        "")
            # ESC or empty — loop back
            ;;
    esac
done

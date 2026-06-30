#!/bin/sh
# TUI screen: Service management (nginx + pcd-auth)

LIBDIR="/usr/local/lib/pcd-proxy"
. "$LIBDIR/common.sh"

clear
header "Service Management"
echo

_status_line() {
    local svc="$1"
    if rc-service "$svc" status >/dev/null 2>&1; then
        printf "  %-14s  " "$svc"
        gum style --foreground 82 "running"
    else
        printf "  %-14s  " "$svc"
        gum style --foreground 196 "stopped"
    fi
}

_status_line nginx
_status_line pcd-auth
echo

CHOICE=$(gum choose \
    "Restart nginx" \
    "Restart pcd-auth" \
    "Restart all" \
    "Stop nginx" \
    "Stop pcd-auth" \
    "View nginx error log" \
    "Back")

case "$CHOICE" in
    "Restart nginx")
        gum spin --title "Restarting nginx..." -- rc-service nginx restart
        gum style --foreground 82 "Done."
        ;;
    "Restart pcd-auth")
        gum spin --title "Restarting pcd-auth..." -- rc-service pcd-auth restart
        gum style --foreground 82 "Done."
        ;;
    "Restart all")
        gum spin --title "Restarting services..." -- sh -c "rc-service nginx restart && rc-service pcd-auth restart"
        gum style --foreground 82 "All services restarted."
        ;;
    "Stop nginx")
        gum confirm "Stop nginx? The proxy will be unreachable." && rc-service nginx stop
        ;;
    "Stop pcd-auth")
        gum confirm "Stop pcd-auth? All sessions will be invalidated." && rc-service pcd-auth stop
        ;;
    "View nginx error log")
        tail -n 50 /var/log/nginx/error.log 2>/dev/null | gum pager
        ;;
    *) return ;;
esac

sleep 2

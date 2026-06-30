#!/bin/sh
# TUI screen: Log viewer

LIBDIR="/usr/local/lib/pcd-proxy"
. "$LIBDIR/common.sh"

clear
header "View Logs"
echo

CHOICE=$(gum choose \
    "nginx — access log (live)" \
    "nginx — error log (live)" \
    "pcd-auth log (live)" \
    "System log (live)" \
    "nginx — access log (pager)" \
    "nginx — error log (pager)" \
    "Back")

case "$CHOICE" in
    "nginx — access log (live)")
        gum style --faint "Press Ctrl-C to return to menu."
        tail -f /var/log/nginx/access.log
        ;;
    "nginx — error log (live)")
        gum style --faint "Press Ctrl-C to return to menu."
        tail -f /var/log/nginx/error.log
        ;;
    "pcd-auth log (live)")
        gum style --faint "Press Ctrl-C to return to menu."
        tail -f /var/log/pcd-auth.log 2>/dev/null || \
            tail -f /var/log/messages | grep pcd-auth
        ;;
    "System log (live)")
        gum style --faint "Press Ctrl-C to return to menu."
        tail -f /var/log/messages
        ;;
    "nginx — access log (pager)")
        tail -n 200 /var/log/nginx/access.log 2>/dev/null | gum pager
        ;;
    "nginx — error log (pager)")
        tail -n 200 /var/log/nginx/error.log 2>/dev/null | gum pager
        ;;
    *) return ;;
esac

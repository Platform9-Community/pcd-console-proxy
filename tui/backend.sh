#!/bin/sh
# TUI screen: noVNC backend management (multiple ip:port targets)

LIBDIR="/usr/local/lib/pcd-proxy"
. "$LIBDIR/common.sh"

_show_backends() {
    load_state
    if [ -z "$BACKEND_IPS" ]; then
        gum style --foreground 214 "  No backends configured."
    else
        for ep in $BACKEND_IPS; do
            gum style --foreground 82 "  • $ep"
        done
    fi
}

_add_backend() {
    local ep
    ep=$(gum input \
        --placeholder "e.g. 10.0.0.10:6080" \
        --prompt "  Backend IP:port: ")
    [ -z "$ep" ] && return

    # Basic validation: must contain a colon
    case "$ep" in
        *:*) ;;
        *) gum style --foreground 196 "  Invalid format — use IP:PORT"; sleep 2; return ;;
    esac

    load_state
    # Deduplicate
    for existing in $BACKEND_IPS; do
        [ "$existing" = "$ep" ] && \
            gum style --foreground 214 "  $ep already in list." && sleep 2 && return
    done

    NEW_IPS="${BACKEND_IPS:+$BACKEND_IPS }$ep"
    save_state BACKEND_IPS "$NEW_IPS"
    apply_nginx_config
    gum style --foreground 82 "  Added $ep. Nginx reloaded."
    sleep 1
}

_remove_backend() {
    load_state
    [ -z "$BACKEND_IPS" ] && \
        gum style --foreground 214 "  No backends to remove." && sleep 2 && return

    # Build a list for gum choose
    CHOICE=$(printf '%s\n' $BACKEND_IPS | gum choose --height 10 --header "Select backend to remove:")
    [ -z "$CHOICE" ] && return

    # Rebuild list without chosen entry
    NEW_IPS=""
    for ep in $BACKEND_IPS; do
        [ "$ep" = "$CHOICE" ] && continue
        NEW_IPS="${NEW_IPS:+$NEW_IPS }$ep"
    done
    save_state BACKEND_IPS "$NEW_IPS"
    apply_nginx_config
    gum style --foreground 82 "  Removed $CHOICE. Nginx reloaded."
    sleep 1
}

_refresh_backends() {
    if [ ! -s /etc/pcd-proxy/app-credential.env ]; then
        gum style --foreground 214 "  No app credential configured."
        gum style --faint "  Inject /etc/pcd-proxy/app-credential.env via cloud-init user-data,"
        gum style --faint "  or add backends manually."
        sleep 3
        return
    fi
    gum spin --title "Discovering backends from PCD..." -- \
        /usr/local/lib/pcd-proxy/discover-backends.sh
    load_state
    COUNT=0
    for _ in $BACKEND_IPS; do COUNT=$((COUNT+1)); done
    gum style --foreground 82 "  Discovery complete — $COUNT backend(s) found."
    sleep 2
}

while true; do
    clear
    header "Backend Targets"
    echo
    gum style --faint "  nova-novncproxy backends (ip:port). Traffic is sticky by source IP."
    echo
    _show_backends
    echo

    CHOICE=$(gum choose \
        --cursor "▶ " \
        --cursor.foreground 33 \
        "Add Backend" \
        "Remove Backend" \
        "Refresh from PCD" \
        "Done")

    case "$CHOICE" in
        "Add Backend")           _add_backend ;;
        "Remove Backend")        _remove_backend ;;
        "Refresh from PCD") _refresh_backends ;;
        *) break ;;
    esac
done

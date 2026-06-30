#!/bin/sh
# TUI screen: Keystone authentication configuration

LIBDIR="/usr/local/lib/pcd-proxy"
. "$LIBDIR/common.sh"
load_state

clear
header "Authentication — Keystone"
echo

gum style --faint \
    "Configure the OpenStack Keystone endpoint used to authenticate console users." \
    "Users log in with their Keystone credentials scoped to a project." \
    "Leave ALLOWED_PROJECTS empty to permit any valid Keystone project."
echo

OS_AUTH_URL=$(gum input \
    --placeholder "e.g. https://keystone.example.com:5000" \
    --value "${OS_AUTH_URL:-}" \
    --prompt "  Keystone auth URL: ")
[ -z "$OS_AUTH_URL" ] && return

ALLOWED_PROJECTS=$(gum input \
    --placeholder "project-id-1,project-id-2  (blank = allow any)" \
    --value "${ALLOWED_PROJECTS:-}" \
    --prompt "  Allowed project IDs: ")

SESSION_TTL_MINUTES=$(gum input \
    --placeholder "10" \
    --value "${SESSION_TTL_MINUTES:-10}" \
    --prompt "  Session TTL (minutes): ")

echo
gum confirm "Save and restart auth daemon?" || return

save_state OS_AUTH_URL         "$OS_AUTH_URL"
save_state ALLOWED_PROJECTS    "$ALLOWED_PROJECTS"
save_state SESSION_TTL_MINUTES "$SESSION_TTL_MINUTES"

gum spin --title "Restarting pcd-auth..." -- rc-service pcd-auth restart

if rc-service pcd-auth status >/dev/null 2>&1; then
    gum style --foreground 82 "Auth daemon restarted successfully."
else
    gum style --foreground 196 "Auth daemon failed to start. Check: rc-service pcd-auth status"
fi
sleep 2

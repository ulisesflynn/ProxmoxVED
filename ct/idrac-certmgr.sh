#!/usr/bin/env bash
# --- TESTING ONLY: pull framework + install/defaults from this fork/branch. Remove before PR. ---
export COMMUNITY_SCRIPTS_URL="https://raw.githubusercontent.com/ulisesflynn/ProxmoxVED/add/idrac-cert"
source <(curl -fsSL "$COMMUNITY_SCRIPTS_URL/misc/build.func")
# Copyright (c) 2021-2026 community-scripts ORG
# Author: you
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/acmesh-official/acme.sh
# Description: Issues Let's Encrypt certs via Cloudflare DNS-01 and pushes them
#              to multiple Dell iDRAC 8 boxes over remote racadm (HTTPS/443).
#              Auto-renews, redeploys, and healthchecks. No SSH to iDRAC needed.

APP="iDRAC-CertMgr"
var_tags="${var_tags:-network;certificates}"
var_cpu="${var_cpu:-1}"
var_ram="${var_ram:-512}"
var_disk="${var_disk:-4}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -d /opt/idrac-certs ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi
  msg_info "Updating acme.sh"
  $STD /root/.acme.sh/acme.sh --upgrade
  msg_ok "Updated acme.sh"
  exit
}

# ---- Optional credential wizard (runs on the Proxmox host) ----
CONFIGURE_CREDS="no"
function collect_settings() {
  whiptail --backtitle "Proxmox VE Helper Scripts" --title "iDRAC-CertMgr Setup" \
    --yesno "Configure Cloudflare + iDRAC credentials now so the container is ready to run?\n\nChoose No to fill them in manually later." 12 72 || return
  CONFIGURE_CREDS="yes"
  CF_TOKEN=$(whiptail --backtitle "iDRAC-CertMgr" --inputbox "Cloudflare API token (scoped Zone:DNS:Edit)" 8 72 3>&1 1>&2 2>&3) || CONFIGURE_CREDS="no"
  CF_ZONE=$(whiptail --backtitle "iDRAC-CertMgr" --inputbox "Cloudflare Zone ID" 8 72 3>&1 1>&2 2>&3)
  IDRAC_USER=$(whiptail --backtitle "iDRAC-CertMgr" --inputbox "Default iDRAC username (use a limited user, not root)" 8 72 "certmgr" 3>&1 1>&2 2>&3)
  IDRAC_PASS=$(whiptail --backtitle "iDRAC-CertMgr" --passwordbox "Default iDRAC password" 8 72 3>&1 1>&2 2>&3)
  FIRST_FQDN=$(whiptail --backtitle "iDRAC-CertMgr" --inputbox "First iDRAC FQDN (optional, leave blank to skip)" 8 72 3>&1 1>&2 2>&3)
  FIRST_IP=$(whiptail --backtitle "iDRAC-CertMgr" --inputbox "First iDRAC IP address (optional)" 8 72 3>&1 1>&2 2>&3)
  NOTIFY_URL=$(whiptail --backtitle "iDRAC-CertMgr" --inputbox "Healthcheck notify URL (ntfy topic / webhook, optional)" 8 72 3>&1 1>&2 2>&3)
}

# Collect credentials up front (before the container is built), exactly once.
collect_settings

start
build_container
description

# ---- Write the collected credentials into the container (after it exists) ----
# Guarded on /opt/idrac-certs so a failed/404'd install can't hard-fail here.
if [[ "$CONFIGURE_CREDS" == "yes" ]]; then
  if pct exec "$CTID" -- test -d /opt/idrac-certs 2>/dev/null; then
    msg_info "Writing credentials into the container"
    pct exec "$CTID" -- mkdir -p /opt/idrac-certs
    # %q-quoting keeps tokens/passwords safe for `source` in the env files
    printf 'CF_Token=%q\nCF_Zone_ID=%q\n' "${CF_TOKEN:-}" "${CF_ZONE:-}" \
      | pct exec "$CTID" -- bash -c 'umask 077; cat >/opt/idrac-certs/cloudflare.env'
    printf 'NTFY_URL=%q\nHC_PING_URL=%q\nHC_WARN_DAYS=21\n' "${NOTIFY_URL:-}" "" \
      | pct exec "$CTID" -- bash -c 'umask 077; cat >/opt/idrac-certs/notify.env'
    if [[ -n "${FIRST_FQDN:-}" && -n "${FIRST_IP:-}" ]]; then
      printf '%s %s %s %s\n' "$FIRST_FQDN" "$FIRST_IP" "${IDRAC_USER:-certmgr}" "${IDRAC_PASS:-}" \
        | pct exec "$CTID" -- bash -c 'umask 077; cat >>/opt/idrac-certs/servers.conf'
    fi
    msg_ok "Credentials written"
  else
    msg_error "/opt/idrac-certs not found in CT ${CTID}. The install script did not run (check for a 404 above). Your entered credentials were not written; container left intact for inspection."
  fi
fi

msg_ok "Completed Successfully!\n"
echo -e "${INFO}${YW} This is a headless cert-automation worker (no web UI).${CL}"
echo -e "${INFO}${YW} On each iDRAC: ensure the web/Remote RACADM interface is reachable on 443${CL}"
echo -e "${TAB}(iDRAC Settings -> Services). SSH does NOT need to be enabled.${CL}"
echo -e "${INFO}${YW} Add a Cloudflare A record per iDRAC (grey cloud) -> its private IP.${CL}"
echo -e "${INFO}${YW} Then inside the container (pct enter ${CTID:-<ctid>}):${CL}"
echo -e "${TAB}1) idrac-certs install-racadm <Dell-iDRACTools-Web-LX tarball URL>"
echo -e "${TAB}2) edit /opt/idrac-certs/servers.conf   (add any more iDRACs)"
echo -e "${TAB}3) idrac-certs check                    (verify reachability + auth)"
echo -e "${TAB}4) idrac-certs issue --staging          (dry run: verifies pipeline, no deploy)"
echo -e "${TAB}5) idrac-certs issue                    (issue + deploy all)"
echo -e "${INFO}${YW} Certs auto-renew/redeploy via acme.sh's daily cron; healthcheck runs daily.${CL}"

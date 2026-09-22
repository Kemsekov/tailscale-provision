#!/usr/bin/env bash
# provision_tailscale.sh — config-driven Tailscale & Wake-on-LAN fleet provisioner
#
# Reads config.json (subnets, credentials, auth_key, ssh_public_key,
# re_search_delay_sec). For every host that is SSH-able with one of the
# given credential pairs it:
#   1. installs Tailscale (if missing)
#   2. joins the tailnet with auth_key
#   3. enables tailscaled at boot (persistent)
#   4. ensures ssh_public_key is in authorized_keys (admin/lab/vlad/student)
#   5. installs ethtool, enables Wake-on-LAN, and configures its daemon
#
# If re_search_delay_sec > 0 the whole process repeats forever, sleeping that
# many seconds between passes. If 0, it runs exactly once.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG="${CONFIG:-$SCRIPT_DIR/config.json}"
[ -f "$CONFIG" ] || { echo "config not found: $CONFIG"; exit 1; }

eval "$(python3 - "$CONFIG" <<'PY'
import json, sys, shlex
d = json.load(open(sys.argv[1]))
def q(s): return shlex.quote(str(s))
print('SUBNETS=(' + ' '.join(q(x) for x in d.get('subnets', [])) + ')')
print('CREDS=(' + ' '.join(q(f"{c.get('username','')}:{c.get('password','')}")
                          for c in d.get('credentials', [])) + ')')
print('AUTH_KEY=' + q(d.get('auth_key', '')))
print('PUBKEY=' + q(d.get('ssh_public_key', '')))
print('DELAY=' + q(d.get('re_search_delay_sec', 0)))
PY
)"

[ -n "${AUTH_KEY:-}" ] || { echo "auth_key missing in $CONFIG"; exit 1; }
[ -n "${PUBKEY:-}" ]   || { echo "ssh_public_key missing in $CONFIG"; exit 1; }
FP=$(awk '{print $2}' <<<"$PUBKEY")

SSH_OPTS=(-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new
          -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no)
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO=sudo

PAYLOAD=$(cat <<'EOS'
#!/bin/bash
SUDO_PASS="$1"
sudo_run() { echo "$SUDO_PASS" | sudo -S -p '' "$@"; }
log() { echo "[payload] $*"; }
if ! sudo_run true 2>/dev/null; then log "sudo failed"; exit 1; fi

if ! command -v tailscale >/dev/null 2>&1; then
    log "installing tailscale"
    ARCH=$(dpkg --print-architecture 2>/dev/null || echo amd64)
    TMPD=$(mktemp -d)
    if curl -fsSL --max-time 180 "https://pkgs.tailscale.com/stable/ubuntu/pool/tailscale_1.102.4_${ARCH}.deb" -o "$TMPD/ts.deb" \
        && sudo_run dpkg -i "$TMPD/ts.deb" >/dev/null 2>&1; then
        log "installed via deb"
    else
        log "deb failed; trying official install script"
        if curl -fsSL --max-time 120 https://tailscale.com/install.sh -o "$TMPD/install.sh"; then
            sudo_run bash "$TMPD/install.sh" >/dev/null 2>&1
        fi
    fi
    rm -rf "$TMPD"
fi

sudo_run systemctl enable --now tailscaled >/dev/null 2>&1

if ! sudo_run timeout 90 tailscale up --auth-key='__AUTH_KEY__' 2>/tmp/ts_up.err; then
    if grep -q 'non-default flags' /tmp/ts_up.err 2>/dev/null; then
        FLAGS=$(grep -oE 'tailscale up .*' /tmp/ts_up.err | head -1 | sed 's/^tailscale up //; s/--auth-key=[^ ]*//g')
        log "retrying with flags:$FLAGS"
        sudo_run timeout 90 tailscale up --auth-key='__AUTH_KEY__' $FLAGS 2>&1 | tail -2
    else
        log "tailscale up error:"; tail -2 /tmp/ts_up.err
    fi
fi

# === WAKE-ON-LAN INJECTION ===
log "configuring wake-on-lan"
if ! command -v ethtool >/dev/null 2>&1; then
    log "installing ethtool"
    if command -v apt-get >/dev/null 2>&1; then
        sudo_run apt-get update >/dev/null 2>&1 && sudo_run apt-get install -y ethtool >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        sudo_run dnf install -y ethtool >/dev/null 2>&1
    fi
fi

# Dynamically find the primary Ethernet interface (ignores loopback, virtual bridges, tailscale, zerotier, hamachi, etc.)
WOL_INTF=$(ip -br link | grep -E -v '^(lo|ts|tailscale|docker|br-|veth|wl|zt|ham)' | head -n 1 | awk '{print $1}')

if [ -n "$WOL_INTF" ] && command -v ethtool >/dev/null 2>&1; then
    # Test if hardware supports WOL
    if sudo_run ethtool "$WOL_INTF" 2>/dev/null | grep -q "Supports Wake-on:.*g"; then
        log "enabling WOL on $WOL_INTF"
        sudo_run ethtool -s "$WOL_INTF" wol g >/dev/null 2>&1

        # Create persistent systemd unit file
        sudo_run sh -c "cat << 'EOF' > /etc/systemd/system/wol.service
[Unit]
Description=Enable Wake-on-LAN on $WOL_INTF
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ethtool -s $WOL_INTF wol g

[Install]
WantedBy=multi-user.target
EOF"

        sudo_run systemctl daemon-reload >/dev/null 2>&1
        sudo_run systemctl enable --now wol.service >/dev/null 2>&1
        log "WOL daemon persistent state: $(systemctl is-enabled wol.service 2>/dev/null)"
    else
        log "WOL not supported by interface $WOL_INTF or disabled in BIOS"
    fi
else
    log "failed to find valid Ethernet interface or ethtool is missing"
fi
# =============================

for user in $(id -un) admin lab vlad student; do
    h=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
    [ -z "$h" ] && continue
    sudo_run mkdir -p "$h/.ssh" 2>/dev/null
    sudo_run touch "$h/.ssh/authorized_keys" 2>/dev/null
    if ! sudo_run grep -qF '__FP__' "$h/.ssh/authorized_keys" 2>/dev/null; then
        sudo_run sh -c "printf '%s\n' '__PUBKEY__' >> '$h/.ssh/authorized_keys'"
    fi
    sudo_run chown -R "$user:$user" "$h/.ssh" 2>/dev/null
    sudo_run chmod 700 "$h/.ssh" 2>/dev/null
    sudo_run chmod 600 "$h/.ssh/authorized_keys" 2>/dev/null
done

log "node: $(sudo_run tailscale status --self=true --peers=false 2>/dev/null | head -1)"
log "ip:   $(sudo_run tailscale ip -4 2>/dev/null)"
log "svc:  $(systemctl is-enabled tailscaled 2>/dev/null)/$(systemctl is-active tailscaled 2>/dev/null)"
EOS
)
PAYLOAD=${PAYLOAD//__AUTH_KEY__/$AUTH_KEY}
PAYLOAD=${PAYLOAD//__PUBKEY__/$PUBKEY}
PAYLOAD=${PAYLOAD//__FP__/$FP}

run_pass() {
    echo "== discovering SSH hosts on: ${SUBNETS[*]} =="
    declare -A SEEN=()
    HOSTS=()
    for net in "${SUBNETS[@]}"; do
        while read -r ip; do
            [ -z "$ip" ] && continue
            [ -n "${SEEN[$ip]:-}" ] && continue
            SEEN[$ip]=1; HOSTS+=("$ip")
        done < <($SUDO nmap -sS -Pn -n -p22 --open --min-rate 3000 "$net" -oG - 2>/dev/null | awk '/22\/open/ {print $2}')
    done
    echo "candidates with SSH open: ${#HOSTS[@]}"
    for ip in "${HOSTS[@]}"; do echo "  $ip"; done

    OK=0; SKIP=0
    for ip in "${HOSTS[@]}"; do
        for cred in "${CREDS[@]}"; do
            u=${cred%%:*}; p=${cred##*:}
            if sshpass -p "$p" ssh "${SSH_OPTS[@]}" "$u@$ip" 'echo LOGIN_OK' 2>/dev/null | grep -q LOGIN_OK; then
                echo "[+] $ip — login OK as $u"
                os=$(sshpass -p "$p" ssh "${SSH_OPTS[@]}" "$u@$ip" 'uname -s 2>/dev/null || echo unknown' 2>/dev/null)
                if [ "$os" != "Linux" ]; then
                    echo "    skipped: OS=$os (not Linux)"; SKIP=$((SKIP+1)); break
                fi
                printf '%s' "$PAYLOAD" | sshpass -p "$p" ssh "${SSH_OPTS[@]}" "$u@$ip" \
                    "cat > /tmp/ts_provision.sh && bash /tmp/ts_provision.sh '$p'; rm -f /tmp/ts_provision.sh" 2>&1 | sed 's/^/    /'
                OK=$((OK+1))
                break
            fi
        done
    done
    echo "== pass summary: provisioned=$OK skipped=$SKIP =="
}

while :; do
    echo "===== pass started: $(date -Is) ====="
    run_pass
    if [ "${DELAY:-0}" -gt 0 ] 2>/dev/null; then
        echo "===== pass done: $(date -Is); sleeping ${DELAY}s ====="
        sleep "$DELAY"
    else
        echo "===== pass done: $(date -Is); re_search_delay_sec=0, exiting ====="
        break
    fi
done

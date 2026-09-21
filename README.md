# tailscale-provision

Config-driven provisioner that finds SSH-able machines on given subnets and sets
them up with Tailscale.

For every host that accepts one of the configured username/password pairs it:

1. installs Tailscale (if missing)
2. joins the tailnet with the configured `auth_key`
3. enables `tailscaled` at boot (persistent)
4. ensures the configured SSH public key is present in `authorized_keys`
   (for the login user plus `admin`, `lab`, `vlad`, `student` when they exist)

If `re_search_delay_sec` is greater than `0`, the whole process repeats forever,
sleeping that many seconds between passes. With `0` it runs once and exits.

## Requirements

- `bash`, `nmap`, `sshpass`, `python3`, `curl`, `openssh-client`
- network access to the target subnets
- `sudo` on the targets (passwords are supplied from config)

## Configuration

Copy `config.example.json` to `config.json` and fill in real values:

```json
{
  "subnets": ["100.100.56.0/22", "100.100.60.0/24"],
  "credentials": [
    { "username": "admin", "password": "CHANGE_ME" }
  ],
  "auth_key": "tskey-auth-REPLACE_ME",
  "ssh_public_key": "ssh-ed25519 AAAA... user@host",
  "re_search_delay_sec": 600
}
```

- `subnets` – IP ranges to scan for SSH (port 22)
- `credentials` – username/password pairs tried against each host
- `auth_key` – Tailscale auth key used for `tailscale up`
- `ssh_public_key` – public key appended to `authorized_keys`
- `re_search_delay_sec` – seconds between passes; `0` = run once

`config.json` contains secrets and is ignored by git.

## Usage

```bash
./provision_tailscale.sh                 # uses ./config.json
CONFIG=/path/to/config.json ./provision_tailscale.sh
```

Continuous run in the background:

```bash
setsid nohup ./provision_tailscale.sh >> provision.log 2>&1 < /dev/null &
```

Stop with `pkill -f provision_tailscale.sh`.

## Security

- Never commit `config.json` (credentials + Tailscale auth key).
- Prefer short-lived, tagged Tailscale auth keys and rotate them.

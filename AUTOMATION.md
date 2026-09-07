# Automation status

Audit of everything this project configures, split by how it is codified.

The setup is layered:

1. **Install layer** — `apollo-gaming.yaml` user data. Runs once, at instance creation.
2. **Config layer** — `config/` + `apply-config.sh` / `dump-config.sh`. Applies to a running
   instance at any time. Day-to-day tuning lives here.
3. **Manual layer** — steps that cannot be scripted, listed below with reasons.

Recovery for state that cannot be rebuilt from code: daily DLM snapshots (30-day retention).

## Codified — install layer (`apollo-gaming.yaml`)

- NVIDIA gaming driver from `s3://nvidia-gaming`, silent install
- `vGamingMarketplace=2` registry value + `GridSwCert_2026_03_02.cert` license cert
  (with a wrong or old cert, the driver installs cleanly but is silently unlicensed)
- Apollo 0.4.6 silent install. Web UI credentials are set post-reboot, with the service stopped
- `sunshine.conf` baseline: `origin_web_ui_allowed=wan`, `headless_mode`,
  `isolated_virtual_display_option`, `av1_mode=3`, `dd_configuration_option=ensure_only_display`
- Default `apps.json` with `virtual-display: true` — **setup-time apps only**. Tiles added later
  in the web UI default to `virtual-display: false`. The config layer fixes those
- Autologon, VB-Cable, ViGEmBus, Media Foundation, audio service, firewall rules
- Steam, GOG Galaxy (+ vcredist140, webview2)
- RDP-to-console scheduled task, Elastic IP, daily 02:00 auto-stop, DLM snapshot policy
- Security group ingress = your current IP, auto-detected by `deploy-apollo.sh`

**Validated 2026-08-09** by a from-scratch smoke-test deploy (g6.xlarge, 100 GB volume):
CREATE_COMPLETE with cfn-signal in ~13 min. The driver installed and reported **Licensed**.
All three NVENC encoders (h264/hevc/av1) were detected. SudoVDA was present. The autologon
console session was active. Steam, GOG, ViGEmBus and audio were OK. The web UI and the pairing
port were reachable from the allowed IP.

**Follow-up behavioral test, same day:** PIN pairing and a live Desktop stream were verified on
the fresh box, fully scripted from the client machine — `moonlight pair <host> --pin <PIN>` plus
the PIN submitted through Apollo's API (`POST /api/login` for a session cookie, then
`POST /api/pin`), then `moonlight stream <host> Desktop`. A mid-session readout confirmed the
display-topology automation: SudoVDA came up at the client's exact resolution, and the capture
geometry read `Offset: 0x0` with `Virtual Desktop` equal to the client resolution. The virtual
display owns origin (0,0), and the phantom NVIDIA head is excluded from the desktop canvas
(`ensure_only_display` at work).

## Codified — config layer (`config/`)

- `config/apps.json` — the app tiles (Desktop + Steam Big Picture) with the critical field
  `virtual-display: true`. Useful fields when you add game tiles: a direct-exe `cmd` (DRM-free
  games need no launcher), a `prep-cmd` undo with `taskkill` (closes the game when the stream
  ends), `working-dir`, `exit-timeout`, `gamepad`
- `config/sunshine.conf` — full canonical file, including `av1_mode = 3` (AV1 8-bit + 10-bit HDR)
- Workflow: edit `config/*` → `./apply-config.sh` (restarts Apollo — drops live sessions).
  After web-UI experiments: `./dump-config.sh` → review the drift diff → adopt (`cp` + commit)
  or discard (`./apply-config.sh`)
- After any fresh deploy: run `./apply-config.sh` once to bring the box to canonical state
- `monitoring/` + `./setup-monitoring.sh`: CloudWatch agent for RAM and disk, plus a scheduled
  task that publishes NVIDIA GPU metrics every minute. The agent's `nvidia_gpu` plugin is
  Linux-only, so `monitoring/gpu-metrics.ps1` mimics its metric names and dimensions in the
  `CWAgent` namespace — which also feeds Compute Optimizer's GPU rightsizing. All scripts honor
  the `STACK_NAME` override

## Manual — once per rebuild (and why)

| Step | Why it is not codified |
|---|---|
| Store logins (Steam, GOG, ...) | Interactive auth + 2FA. Stored credentials would be worse than the manual step |
| Game installs | Tied to the account login, plus large downloads. `steamcmd` and similar tools exist but need stored credentials |
| Per-game graphics settings | Live in each game's own config files on the box |

Practical mitigation for all of the above: the EBS snapshots. A rebuild from a snapshot keeps
logins, games and settings. A rebuild from the template repeats these manual steps once.

## Manual — once per client (inherently)

| Step | Why |
|---|---|
| Moonlight PIN pairing | Security by design |
| Apollo per-client permission grant (fixes HTTP 403 on first launch) | Tied to the pairing that just happened |
| Client-side settings (codec, bitrate, HDR toggle) | Live on the client device |

Client pairings and permissions live in Apollo's state files on the EBS volume. Snapshots cover
them. A from-template rebuild loses them — re-pair each client (~2 min per device).

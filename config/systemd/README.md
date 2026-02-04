# systemd Timer Configuration

Systemd timers for scheduled homelab tasks.

## Timers

| Timer | Schedule | Purpose |
|-------|----------|---------|
| `snapraid-runner` | Daily 2:00 AM | SnapRAID sync/scrub |
| `disk-monitor` | Every 5 min | Disk health monitoring |

## Installation

```bash
sudo cp /home/cyl/homelab/config/systemd/*.timer /etc/systemd/system/
sudo cp /home/cyl/homelab/config/systemd/*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now snapraid-runner.timer
sudo systemctl enable --now disk-monitor.timer
```

## Commands

```bash
# Check timer status
systemctl list-timers

# View logs
journalctl -u disk-monitor.service -n 50

# Manual trigger
sudo systemctl start snapraid-runner.service
```

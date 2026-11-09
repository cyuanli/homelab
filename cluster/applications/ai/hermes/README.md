# Hermes Agent

[Hermes Agent](https://github.com/NousResearch/hermes-agent) talking over Matrix (E2EE), using the
Claude subscription via the official
[claude-subscription-directsdk](https://hermes-agent.nousresearch.com/marketplace/claude-subscription-directsdk)
plugin (shells out to the `claude` CLI). Experimental; may stop working if Anthropic changes policy.

Hermes state (config, memories, skills, plugin, `claude` binary and login, Matrix crypto store) lives in
`/srv/app-storage/hermes` on `cyl-homelab`, backed up by borgmatic (caches and reinstallable
tools excluded, see `config/borgmatic/config.yaml`).

## Setup

1. Register a bot account (e.g. `@<name>-hermes:matrix.org`) at app.element.io, set up Secure
   Backup and save the recovery key, then log out of Element. Get a dedicated token/device:

   ```bash
   curl -s -X POST https://matrix.org/_matrix/client/v3/login -H 'Content-Type: application/json' \
     -d '{"type":"m.login.password","identifier":{"type":"m.id.user","user":"<bot>"},"password":"<pw>","initial_device_display_name":"hermes"}'
   ```
2. `cp secrets.yaml.template secrets.yaml` and fill in the token, recovery key and your own Matrix ID.
3. `kubectl apply -k cluster/applications/ai/hermes`
4. One-time setup inside the pod (persists on the volume):

```bash
H="kubectl -n ai exec -it deploy/hermes --"
AS_HERMES="/command/s6-setuidgid hermes env HOME=/opt/data"

$H $AS_HERMES npm install -g --prefix /opt/data/.local @anthropic-ai/claude-code
# npm's postinstall doesn't run here; without this claude reports "native binary not installed"
$H $AS_HERMES sh -c 'cd /opt/data/.local/lib/node_modules/@anthropic-ai/claude-code && node install.cjs'
$H $AS_HERMES /opt/data/.local/bin/claude auth login
$H hermes plugins install claude-subscription-directsdk
$H hermes plugins enable claude-subscription-directsdk-experimental
$H hermes config set model.provider claude-subscription-directsdk-experimental
$H hermes config set model.default sonnet
```

5. Proton Mail Bridge login (`proton-bridge` container waits until this is done). Use `login`,
   then `info` for the IMAP username/password Hermes needs, then `exit`:

   ```bash
   kubectl -n ai exec -it deploy/hermes -c proton-bridge -- protonmail-bridge --cli
   kubectl -n ai exec deploy/hermes -c proton-bridge -- touch /root/.setup-done
   ```
6. From your own account, start a DM with the bot and verify its `hermes` device if your client
   asks.

If encryption breaks, get a new token (new device) and delete
`/srv/app-storage/hermes/platforms/matrix/store/crypto.db`.

`hermes` drops to the `hermes` user on its own; anything else run via `exec` must use
`s6-setuidgid` or it writes root-owned files into `/opt/data`.

Turn off **extra usage** at claude.ai/settings/usage, otherwise overflow bills pay-as-you-go.

## Voice notes

Local faster-whisper, `stt.local.model: small.en`, English only, unloaded after 300s idle.
Enabled with `hermes tools enable stt --platform matrix` + `hermes config set stt.provider local`.
faster-whisper sits in the pm environment under `/opt/data/installs` (picked at boot, so a
restart is needed after it first installs); model cache via `HF_HOME`. On this i5-3470 an
11s clip takes ~9s once the model is loaded, container hit ~1.3Gi during that test.

## Semantic index

Hermes built its own search index (`/opt/data/scripts/semindex.py`, fastembed with
`multilingual-e5-large`) over the vault and chats, stored in `/opt/data/index`. The model is 2.1GB
on disk and loading it OOM-killed the container at the old 2Gi limit, hence 4Gi. The model cache
`index/models` is excluded from borgmatic (re-downloads on first use).

## Obsidian vault

Hermes has its own read-write copy at `/opt/data/vault` (`OBSIDIAN_VAULT_PATH`, used by the
bundled `obsidian` skill), kept in sync by the `syncthing` sidecar. The sidecar runs as uid 10000
so the files belong to hermes, and peers only with `utilities/syncthing` through the
`hermes-syncthing` Service (global/local discovery, relays and NAT off). Edits arrive on the
other side in ~15s. The vault is backed up by borgmatic with the rest of `/opt/data`, plus hourly
git commits on the Syncthing side.

Sidecar config and identity live in `/opt/data/syncthing` (device `L5SNWSI-…`, name `hermes`).
GUI/API on `127.0.0.1:8384`, only from inside the pod. Its CLI needs the API key passed in:

```bash
kubectl -n ai exec deploy/hermes -c syncthing -- sh -c 'K=$(grep -o "<apikey>[^<]*" /var/syncthing/config/config.xml | cut -d">" -f2); syncthing cli --gui-address=127.0.0.1:8384 --gui-apikey="$K" show connections'
```

Don't use a hostPath mount of `/srv/app-storage/syncthing/data` instead: those files are uid 1000,
and the Syncthing pod reads that directory over NFS from another node, so it never gets inotify
events for writes made on `cyl-homelab` and only sees them at the hourly rescan.

## Proton Mail Bridge

Official Proton `.deb` on stock Debian, installed at every container start and checked against
`BRIDGE_SHA256` (verified against Proton's signing key `D51E64D3E63EDC3EEF7864CEE2C75D68E6234B07`).
Listens on `127.0.0.1:1143` (IMAP) / `:1025` (SMTP) inside the pod only. Its vault and keyring live
in `/srv/app-storage/hermes-bridge`, which Hermes doesn't mount and borg doesn't back up (re-login
instead). Hermes reads mail with the bundled `himalaya` skill and is told not to send or modify;
nothing enforces that.

`himalaya` (v2) lives in `/opt/data/.local/bin`, installed with the upstream `install.sh`
(`PREFIX=/opt/data/.local`, run as `hermes`). Config `/opt/data/.config/himalaya/config.toml`
is IMAP-only (`imap://127.0.0.1:1143`, `starttls = false`, cleartext stays inside the pod) with
the Bridge password from `info`; update it if `info` shows a different one after a re-login.
A second account `gmail` (`imap.gmail.com`, Google app password, also IMAP-only) sits beside it.
Google OAuth was skipped: Testing-mode refresh tokens expire after 7 days, and publishing needs a
homepage and privacy policy.

Bumping Bridge: new version + sha256 of the `.deb`, after `gpg --verify` against the `.sig`.

## Updating

`kubectl -n ai rollout restart deploy/hermes` pulls the latest image. The `claude` CLI does not
update with the image; rerun the `npm install` and `install.cjs` lines.

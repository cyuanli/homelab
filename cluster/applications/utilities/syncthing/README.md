# Syncthing

Obsidian vault hub. Folder `nl9kp-tdryv` at `/data`, **receive-only**: it still forwards changes
from any peer (including Hermes's edits) to the others, but changes made in `/data` itself (e.g. a
`git-init` re-clone) stay local and never get pushed to the devices. Shared with
`cyl-milano-cachyos`, `cyl-milano-win11`, `cyl-s24` and `hermes` (the sidecar in `ai/hermes`,
dialled at `tcp://hermes-syncthing.ai.svc.cluster.local:22000`). This instance's own device name is
`cyl-homelab`, but it isn't pinned to that node.

Data and config are NFS PVs from `cyl-homelab` (`/srv/app-storage/syncthing/{data,config}`), so the
pod can run on any node. `.stignore` skips `.git` and `.obsidian/workspace*`.

The `git-sidecar` container commits and pushes `/data` to GitHub every hour (remote in
`secrets.yaml`, see the template). The `git-init` init container clones it into an empty volume.

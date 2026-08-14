# proxmox-masqueradarr

One-command install (and update) of [masqueradarr](https://github.com/TheBinaryNinja/masqueradarr) in a
Proxmox VE LXC container.

The script runs the `iflip721/masqueradarr-aio` "all-in-one" Docker image, which already bundles
the app, MongoDB, the Rust video sidecar, and the headful-Chromium login flow. So all this script
has to do is:

1. Create a Debian LXC with Docker nesting enabled.
2. Install Docker Engine inside it.
3. `docker run` the AIO image.

Re-running the script against an existing install switches to **update mode**
(`docker pull` + recreate), preserving all state.

## Requirements

- A Proxmox VE host, run as `root`.
- Host CPU with **AVX** support. MongoDB 5.0+ will `SIGILL` ("Illegal instruction") without it —
  this includes guests using the `kvm64`/`qemu64` CPU type. The script checks for this up front
  and refuses to continue if it's missing.

## Usage

Run directly from the Proxmox host shell:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/chrsi/proxmox-masqueradarr/main/masqueradarr.sh)"
```

Or clone and run locally:

```bash
git clone https://github.com/chrsi/proxmox-masqueradarr.git
cd proxmox-masqueradarr
./masqueradarr.sh
```

Re-run the exact same command any time to update — it detects the existing container by
hostname and pulls + recreates only if a newer image is actually available.

## Configuration

Everything is auto-detected on a fresh install (next free CTID, a storage with `rootdir`
content, a storage with `vztmpl` content, the newest matching Debian 13 template for the
host architecture), but every setting can be overridden via environment variables:

| Variable          | Default                    | Description                                   |
|-------------------|-----------------------------|------------------------------------------------|
| `CTID`            | next free ID                | Container ID to create or update              |
| `CT_HOSTNAME`     | `masqueradarr`              | Container hostname (used to find existing installs) |
| `CORES`           | `2`                          | vCPUs                                          |
| `RAM`             | `4096`                       | Memory (MB)                                    |
| `DISK`            | `16`                         | Rootfs size (GB)                               |
| `BRIDGE`          | `vmbr0`                      | Network bridge                                 |
| `STORAGE`         | auto-detected                | Storage for the container rootfs               |
| `TEMPLATE_STORAGE`| auto-detected                | Storage for the LXC template                   |
| `PORT`            | `3000`                       | Host port mapped to the app's port 3000        |
| `TAG`             | `latest`                     | Image tag to pull                              |
| `IMAGE`           | `iflip721/masqueradarr-aio`  | Docker image                                   |
| `MONGO_ROOT_USER` | —                            | Passed through to the container as an env var  |
| `MONGO_ROOT_PASS` | —                            | Passed through to the container as an env var  |
| `MONGO_CACHE_GB`  | —                            | Passed through to the container as an env var  |
| `LOG_LEVEL`       | —                            | Passed through to the container as an env var  |

Example — pin the CTID and port:

```bash
CTID=105 PORT=3010 ./masqueradarr.sh
```

## What it does

**Fresh install:**

- Creates an unprivileged Debian 13 LXC with `nesting=1,keyctl=1` (the minimum needed to run
  Docker inside a container, without going privileged or using a full VM).
- Waits for network/DNS inside the container, then updates packages.
- Installs Docker Engine from Docker's official apt repo (not Debian's packaged version).
- Creates a named `masqueradarr-data` volume and starts the container.

**Update (re-running against an existing install):**

- Upgrades guest OS packages and the Docker Engine packages.
- Pulls the configured image tag; if the image ID hasn't changed, it stops here.
- Otherwise stops/removes the old container and recreates it with the same volume, so
  state is preserved.

**Both paths finish by:**

- Waiting for the container's Docker healthcheck to report `healthy`.
- Printing the container's IP and the URL to open, e.g. `http://<ip>:3000`.

## Notes

- Output uses `msg_info`/`msg_ok`/`msg_error` helpers in the style of the
  [community-scripts](https://github.com/community-scripts/ProxmoxVE) project, with colour only
  when attached to a TTY — so piping through `curl | bash` stays readable.
- If you hit the AVX/MongoDB issue and can't change the host's CPU type, note that only a
  compose stack using `image: mongo:4.4` avoids the AVX requirement — there's no published
  `mongo4.4-*` tag for the AIO image itself.

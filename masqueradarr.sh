#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# masqueradarr.sh — one-command install/update of masqueradarr in a Proxmox LXC.
#
# Runs the "all-in-one" Docker image (iflip721/masqueradarr) inside a Debian LXC
# with nesting enabled. The AIO image bundles the app, MongoDB, the Rust video
# sidecar and the headful-Chromium login flow, so this script only needs to:
# create the container, install Docker in it, and `docker run` the image.
#
# Usage (as root, on the Proxmox host):
#   bash -c "$(curl -fsSL <url>/masqueradarr.sh)"
#   ./masqueradarr.sh
#
# Re-running this script against an existing install switches to update mode:
# docker pull + recreate, preserving all state (the masqueradarr-data volume).
#
# Overridable via env: CTID CT_HOSTNAME CORES RAM DISK BRIDGE STORAGE PORT TAG
#                       IMAGE MONGO_ROOT_USER MONGO_ROOT_PASS MONGO_CACHE_GB
#                       LOG_LEVEL
# -----------------------------------------------------------------------------
set -euo pipefail

CT_HOSTNAME="${CT_HOSTNAME:-masqueradarr}"
CORES="${CORES:-2}"
RAM="${RAM:-4096}"
DISK="${DISK:-16}"
BRIDGE="${BRIDGE:-vmbr0}"
PORT="${PORT:-3000}"
TAG="${TAG:-latest}"
IMAGE="${IMAGE:-iflip721/masqueradarr-aio}"
TEMPLATE_OS="debian-13-standard"

# ---- output helpers (community-scripts-style msg_info/msg_ok/msg_error) ----
if [[ -t 2 ]]; then
  CL='\033[m'; RD='\033[01;31m'; GN='\033[1;92m'; YW='\033[33m'
else
  CL=''; RD=''; GN=''; YW=''
fi
msg_info()  { printf "%b %s...\n"  "${YW}[i]${CL}" "$1" >&2; }
msg_ok()    { printf "%b %s\n"     "${GN}[+]${CL}" "$1" >&2; }
msg_error() { printf "%b %s\n"     "${RD}[!]${CL}" "$1" >&2; }
die()       { msg_error "$1"; exit 1; }

# =============================================================================
# Phase 0 — preflight
# =============================================================================
[[ $EUID -eq 0 ]] || die "Run as root on the Proxmox host."
command -v pveversion >/dev/null 2>&1 || die "pveversion not found — this must run on a Proxmox VE host."
command -v pct >/dev/null 2>&1 || die "pct not found — this must run on a Proxmox VE host."

msg_info "Checking host CPU for AVX (required by MongoDB 5.0+)"
if ! grep -qm1 avx /proc/cpuinfo; then
  die "Host CPU has no AVX flag. mongod 5.0+ will SIGILL (\"Illegal instruction\") on this
    hardware or on a guest CPU type of kvm64/qemu64. Fix: set the container's CPU type to
    'host' (pct set <CTID> -cpuunits ... ; edit /etc/pve/lxc/<CTID>.conf -> 'features: ...'
    is unrelated — set 'arch'/'ostype' as usual and ensure the node's physical CPU has AVX;
    there is no published mongo4.4-* tag for this image to fall back to, only the compose
    stack with 'image: mongo:4.4' avoids the AVX requirement)."
fi
msg_ok "AVX present"

# Find an existing install by hostname.
EXISTING_CTID=""
while read -r id; do
  if pct config "$id" 2>/dev/null | grep -Fqx "hostname: ${CT_HOSTNAME}"; then
    EXISTING_CTID="$id"
    break
  fi
done < <(pct list | awk 'NR>1{print $1}')

# =============================================================================
# Update path — re-running against an existing install
# =============================================================================
if [[ -n "${EXISTING_CTID:-}" ]]; then
  CTID="$EXISTING_CTID"
  msg_info "Existing install found (CTID $CTID) — switching to update mode"

  msg_info "Updating guest OS packages"
  pct exec "$CTID" -- bash -c "apt-get update -qq && apt-get upgrade -y -qq" \
    || msg_error "apt upgrade failed — continuing anyway"
  msg_ok "Guest OS packages updated"

  msg_info "Refreshing Docker Engine packages"
  pct exec "$CTID" -- bash -c "apt-get install -y -qq --only-upgrade docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin" \
    || msg_error "Docker package refresh failed — continuing anyway"
  msg_ok "Docker Engine refreshed"

  msg_info "Pulling ${IMAGE}:${TAG}"
  OLD_ID="$(pct exec "$CTID" -- docker inspect --format '{{.Image}}' masqueradarr 2>/dev/null || echo '')"
  pct exec "$CTID" -- docker pull "${IMAGE}:${TAG}"
  NEW_ID="$(pct exec "$CTID" -- docker inspect --format '{{.Id}}' "${IMAGE}:${TAG}")"
  msg_ok "Pulled ${IMAGE}:${TAG}"

  if [[ -n "$OLD_ID" && "$OLD_ID" == "$NEW_ID" ]]; then
    msg_ok "Already running the latest image — no recreate needed"
  else
    msg_info "Recreating container (state preserved in the masqueradarr-data volume)"
    pct exec "$CTID" -- bash -c "docker stop masqueradarr && docker rm masqueradarr" || true
    pct exec "$CTID" -- docker run -d --name masqueradarr \
      --restart unless-stopped \
      -p "${PORT}:3000" \
      -v masqueradarr-data:/data \
      ${MONGO_ROOT_USER:+-e MONGO_ROOT_USER="$MONGO_ROOT_USER"} \
      ${MONGO_ROOT_PASS:+-e MONGO_ROOT_PASS="$MONGO_ROOT_PASS"} \
      ${MONGO_CACHE_GB:+-e MONGO_CACHE_GB="$MONGO_CACHE_GB"} \
      ${LOG_LEVEL:+-e LOG_LEVEL="$LOG_LEVEL"} \
      "${IMAGE}:${TAG}"
    pct exec "$CTID" -- docker image prune -f >/dev/null || true
    msg_ok "Container recreated"
  fi
else
  # ===========================================================================
  # Fresh install
  # ===========================================================================
  # Pick the next free CTID unless caller pinned one.
  CTID="${CTID:-$(pvesh get /cluster/nextid)}"

  # Pick a storage that can hold a container rootfs, unless caller pinned one.
  if [[ -z "${STORAGE:-}" ]]; then
    STORAGE="$(pvesm status -content rootdir | awk 'NR>1{print $1; exit}')"
    [[ -n "$STORAGE" ]] || die "No storage with 'rootdir' content found — set STORAGE=<name>."
  fi

  # Pick a storage that can hold the LXC template, unless caller pinned one.
  TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-}"
  if [[ -z "$TEMPLATE_STORAGE" ]]; then
    TEMPLATE_STORAGE="$(pvesm status -content vztmpl | awk 'NR>1{print $1; exit}')"
    [[ -n "$TEMPLATE_STORAGE" ]] || die "No storage with 'vztmpl' content found — set TEMPLATE_STORAGE=<name>."
  fi

  msg_info "Refreshing available LXC templates"
  pveam update >/dev/null 2>&1 || true
  msg_ok "Template list refreshed"

  HOST_ARCH="$(dpkg --print-architecture)"
  TEMPLATE="$(pveam available -section system 2>/dev/null \
    | awk -v t="$TEMPLATE_OS" '$2 ~ t {print $2}' \
    | grep -E "_${HOST_ARCH}\.tar\." \
    | sort -V | tail -1)"
  [[ -n "$TEMPLATE" ]] || die "Could not find a ${TEMPLATE_OS} template for arch ${HOST_ARCH} in 'pveam available'."

  if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE"; then
    msg_info "Downloading template $TEMPLATE"
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
    msg_ok "Template downloaded"
  else
    msg_ok "Template $TEMPLATE already present"
  fi

  msg_info "Creating LXC $CTID ($CT_HOSTNAME)"
  pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CORES" \
    --memory "$RAM" \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},firewall=1,ip=dhcp" \
    --unprivileged 1 \
    --features "nesting=1,keyctl=1" \
    --onboot 1 \
    >/dev/null
  msg_ok "LXC $CTID created"

  msg_info "Starting LXC $CTID"
  pct start "$CTID"
  msg_ok "LXC started"

  msg_info "Waiting for network inside the container"
  for _ in $(seq 1 60); do
    pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 && break
    sleep 2
  done
  pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1 \
    || die "Container has no working network/DNS after 120s."
  msg_ok "Network is up"

  msg_info "Updating guest OS packages"
  pct exec "$CTID" -- bash -c "apt-get update -qq && apt-get upgrade -y -qq && apt-get install -y -qq ca-certificates curl"
  msg_ok "Guest OS packages installed"

  msg_info "Installing Docker Engine (official repo)"
  pct exec "$CTID" -- bash -c '
    set -e
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    mkdir -p /etc/docker
    [ -f /etc/docker/daemon.json ] || printf "{\n  \"log-driver\": \"journald\"\n}\n" > /etc/docker/daemon.json
    systemctl enable --now docker
  '
  msg_ok "Docker Engine installed and running"

  msg_info "Launching masqueradarr (${IMAGE}:${TAG})"
  pct exec "$CTID" -- docker volume create masqueradarr-data >/dev/null
  pct exec "$CTID" -- docker run -d --name masqueradarr \
    --restart unless-stopped \
    -p "${PORT}:3000" \
    -v masqueradarr-data:/data \
    ${MONGO_ROOT_USER:+-e MONGO_ROOT_USER="$MONGO_ROOT_USER"} \
    ${MONGO_ROOT_PASS:+-e MONGO_ROOT_PASS="$MONGO_ROOT_PASS"} \
    ${MONGO_CACHE_GB:+-e MONGO_CACHE_GB="$MONGO_CACHE_GB"} \
    ${LOG_LEVEL:+-e LOG_LEVEL="$LOG_LEVEL"} \
    "${IMAGE}:${TAG}" >/dev/null
  msg_ok "Container started"
fi

# =============================================================================
# Wait for health, then report
# =============================================================================
msg_info "Waiting for masqueradarr to become healthy (mongod init can take a while)"
HEALTHY=0
for _ in $(seq 1 90); do
  STATUS="$(pct exec "$CTID" -- docker inspect --format '{{.State.Health.Status}}' masqueradarr 2>/dev/null || echo starting)"
  [[ "$STATUS" == "healthy" ]] && { HEALTHY=1; break; }
  sleep 2
done
if [[ "$HEALTHY" -eq 1 ]]; then
  msg_ok "masqueradarr is healthy"
else
  msg_error "masqueradarr did not report healthy in time — check: pct exec $CTID -- docker logs masqueradarr"
fi

IP=""
for _ in $(seq 1 30); do
  IP="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -n "$IP" ]] && break
  sleep 2
done

echo
msg_ok "Done."
if [[ -n "$IP" ]]; then
  echo -e "  ${GN}http://${IP}:${PORT}${CL}"
else
  echo "  Could not detect the container IP — run 'pct exec $CTID -- hostname -I'."
fi
echo "  Re-run this script at any time to update (docker pull + recreate; state is preserved)."

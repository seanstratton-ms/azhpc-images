#!/bin/bash
set -ex

# Configure NVIDIA persistence daemon to keep the GPU driver loaded in memory
# This eliminates cold start delays when launching GPU applications

# On Debian, also enable UVM persistence so the /dev/nvidia-uvm and
# /dev/nvidia-uvm-tools device nodes are created at boot (as root). Without it,
# those nodes are only created lazily on the first CUDA init by root/setuid
# nvidia-modprobe, so a NON-ROOT cuInit() (e.g. the image sanity gdrcopy/osu
# tests run as hpcuser over pdsh) returns CUDA_ERROR_NO_DEVICE even though the
# driver, NVML (nvidia-smi) and Fabric Manager are all healthy (validation
# 34252: root aznhc gpu-burn passed while non-root gdrcopy_sanity got
# NO_DEVICE in the same run). Other distros already create these nodes and are
# left unchanged to avoid regressing working images.
PERSISTENCED_EXTRA_FLAGS=""
if [[ "${DISTRIBUTION:-}" == *"debian"* ]]; then
    PERSISTENCED_EXTRA_FLAGS=" --uvm-persistence-mode"
fi

# Create systemd service file if it doesn't exist
if [ ! -f /etc/systemd/system/nvidia-persistenced.service ]; then
    cat <<EOF > /etc/systemd/system/nvidia-persistenced.service
[Unit]
Description=NVIDIA Persistence Daemon
Wants=syslog.target
 
[Service]
Type=forking
PIDFile=/var/run/nvidia-persistenced/nvidia-persistenced.pid
Restart=always
ExecStart=/usr/bin/nvidia-persistenced --verbose --persistence-mode${PERSISTENCED_EXTRA_FLAGS}
ExecStopPost=/bin/rm -rf /var/run/nvidia-persistenced
 
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
fi

# Enable unconditionally so first-boot activation works whether the unit was
# written by this script or shipped by a distro driver package.
systemctl enable nvidia-persistenced.service

# Do NOT start/restart nvidia-persistenced at build time. The daemon attaches
# to /dev/nvidia* and exits non-zero if no GPU is present, which breaks builds
# on general-purpose build SKUs (build_vm_size != vm_size). The unit is
# enabled above and Restart=always in its [Service] section, so it will come
# up cleanly on first boot on the customer VM. Activation is verified after
# reboot by `verify_nvidia_persistenced_service` in tests/test-definitions.sh
# (gated on actual NVIDIA GPU presence).

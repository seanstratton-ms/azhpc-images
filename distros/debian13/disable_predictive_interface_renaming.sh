#!/bin/bash
set -e

# Kernel parameter to disable predictive network interface naming
KERNEL_PARAMETER="net.ifnames=0"

# On Debian 13 (unlike the Ubuntu Azure images) there is no
# /etc/default/grub.d/50-cloudimg-settings.cfg, so editing that file fails
# with "No such file or directory". Debian's update-grub sources
# /etc/default/grub followed by every /etc/default/grub.d/*.cfg drop-in, so we
# write a dedicated drop-in that appends net.ifnames=0 (plus the serial/console
# args the Ubuntu path also set) to the kernel command line. This is idempotent
# (the file is overwritten on every run) and independent of the base image's
# existing grub configuration.
GRUB_DROPIN_DIR="/etc/default/grub.d"
GRUB_DROPIN_FILE="${GRUB_DROPIN_DIR}/99-azhpc-net-ifnames.cfg"

mkdir -p "${GRUB_DROPIN_DIR}"
cat > "${GRUB_DROPIN_FILE}" <<EOF
# Managed by azhpc-images: disable predictive network interface naming
GRUB_CMDLINE_LINUX="\${GRUB_CMDLINE_LINUX} console=tty1 console=ttyS0 earlyprintk=ttyS0 ${KERNEL_PARAMETER}"
EOF

# Generate grub file with updated parameters
update-grub

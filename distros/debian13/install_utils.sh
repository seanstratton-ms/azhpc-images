#!/bin/bash
set -ex

export DEBIAN_FRONTEND=noninteractive

# Install the "Microsoft TLS RSA Root G2" trust anchor before any HTTPS
# calls to Microsoft endpoints.

if [[ $DISTRIBUTION != *"debian"* ]]; then
    $COMPONENT_DIR/install_microsoft_tls_root_g2.sh
else
    echo "Skipping Microsoft TLS root install on Debian"
fi

# Setup microsoft packages repository
if [[ $DISTRIBUTION != *"debian"* ]]; then
    curl -sSL -O https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb
else
    curl -sSL -O https://packages.microsoft.com/config/debian/13/packages-microsoft-prod.deb
fi
dpkg -i packages-microsoft-prod.deb
rm packages-microsoft-prod.deb

apt-get update
apt-get -y install build-essential
apt-get -y install numactl \
                   rpm \
                   libnuma-dev \
                   libmpc-dev \
                   libmpfr-dev \
                   libxml2-dev \
                   m4 \
                   byacc \
                   tcl \
                   environment-modules \
                   tk \
                   texinfo \
                   libudev-dev \
                   binutils \
                   binutils-dev \
                   selinux-policy-dev \
                   flex \
                   libnl-3-dev \
                   libnl-route-3-dev \
                   libnl-3-200 \
                   libnl-genl-3-dev \
                   libnl-genl-3-200 \
                   bison \
                   libnl-route-3-200 \
                   gfortran \
                   cmake \
                   libnl-3-dev \
                   libnl-route-3-dev \
                   net-tools \
                   libsecret-1-0 \
                   python3 \
                   python3-pip \
                   python3-setuptools \
                   dkms \
                   jq \
                   curl \
                   libyaml-dev \
                   libreadline-dev \
                   libkeyutils1 \
                   libkeyutils-dev \
                   libmount-dev \
                   nfs-common \
                   pssh \
                   dos2unix

# Install azcopy from official tarball (not in MS debian/13 apt repo)
AZCOPY_TMP=$(mktemp -d)
curl -sSL -o "$AZCOPY_TMP/azcopy.tar.gz" https://aka.ms/downloadazcopy-v10-linux
tar -xzf "$AZCOPY_TMP/azcopy.tar.gz" -C "$AZCOPY_TMP" --strip-components=1
install -m 0755 "$AZCOPY_TMP/azcopy" /usr/local/bin/azcopy
rm -rf "$AZCOPY_TMP"

# Load ib_ipoib on Azure VM builds; skip on baremetal (IPoIB is not used).
if [[ "${NODE_TYPE:-azure-vm}" != "baremetal" ]]; then
    echo ib_ipoib | sudo tee /etc/modules-load.d/ib_ipoib.conf
fi
echo ib_umad | sudo tee /etc/modules-load.d/ib_umad.conf

# copy kvp client file
$COMPONENT_DIR/copy_kvp_client.sh

# copy torset tool
$COMPONENT_DIR/copy_torset_tool.sh

# Set default shell for newly created users (somehow bash is no longer the default in Canonical's Noble image for Azure)
sed -i 's|^SHELL=.*|SHELL=/bin/bash|' /etc/default/useradd
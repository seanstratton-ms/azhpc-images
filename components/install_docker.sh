#!/bin/bash
set -ex

source ${UTILS_DIR}/utilities.sh

# Install Moby Engine and CLI
if [[ $DISTRIBUTION == *"debian"* ]]; then
    # Microsoft's PMC (packages.microsoft.com/debian/13/prod/trixie) does
    # not currently publish moby-* packages — only the Ubuntu PMC does.
    # Use upstream Docker CE from download.docker.com/linux/debian, which
    # is well-maintained for trixie and ships the same binaries
    # (/usr/bin/docker, /usr/bin/dockerd) that moby provides. Swap back
    # to apt-get install -y moby-engine once MS publishes moby-* for
    # debian/13/prod. Tracked as Task 393 follow-up.
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
elif [[ $DISTRIBUTION == *"ubuntu"* ]]; then
    if [[ "$ARCHITECTURE" == "aarch64" && "${NODE_TYPE:-azure-vm}" == "baremetal" ]]; then
        # Baremetal aarch64: pin to a specific moby version from the baremetal package repo.
        moby_metadata=$(get_component_config "moby")
        MOBY_VERSION=$(jq -r '.version' <<< $moby_metadata)
        apt-get install -y moby-engine=${MOBY_VERSION}
        apt-get install -y moby-cli=${MOBY_VERSION}
    else
        apt-get install -y moby-engine
        apt-get install -y moby-cli
        apt-get install -y moby-buildx
    fi
elif [[ $DISTRIBUTION == "azurelinux3.0" ]]; then
    tdnf install -y moby-engine
    tdnf install -y moby-cli
    tdnf install -y docker-buildx
else
    # RHEL-family: AlmaLinux, Rocky Linux, RHEL, etc.
    # NOTE: on el8 the MS repo is marked with `module_hotfixes=1` by the
    # distro setup script ([distros/almalinux8.10/install_utils.sh] and
    # [distros/rocky8.10/install_utils.sh]). That bypasses dnf modular
    # filtering for moby-runc (which `Provides: runc`, a name claimed by
    # the AppStream `container-tools` module) without disabling the module.
    yum install -y moby-engine
    yum install -y moby-cli
    yum install -y moby-buildx
fi

$COMPONENT_DIR/install_nvidia_container_toolkit.sh

# enable and restart the docker daemon to complete the installation
systemctl enable docker
systemctl restart docker

# restart containerd service and wait for socket to be ready
systemctl restart containerd
for i in $(seq 1 30); do
    if [ -S /run/containerd/containerd.sock ]; then
        break
    fi
    echo "Waiting for containerd socket... ($i/30)"
    sleep 1
done

# status of containerd snapshotter plugins
ctr plugin ls

# Write the docker version to components file
docker_version=$(docker --version | awk -F' ' '{print $3}')
write_component_version "DOCKER" ${docker_version::-1}

if [[ $DISTRIBUTION == *"debian"* ]]; then
    # docker-ce instead of moby-engine on debian (see top of file).
    moby_version=$(apt list --installed 2>/dev/null | grep '^docker-ce/' | awk -F' ' '{print $2}')
elif [[ $DISTRIBUTION == ubuntu* ]]; then
    moby_version=$(apt list --installed | grep moby-engine | awk -F' ' '{print $2}')
elif [[ $DISTRIBUTION == "azurelinux3.0" ]]; then
    moby_version=$(rpm -qa | grep moby | cut -d'-' -f3,4)
else
    # RHEL-family: AlmaLinux, Rocky Linux, RHEL, etc.
    moby_version=$(yum list installed | grep moby-engine | awk -F' ' '{print $2}')
fi
write_component_version "MOBY_ENGINE" ${moby_version}

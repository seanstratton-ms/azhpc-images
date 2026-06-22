#!/bin/bash
set -ex

source ${UTILS_DIR}/utilities.sh

nvidia_metadata=$(get_component_config "nvidia")

if [[ $DISTRIBUTION == *"ubuntu"* || $DISTRIBUTION == *"debian"* ]]; then
    # Install from NVIDIA APT repo (already configured during driver installation)
    NVIDIA_DRIVER_VERSION=$(jq -r '.driver.version' <<< $nvidia_metadata)
    NVIDIA_DRIVER_MAJOR=$(echo $NVIDIA_DRIVER_VERSION | cut -d '.' -f1)

    if [[ $NVIDIA_DRIVER_MAJOR -ge 580 ]]; then
        PACKAGE_NAME="nvidia-fabricmanager"
    else
        PACKAGE_NAME="nvidia-fabricmanager-${NVIDIA_DRIVER_MAJOR}"
    fi

    # Fabric Manager must match the installed NVIDIA kernel driver EXACTLY, or
    # nv-fabricmanager fails with "failed to allocate handle (client) to NVIDIA
    # GPU driver" (build 33208) or "driver interface version X don't match with
    # driver version Y" (hpc-image-val2 build 33746).
    #
    # On Debian we pin FM to the ACTUALLY INSTALLED driver, not the metadata
    # version: `apt install nvidia-open=<metadata>-1` only pins the (tiny)
    # nvidia-open META-package; its dependency nvidia-kernel-open-dkms (the real
    # kernel driver) is unpinned and apt resolves it to the newest patch in the
    # 590 series (e.g. metadata says 590.44.01 but the loaded driver — and the
    # consistent userspace libs that nvidia-smi reports — are 590.48.01).
    # Deriving the FM pin from stale metadata produced FM 590.44.01 against a
    # 590.48.01 driver. Read the installed driver back from dpkg so FM always
    # tracks whatever the driver actually resolved to.
    if [[ $DISTRIBUTION == *"debian"* ]]; then
        # Prefer the installed open kernel module's upstream version; fall back
        # to the proprietary kmod package, then to metadata as a last resort.
        INSTALLED_DRIVER_VERSION=""
        for _drv_pkg in nvidia-kernel-open-dkms nvidia-kernel-dkms nvidia-open; do
            _v=$(dpkg-query -W -f='${Version}' "${_drv_pkg}" 2>/dev/null | sed -E 's/-[^-]*$//')
            if [[ -n "${_v}" ]]; then
                INSTALLED_DRIVER_VERSION="${_v}"
                echo "Detected installed NVIDIA driver ${INSTALLED_DRIVER_VERSION} (from ${_drv_pkg})"
                break
            fi
        done
        DRIVER_VERSION_FOR_FM="${INSTALLED_DRIVER_VERSION:-${NVIDIA_DRIVER_VERSION}}"

        # Resolve the exact apt candidate whose upstream version matches the
        # installed driver (deb revisions may differ, e.g. -1 vs -2).
        FM_PINNED_VERSION=$(apt-cache madison ${PACKAGE_NAME} 2>/dev/null \
            | awk '{print $3}' | grep -E "^${DRIVER_VERSION_FOR_FM}-" | head -1)
        if [[ -n "${FM_PINNED_VERSION}" ]]; then
            echo "Pinning ${PACKAGE_NAME} to ${FM_PINNED_VERSION} to match installed driver ${DRIVER_VERSION_FOR_FM}"
            apt install -y --allow-downgrades ${PACKAGE_NAME}=${FM_PINNED_VERSION}
        else
            echo "##[error]No ${PACKAGE_NAME} build matching installed driver ${DRIVER_VERSION_FOR_FM} in apt repo; refusing to install a mismatched Fabric Manager"
            apt-cache madison ${PACKAGE_NAME} 2>/dev/null || true
            exit 1
        fi
    else
        apt install -y ${PACKAGE_NAME}
    fi

    # Read back installed version for the component manifest
    NVIDIA_FABRICMANAGER_VERSION=$(dpkg-query -W -f='${Version}' ${PACKAGE_NAME})
elif [[ $DISTRIBUTION == "azurelinux3.0" ]]; then
    # The NVIDIA CUDA repo (cuda-azl3) ships nvidia-fabricmanager and
    # libnvidia-nscq packages that Provide/Obsolete the identically-named PMC
    # packages, often at a newer version than the Microsoft 1P-signed driver
    # installed from PMC.  The driver kmod and fabric manager versions must
    # match exactly, so exclude the CUDA repo copies and let tdnf resolve to
    # the PMC-sourced packages whose versions track the 1P-signed driver.
    echo "exclude=nvidia-fabricmanager* nvidia-fabric-manager* libnvidia-nscq*" >> /etc/yum.repos.d/cuda-azl3.repo

    # tdnf does not respect exclude= directive of repo config
    dnf install -y nvidia-fabric-manager \
                   nvidia-fabric-manager-devel \
                   libnvidia-nscq
    NVIDIA_FABRICMANAGER_VERSION=$(sudo tdnf list installed | grep -i nvidia-fabric-manager.x86_64 | sed 's/.*[[:space:]]\([0-9.]*-[0-9]*\)\..*/\1/')
else
    # RHEL-family: AlmaLinux, Rocky Linux, RHEL, etc.
    nvidia_fabricmanager_metadata=$(jq -r '.fabricmanager' <<< $nvidia_metadata)
    NVIDIA_FABRICMANAGER_DISTRIBUTION=$(jq -r '.distribution' <<< $nvidia_fabricmanager_metadata)
    NVIDIA_FABRICMANAGER_VERSION=$(jq -r '.version' <<< $nvidia_fabricmanager_metadata)
    NVIDIA_FABRICMANAGER_SHA256=$(jq -r '.sha256' <<< $nvidia_fabricmanager_metadata)
    NVIDIA_FABRICMANAGER_PREFIX=$(echo $NVIDIA_FABRICMANAGER_VERSION | cut -d '.' -f1)

    # For NVIDIA Fabric Manager major version 580, Nvidia dropped the hyphen between fabric and manager
    if [[ $NVIDIA_FABRICMANAGER_PREFIX -ge 580 ]]; then
        PACKAGE_NAME="nvidia-fabricmanager"
    else
        PACKAGE_NAME="nvidia-fabric-manager"
    fi
    NVIDIA_FABRIC_MNGR_PKG=https://developer.download.nvidia.com/compute/cuda/repos/${NVIDIA_FABRICMANAGER_DISTRIBUTION}/x86_64/${PACKAGE_NAME}-${NVIDIA_FABRICMANAGER_VERSION}.x86_64.rpm
    FILENAME=$(basename $NVIDIA_FABRIC_MNGR_PKG)
    download_and_verify ${NVIDIA_FABRIC_MNGR_PKG} ${NVIDIA_FABRICMANAGER_SHA256}
    
    yum install -y ./${FILENAME}

    # Prevent package from being updated after installation
    dnf_pin_packages "${PACKAGE_NAME}"
fi
write_component_version "NVIDIA_FABRIC_MANAGER" ${NVIDIA_FABRICMANAGER_VERSION}

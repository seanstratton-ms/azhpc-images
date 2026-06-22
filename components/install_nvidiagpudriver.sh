#!/bin/bash
set -ex

source ${UTILS_DIR}/utilities.sh

# Install NVIDIA driver
nvidia_metadata=$(get_component_config "nvidia")
cuda_metadata=$(get_component_config "cuda")

if [[ $DISTRIBUTION == "azurelinux3.0" ]]; then
    if [ "$SKU" = "V100" ]; then
        # V100 requires proprietary kernel modules
        AL3_GPU_DRIVER_PACKAGES="cuda"
    elif [ "$ARCHITECTURE" = "aarch64" ]; then
        AL3_GPU_DRIVER_PACKAGES="cuda-open-hwe"
    else
        AL3_GPU_DRIVER_PACKAGES="cuda-open"
    fi

    if [[ "$ARCHITECTURE" == "aarch64" ]]; then
        curl https://packages.microsoft.com/azurelinux/3.0/prod/nvidia/aarch64/config.repo > /etc/yum.repos.d/azurelinux-nvidia-prod.repo
        curl https://developer.download.nvidia.com/compute/cuda/repos/azl3/sbsa/cuda-azl3.repo > /etc/yum.repos.d/cuda-azl3.repo
    else
        curl https://packages.microsoft.com/azurelinux/3.0/prod/nvidia/x86_64/config.repo > /etc/yum.repos.d/azurelinux-nvidia-prod.repo
        curl https://developer.download.nvidia.com/compute/cuda/repos/azl3/x86_64/cuda-azl3.repo > /etc/yum.repos.d/cuda-azl3.repo
    fi

    # Disable the NVIDIA CUDA repo during driver install — all driver
    # packages come from PMC and the CUDA repo has an identically-named
    # 'cuda' meta-package that would conflict.
    # Do not use this before bugfixed tdnf lands (https://github.com/vmware/tdnf/pull/553/commits/a418054b02c4cac787184f973dac4d6790344ef3)
    # or before switching to dnf
    # tdnf install -y --disablerepo=cuda-azl3* $AL3_GPU_DRIVER_PACKAGES
    tdnf install -y --disablerepo=cuda-azl3-x86_64 --disablerepo=cuda-azl3-sbsa $AL3_GPU_DRIVER_PACKAGES
    NVIDIA_DRIVER_VERSION=$(tdnf list installed | grep "^${AL3_GPU_DRIVER_PACKAGES}\." | sed 's/.*\s\+\([0-9.]\+-[0-9]\+\)_.*/\1/')

    # Temp disable NVIDIA driver updates
    mkdir -p /etc/tdnf/locks.d
    echo cuda >> /etc/tdnf/locks.d/nvidia.conf
elif [[ $DISTRIBUTION == *"ubuntu"* || $DISTRIBUTION == *"debian"* ]]; then
    # APT-based NVIDIA driver installation for Ubuntu / Debian
    NVIDIA_DRIVER_VERSION=$(jq -r '.driver.version' <<< $nvidia_metadata)
    CUDA_DRIVER_DISTRIBUTION=$(jq -r '.driver.distribution' <<< $cuda_metadata)

    # Add NVIDIA CUDA APT repo (provides both driver and toolkit packages)
    wget https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_DRIVER_DISTRIBUTION}/x86_64/cuda-keyring_1.1-1_all.deb
    dpkg -i ./cuda-keyring_1.1-1_all.deb
    apt-get update

    # Pin the ENTIRE NVIDIA driver closure to the metadata driver version on
    # Debian, not just the nvidia-open meta-package. `apt install
    # nvidia-open=<ver>-1` only constrains the (tiny) meta-package; its
    # dependencies (nvidia-kernel-open-dkms — the real kmod — plus
    # nvidia-driver*, libcuda1, libnvidia-*, firmware-nvidia-gsp) are loosely
    # versioned, so apt floats them to the newest patch in the major series.
    # That shipped driver 590.48.01 (whose user-mode stack only advertises
    # CUDA 13.1) against the image's CUDA 13.2.78 toolkit, so every CUDA app
    # failed at runtime with "the provided PTX was compiled with an unsupported
    # toolchain" (gpu-burn), NVBandwidth error 1, and NCCL all-reduce hangs
    # (hpc-image-val2 build 33765). Pin the whole closure to the matching
    # ${NVIDIA_DRIVER_VERSION} so the driver pairs with the CUDA toolkit.
    #
    # A version-glob pin is self-limiting: it only binds packages that actually
    # publish a ${NVIDIA_DRIVER_VERSION} build, so independently-versioned NVIDIA
    # packages (nvidia-container-toolkit, libnvidia-egl-wayland1,
    # nvidia-driver-pinning-590, etc.) are untouched.
    if [[ $DISTRIBUTION == *"debian"* ]]; then
        # Refuse to build a mismatched image: the exact driver build must exist
        # in the repo, or pinning would silently fall back to the floated patch.
        if ! apt-cache madison nvidia-kernel-open-dkms 2>/dev/null \
                | awk '{print $3}' | grep -qE "^${NVIDIA_DRIVER_VERSION}-"; then
            echo "##[error]No nvidia-kernel-open-dkms build matching driver ${NVIDIA_DRIVER_VERSION} in apt repo; refusing to pin a mismatched NVIDIA driver closure"
            apt-cache madison nvidia-kernel-open-dkms 2>/dev/null || true
            exit 1
        fi
        cat > /etc/apt/preferences.d/nvidia-driver-pin <<EOF
# Pin the NVIDIA driver closure to the metadata driver version so the kernel
# module + user-mode libraries match the image CUDA toolkit. Version-glob is
# self-limiting: only packages that publish ${NVIDIA_DRIVER_VERSION} are bound.
Package: nvidia-driver* nvidia-kernel-open-dkms nvidia-kernel-dkms nvidia-kernel-support nvidia-modprobe nvidia-persistenced nvidia-settings nvidia-xconfig nvidia-egl-icd nvidia-vulkan-icd nvidia-vdpau-driver nvidia-opencl-icd libnvidia-* libcuda1 libcudadebugger1 firmware-nvidia-gsp
Pin: version ${NVIDIA_DRIVER_VERSION}*
Pin-Priority: 1001
EOF
        echo "Pinned NVIDIA driver closure to ${NVIDIA_DRIVER_VERSION} via /etc/apt/preferences.d/nvidia-driver-pin"
    fi

    # Pin the driver version and install via APT packages.
    # Debian's NVIDIA repo only ships major-version pinning packages
    # (e.g. nvidia-driver-pinning-590) and not full-version variants
    # (nvidia-driver-pinning-590.44.01), so fall back to the major when
    # the full-version package is unavailable.
    NVIDIA_DRIVER_MAJOR_VERSION=$(jq -r '.driver.major_version // empty' <<< $nvidia_metadata)
    if [[ $DISTRIBUTION == *"debian"* && -n "${NVIDIA_DRIVER_MAJOR_VERSION}" ]]; then
        apt install nvidia-driver-pinning-${NVIDIA_DRIVER_MAJOR_VERSION} -y
    else
        apt install nvidia-driver-pinning-${NVIDIA_DRIVER_VERSION} -y
    fi
    if [ "$SKU" = "V100" ]; then
        # V100 requires proprietary kernel modules
        apt install cuda-drivers -y
    elif [[ $DISTRIBUTION == *"debian"* ]]; then
        # Pin the specific driver version on Debian since we install by
        # major-version repo metadata. The preferences.d pin above forces the
        # whole dependency closure to the same ${NVIDIA_DRIVER_VERSION}.
        apt install -y --allow-downgrades nvidia-open=${NVIDIA_DRIVER_VERSION}-1
    else
        # A100, H100, H200 use open kernel modules
        apt install nvidia-open -y
    fi

    # Remove unused configuration file if created by the NVIDIA driver package
    rm -f /etc/modprobe.d/nvidia-graphics-drivers-kms.conf

    # --- Debian build/boot kernel reconciliation -------------------------------
    # The image-build VM never reboots, so nvidia-open's DKMS module is built
    # against the *running* kernel ($(uname -r)). But earlier build steps install
    # a NEWER kernel that becomes the GRUB default and is what the captured image
    # actually boots:
    #   * `apt-get upgrade` (set_properties.sh) bumps linux-image-cloud-amd64, and
    #   * `doca-ofed` Depends on the generic linux-headers-amd64 meta, dragging in
    #     linux-image-<newer>-amd64.
    # The shipped image then boots a kernel with no nvidia.ko, so at runtime
    # `nvidia-smi` reports "couldn't communicate with the NVIDIA driver" and every
    # GPU check (Fabric Manager, gpu-burn, DCGM) fails — hpc-image-val2 build 33701.
    # Ubuntu is unaffected because it holds linux-azure-<ver> so running == shipped.
    # Rebuild + install the nvidia DKMS module(s) for the newest installed kernel
    # (the one GRUB boots). We target nvidia specifically (not `dkms autoinstall`)
    # so a pre-existing OFED DKMS state (e.g. knem "already installed") cannot
    # prevent nvidia.ko from being produced for the shipped kernel.
    if [[ $DISTRIBUTION == *"debian"* ]]; then
        run_kernel="$(uname -r)"
        boot_kernel="$(ls -1 /lib/modules 2>/dev/null | sort -V | tail -1)"
        if [[ -n "$boot_kernel" && "$boot_kernel" != "$run_kernel" ]]; then
            echo "NVIDIA DKMS built for running kernel ${run_kernel}; rebuilding for image boot kernel ${boot_kernel}"
            apt-get install -y "linux-headers-${boot_kernel}" || true
            dkms status 2>/dev/null | grep -iE '(^| )nvidia' | while IFS= read -r _nv_line; do
                _nv_mod="$(sed -E 's#^([^/,]+)[/,].*#\1#' <<< "$_nv_line")"
                _nv_ver="$(sed -E 's#^[^/]+/([^,]+),.*#\1#' <<< "$_nv_line")"
                [[ -n "$_nv_mod" && -n "$_nv_ver" ]] || continue
                echo "  dkms (re)build ${_nv_mod}/${_nv_ver} -k ${boot_kernel}"
                dkms build  -m "$_nv_mod" -v "$_nv_ver" -k "$boot_kernel" --force || true
                dkms install -m "$_nv_mod" -v "$_nv_ver" -k "$boot_kernel" --force || true
            done
            update-initramfs -u -k "$boot_kernel" || true
        fi
    fi
    # ---------------------------------------------------------------------------

    # Apply nvprofiling settings
    echo 'options nvidia NVreg_RestrictProfilingToAdminUsers=0' | tee /etc/modprobe.d/nvprofiling.conf

    # nvidia-peermem is NOT modprobe'd at build time. Loading it before the
    # first reboot is fragile across the matrix of distros / kernels we
    # support (e.g. Ubuntu 26.04 needs DOCA-OFED's patched ib_core in
    # /lib/modules/$(uname -r)/updates/dkms/ which is not active in the
    # build kernel; general-purpose build SKUs have no IB hardware to load
    # against; baremetal builds reboot before IB is fully up). The module is
    # queued for first boot via /etc/modules-load.d/nvidia-peermem.conf
    # written below and via the openibd ExecStartPost drop-in installed by
    # setup_sku_customizations.sh.
else
    # RHEL-family: AlmaLinux, Rocky Linux, RHEL - .run file installation
    NVIDIA_DRIVER_VERSION=$(jq -r '.driver.version' <<< $nvidia_metadata)
    NVIDIA_DRIVER_SHA256=$(jq -r '.driver.sha256' <<< $nvidia_metadata)
    NVIDIA_DRIVER_URL=https://us.download.nvidia.com/tesla/${NVIDIA_DRIVER_VERSION}/NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run
    CUDA_DRIVER_DISTRIBUTION=$(jq -r '.driver.distribution' <<< $cuda_metadata)

    if [ "$SKU" = "V100" ]; then
        KERNEL_MODULE_TYPE="proprietary"
    else
        KERNEL_MODULE_TYPE="open"
    fi

    download_and_verify $NVIDIA_DRIVER_URL ${NVIDIA_DRIVER_SHA256}
    bash NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run --silent --dkms --kernel-module-type=${KERNEL_MODULE_TYPE}
    if [[ $DISTRIBUTION == almalinux* ]] || [[ $DISTRIBUTION == rocky* ]] || [[ $DISTRIBUTION == rhel* ]]; then
        dkms install --no-depmod -m nvidia -v ${NVIDIA_DRIVER_VERSION} -k `uname -r` --force
    fi
    # nvidia-peermem is NOT modprobe'd at build time -- see comment in the
    # Ubuntu branch above. The module is queued for first boot via
    # /etc/modules-load.d/nvidia-peermem.conf written below and via the
    # openibd ExecStartPost drop-in installed by setup_sku_customizations.sh.
fi
write_component_version "NVIDIA" ${NVIDIA_DRIVER_VERSION}

touch /etc/modules-load.d/nvidia-peermem.conf
echo "nvidia_peermem" >> /etc/modules-load.d/nvidia-peermem.conf

if [[ "$DISTRIBUTION" != *-aks ]]; then
    # Install CUDA toolkit
    CUDA_DRIVER_VERSION=$(jq -r '.driver.version' <<< $cuda_metadata)
    CUDA_SAMPLES_VERSION=$(jq -r '.samples.version' <<< $cuda_metadata)
    CUDA_SAMPLES_SHA256=$(jq -r '.samples.sha256' <<< $cuda_metadata)

    if [[ $DISTRIBUTION == *"ubuntu"* || $DISTRIBUTION == *"debian"* ]]; then
        # NVIDIA APT repo already configured during driver installation
        apt install -y cuda-toolkit-${CUDA_DRIVER_VERSION//./-}
    elif [[ $DISTRIBUTION == "azurelinux3.0" ]]; then    
        tdnf install -y cuda-toolkit-${CUDA_DRIVER_VERSION//./-}
    else
        # RHEL-family: AlmaLinux, Rocky Linux, RHEL, etc.
        dnf config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_DRIVER_DISTRIBUTION}/x86_64/cuda-${CUDA_DRIVER_DISTRIBUTION}.repo

        # DOCA ships mft tied to the kernel-mft-dkms it built; cuda-rhel9
        # ships mft on a different cadence (sometimes newer). Letting
        # cuda-rhel9 offer mft causes 'dnf check-update' to flag a
        # stale-package upgrade in verify_package_updates and risks an
        # accidental upgrade that breaks compat with the DOCA-built
        # kernel-mft-dkms. mft must track DOCA, not CUDA. Same pattern as
        # install_nvidia_fabric_manager.sh excluding nvidia-fabricmanager*
        # from cuda-azl3 on AzureLinux 3, and a per-repo replacement for
        # the (removed) global DOCA pin in install_doca.sh.
        dnf config-manager --save \
            --setopt="cuda-${CUDA_DRIVER_DISTRIBUTION}-x86_64.excludepkgs=mft* kernel-mft*" >/dev/null

        dnf clean expire-cache
        dnf install -y cuda-toolkit-${CUDA_DRIVER_VERSION//./-}
    fi

    echo 'export PATH="${PATH:+$PATH:}/usr/local/cuda/bin"' | tee /etc/profile.d/cuda.sh > /dev/null
    echo 'export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}/usr/local/cuda/lib64"' | tee -a /etc/profile.d/cuda.sh > /dev/null

    # Ensure proper permissions
    chmod 644 /etc/profile.d/cuda.sh

    cuda_version=$(source /etc/profile; nvcc --version | grep release | awk '{print $6}' | cut -c2-)
    write_component_version "CUDA" ${cuda_version}

    $COMPONENT_DIR/install_cuda_samples.sh

fi

$COMPONENT_DIR/install_gdrcopy.sh

if [[ "$ARCHITECTURE" != "aarch64" ]]; then
    # Install nvidia fabric manager (required for ND96asr_v4)
    $COMPONENT_DIR/install_nvidia_fabric_manager.sh
else
    # Apply nvprofiling settings
    echo 'options nvidia NVreg_RestrictProfilingToAdminUsers=0' | tee /etc/modprobe.d/nvprofiling.conf

    # Enable CDMM mode
    echo 'options nvidia NVreg_CoherentGPUMemoryMode=driver' | tee /etc/modprobe.d/nvidia-openrm.conf
    
    # Install NVIDIA IMEX
    nvidia_imex_metadata=$(jq -r '.imex' <<< $nvidia_metadata)
    IMEX_VERSION=$(jq -r '.version' <<< $nvidia_imex_metadata)
    tdnf install -y nvidia-imex-${IMEX_VERSION}

    # Add configuration to /etc/modprobe.d/nvidia.conf
    cat <<EOF >> /etc/modprobe.d/nvidia.conf
options nvidia NVreg_CreateImexChannel0=1
EOF

    grep -q 'RMBug5172204War=4' /etc/modprobe.d/nvidia.conf 2>/dev/null || \
        echo 'options nvidia NVreg_RegistryDwords="RMBug5172204War=4"' | tee -a /etc/modprobe.d/nvidia.conf

    # Ensure modprobe settings are available when nvidia module loads on next boot
    dracut --force

    # Configuring nvidia-imex service
    systemctl enable nvidia-imex.service

fi

$COMPONENT_DIR/configure_nvidia_persistence.sh

# cleanup downloaded files
rm -rf *.run *.tar.gz *.rpm
rm -rf -- */
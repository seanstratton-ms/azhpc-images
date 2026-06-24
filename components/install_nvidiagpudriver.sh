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

    # Force the ENTIRE NVIDIA driver closure to the metadata driver version on
    # Debian, not just the nvidia-open meta-package. `apt install
    # nvidia-open=<ver>-1` only constrains the (tiny) meta-package; its
    # dependencies (nvidia-kernel-open-dkms — the real kmod — plus
    # nvidia-driver*, libcuda1, libnvidia-*, firmware-nvidia-gsp) are loosely
    # versioned (>=), so apt floats them to the newest patch available. That
    # shipped driver 590.48.01 (whose user-mode stack only advertises CUDA 13.1)
    # against the image's CUDA 13.2.78 toolkit, so every CUDA app failed at
    # runtime: "the provided PTX was compiled with an unsupported toolchain"
    # (gpu-burn), NVBandwidth error 1, NCCL all-reduce hangs (hpc-image-val2
    # build 33765). The closure must pair with the image CUDA toolkit.
    #
    # We do NOT use an /etc/apt/preferences.d pin here. Debian 13 ships apt 3.0,
    # whose preferences parser rejected our version-glob pin with
    # "Warning: Did not understand pin type version" and silently discarded it,
    # letting the closure float (build 33812 -> 590.48.01 with the branch pin,
    # build 33854 -> 610.43.02 once the branch pin was removed). Instead we pin
    # deterministically with an explicit, single-transaction versioned install of
    # every closure member after the meta-package is installed (see below). That
    # is parser-independent and cannot be silently ignored.
    if [[ $DISTRIBUTION == *"debian"* ]]; then
        # Refuse to build a mismatched image: the exact driver build must exist
        # in the repo, or the closure cannot be forced to the metadata version.
        if ! apt-cache madison nvidia-kernel-open-dkms 2>/dev/null \
                | awk '{print $3}' | grep -qE "^${NVIDIA_DRIVER_VERSION}-"; then
            echo "##[error]No nvidia-kernel-open-dkms build matching driver ${NVIDIA_DRIVER_VERSION} in apt repo; refusing to build a mismatched NVIDIA driver closure"
            apt-cache madison nvidia-kernel-open-dkms 2>/dev/null || true
            exit 1
        fi
    fi

    # Pin the driver version and install via APT packages.
    # Debian's NVIDIA repo only ships major-version pinning packages
    # (e.g. nvidia-driver-pinning-590) and not full-version variants
    # (nvidia-driver-pinning-590.44.01), so fall back to the major when
    # the full-version package is unavailable.
    NVIDIA_DRIVER_MAJOR_VERSION=$(jq -r '.driver.major_version // empty' <<< $nvidia_metadata)
    # Use noninteractive + keep-old conffile options so a dpkg conffile prompt
    # (e.g. from the pinning package's own preferences file) can never hang a
    # non-interactive build.
    _apt_noninteractive="DEBIAN_FRONTEND=noninteractive apt -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
    # The pinning package is only a branch-level safety floor; the exact-patch
    # closure is forced by the explicit versioned install below. Not every driver
    # major ships a nvidia-driver-pinning-<major> package in Debian's repo, so a
    # missing package here must not abort the build.
    if [[ $DISTRIBUTION == *"debian"* && -n "${NVIDIA_DRIVER_MAJOR_VERSION}" ]]; then
        eval ${_apt_noninteractive} install nvidia-driver-pinning-${NVIDIA_DRIVER_MAJOR_VERSION} -y \
            || echo "warning: nvidia-driver-pinning-${NVIDIA_DRIVER_MAJOR_VERSION} unavailable; relying on explicit-version closure install"
    else
        eval ${_apt_noninteractive} install nvidia-driver-pinning-${NVIDIA_DRIVER_VERSION} -y \
            || echo "warning: nvidia-driver-pinning-${NVIDIA_DRIVER_VERSION} unavailable; relying on explicit-version closure install"
    fi
    # NOTE: keep the nvidia-driver-pinning-<major> branch pin in place. It pins
    # the closure to the 590.x branch and acts as a safety floor: even if the
    # explicit version install below were skipped, the closure can never jump to
    # a different major (e.g. 610). The explicit install pins the exact patch.
    if [ "$SKU" = "V100" ]; then
        # V100 requires proprietary kernel modules
        apt install cuda-drivers -y
    elif [[ $DISTRIBUTION == *"debian"* ]]; then
        # Install the (meta) package at the exact metadata version first.
        apt install -y --allow-downgrades nvidia-open=${NVIDIA_DRIVER_VERSION}-1

        # Deterministically force the WHOLE driver closure to the exact metadata
        # patch. apt's >= dependency constraints otherwise float the kernel
        # module and user-mode libs to a newer patch (590.48.01 / 610.43.02),
        # mismatching the image CUDA toolkit. apt 3.0 on Debian 13 ignored an
        # /etc/apt/preferences.d version pin ("Did not understand pin type
        # version"), so we pin by explicit, single-transaction versioned install
        # instead — parser-independent and impossible to silently drop.
        #
        # Enumerate every currently-installed package that publishes a
        # ${NVIDIA_DRIVER_VERSION}-* build (this catches oddly-named closure
        # members an enumerated list would miss: libxnvctrl0, libglx-nvidia0,
        # firmware-nvidia-gsp, nvidia-driver-cuda, ...) and reinstall them all at
        # exactly ${NVIDIA_DRIVER_VERSION} together. One transaction keeps the
        # closure internally consistent (every `Depends: foo (= <ver>)` is
        # satisfied), avoiding the partial-pin conflict that broke build 33802.
        target_pkg_version="${NVIDIA_DRIVER_VERSION}-1"
        mapfile -t nvidia_closure_pkgs < <(
            dpkg-query -W -f='${Package}\n' 2>/dev/null | while read -r _pkg; do
                if apt-cache madison "${_pkg}" 2>/dev/null | awk '{print $3}' \
                        | grep -qxF "${target_pkg_version}"; then
                    echo "${_pkg}"
                fi
            done
        )
        if [[ ${#nvidia_closure_pkgs[@]} -gt 0 ]]; then
            nvidia_closure_pinned=()
            for _pkg in "${nvidia_closure_pkgs[@]}"; do
                nvidia_closure_pinned+=("${_pkg}=${target_pkg_version}")
            done
            echo "Forcing NVIDIA driver closure to ${NVIDIA_DRIVER_VERSION}: ${nvidia_closure_pinned[*]}"
            eval ${_apt_noninteractive} install -y --allow-downgrades "${nvidia_closure_pinned[@]}"
        fi

        # Hard assertion: the REAL driver is the kernel module + user-mode libs,
        # not the (tiny) nvidia-open meta-package. If the closure still floated to
        # a different patch, the image CUDA toolkit will mismatch the driver at
        # runtime (gpu-burn PTX / NVBandwidth / NCCL failures) even though the
        # build is otherwise green (build 33812 shipped that silent mismatch).
        # Fail the build loudly here instead of producing a broken image.
        installed_kmod_version=$(dpkg-query -W -f='${Version}' nvidia-kernel-open-dkms 2>/dev/null | sed 's/-[0-9]*$//')
        if [[ "${installed_kmod_version}" != "${NVIDIA_DRIVER_VERSION}" ]]; then
            echo "##[error]NVIDIA driver closure mismatch: nvidia-kernel-open-dkms is ${installed_kmod_version:-<none>} but the image expects ${NVIDIA_DRIVER_VERSION}. Refusing to ship a driver/CUDA-toolkit mismatched image."
            dpkg-query -W -f='${Package} ${Version}\n' 'nvidia-*' 'libnvidia-*' 2>/dev/null | grep -E '5[0-9]{2}\.|6[0-9]{2}\.' || true
            exit 1
        fi
        echo "Verified NVIDIA driver closure resolved to ${NVIDIA_DRIVER_VERSION} (nvidia-kernel-open-dkms ${installed_kmod_version})"
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
        # The captured image boots the cloud-flavored kernel (grub-cloud-amd64
        # default), so prefer a -cloud- kernel as the boot kernel; fall back to
        # the highest-versioned kernel if none is present.
        boot_kernel="$(ls -1 /lib/modules 2>/dev/null | grep -E '\-cloud-' | sort -V | tail -1)"
        [[ -z "$boot_kernel" ]] && boot_kernel="$(ls -1 /lib/modules 2>/dev/null | sort -V | tail -1)"
        # Gate on whether nvidia.ko actually exists for the boot kernel, NOT on a
        # boot-vs-running kernel name comparison. DKMS autoinstall builds nvidia
        # only for the kernel whose headers happen to be installed — the generic
        # non-cloud linux-headers-amd64 meta dragged in by doca-ofed
        # (6.12.94+deb13-amd64) — which is a DIFFERENT flavor than the cloud
        # kernel the image boots, even when `uname -r` matches the boot kernel by
        # version string. A name comparison wrongly concluded "already built" and
        # skipped the rebuild (build 33895 -> nvidia.ko only under
        # 6.12.94+deb13-amd64, none under 6.12.94+deb13-cloud-amd64 -> driver
        # never loaded on the A100 nodes -> DCGM "no entities", gpu-burn missing).
        if [[ -n "$boot_kernel" ]] \
                && ! find "/lib/modules/${boot_kernel}" -name 'nvidia.ko*' 2>/dev/null | grep -q .; then
            echo "NVIDIA DKMS not present for image boot kernel ${boot_kernel} (running kernel ${run_kernel}; module built for a different kernel flavor); rebuilding"
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
        # Hard assertion: refuse to ship an image whose boot kernel has no
        # nvidia.ko — that always yields a non-functional GPU image (nvidia-smi
        # "couldn't communicate with the NVIDIA driver", DCGM/gpu-burn fail) that
        # only surfaces during A100 validation, wasting a full build+validate
        # cycle (build 33895 / validation 33906).
        if [[ -n "$boot_kernel" ]] \
                && ! find "/lib/modules/${boot_kernel}" -name 'nvidia.ko*' 2>/dev/null | grep -q .; then
            echo "##[error]nvidia.ko is still missing for the image boot kernel ${boot_kernel} after reconciliation; refusing to ship a GPU image whose driver will not load at runtime"
            echo "##[debug]nvidia.ko locations found:"; find /lib/modules -name 'nvidia.ko*' 2>/dev/null || true
            exit 1
        fi
        echo "Verified nvidia.ko present for image boot kernel ${boot_kernel}"
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
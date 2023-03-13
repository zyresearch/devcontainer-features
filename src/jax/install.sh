#!/bin/bash

JAX_VERSION=${VERSION:-"latest"}
JAXLIB_VERSION=${VERSION:-"latest"}
JAXLIB_BACKEND=${JAXLIB_BACKEND:-"cuda"}
INSTALL_NN_LIBS=${INSTALLNNLIBS:-"true"}

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo -e 'Script must be run as root. Use sudo, su, or add "USER root" to your Dockerfile before running this script.'
    exit 1
fi

# Ensure that login shells get the correct path if the user updated the PATH using ENV.
rm -f /etc/profile.d/00-restore-env.sh
echo "export PATH=${PATH//$(sh -lc 'echo $PATH')/\$PATH}" > /etc/profile.d/00-restore-env.sh
chmod +x /etc/profile.d/00-restore-env.sh

# Figure out correct version of a three part version number is not passed
find_version_from_git_tags() {
    local variable_name=$1
    local requested_version=${!variable_name}
    if [ "${requested_version}" = "none" ]; then return; fi
    local repository=$2
    local prefix=${3:-"tags/v"}
    local separator=${4:-"."}
    local last_part_optional=${5:-"false"}    
    if [ "$(echo "${requested_version}" | grep -o "." | wc -l)" != "2" ]; then
        local escaped_separator=${separator//./\\.}
        local last_part
        if [ "${last_part_optional}" = "true" ]; then
            last_part="(${escaped_separator}[0-9]+)?"
        else
            last_part="${escaped_separator}[0-9]+"
        fi
        local regex="${prefix}\\K[0-9]+${escaped_separator}[0-9]+${last_part}$"
        local version_list="$(git ls-remote --tags ${repository} | grep -oP "${regex}" | tr -d ' ' | tr "${separator}" "." | sort -rV)"
        if [ "${requested_version}" = "latest" ] || [ "${requested_version}" = "current" ] || [ "${requested_version}" = "lts" ]; then
            declare -g ${variable_name}="$(echo "${version_list}" | head -n 1)"
        else
            set +e
            declare -g ${variable_name}="$(echo "${version_list}" | grep -E -m 1 "^${requested_version//./\\.}([\\.\\s]|$)")"
            set -e
        fi
    fi
    if [ -z "${!variable_name}" ] || ! echo "${version_list}" | grep "^${!variable_name//./\\.}$" > /dev/null 2>&1; then
        echo -e "Invalid ${variable_name} value: ${requested_version}\nValid values:\n${version_list}" >&2
        exit 1
    fi
    echo "${variable_name}=${!variable_name}"
}

apt_get_update()
{
    echo "Running apt-get update..."
    apt-get update -y
}

# Checks if packages are installed and installs them if not
check_packages() {
    if ! dpkg -s "$@" > /dev/null 2>&1; then
        apt_get_update
        apt-get -y install --no-install-recommends "$@"

        # Clean up
        apt-get clean -y
        rm -rf /var/lib/apt/lists/*
    fi
}

check_cuda() {
    if [ "$(find /usr -name "libcudart.so.*" | wc -l)" -eq 0 ] || [ "$(find /usr -name "libcudnn.so.*" | wc -l)" -eq 0 ]; then
        echo "Missing CUDA or cuDNN libraries, please install them first or choose other JAX backends!"
        exit 1
    fi

    echo "Checking CUDA and cuDNN versions..."
    IFS=. libcudart=($(basename "$(find /usr -name "libcudart.so.*.*.*")"))
    CUDA_MAJOR_VERSION="${libcudart[2]}"
    CUDA_MINOR_VERSION="${libcudart[3]}"
    CUDA_VERSION="${CUDA_MAJOR_VERSION}.${CUDA_MINOR_VERSION}"
    echo "Found CUDA libraries version: ${CUDA_VERSION}"
    IFS=. libcudnn=($(basename "$(find /usr -name "libcudnn.so.*.*.*")"))
    CUDNN_MAJOR_VERSION="${libcudnn[2]}"
    CUDNN_MINOR_VERSION="${libcudnn[3]}"
    CUDNN_VERSION="${libcudnn[2]}6"
    echo "Found cuDNN libraries version: ${CUDNN_MAJOR_VERSION}.${CUDNN_MINOR_VERSION}"

    if [ "$(find /usr -name "ptxas" | wc -l)" -eq 0 ]; then
        echo "JAX requires ptxas, install cuda-nvcc first..."
        # Add NVIDIA's package repository to apt so that we can download packages
        # Always use the ubuntu2004 repo because the other repos (e.g., debian11) are missing packages
        NVIDIA_REPO_URL="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2004/x86_64"
        KEYRING_PACKAGE="cuda-keyring_1.0-1_all.deb"
        KEYRING_PACKAGE_URL="$NVIDIA_REPO_URL/$KEYRING_PACKAGE"
        
        # check_packages wget ca-certificates
        apt_get_update
        curl -fsSLO "${KEYRING_PACKAGE_URL}"
        dpkg -i "${KEYRING_PACKAGE}"
        apt_get_update
        apt-get -y install --no-install-recommends "cuda-nvcc-${CUDA_VERSION/./-}"
        apt-get clean -y
        rm -rf /var/lib/apt/lists/*
    fi
}

# Ensure apt is in non-interactive to avoid prompts
export DEBIAN_FRONTEND=noninteractive

# Ensure git is installed
if ! type git > /dev/null 2>&1; then
    apt_get_update
    apt-get -y install --no-install-recommends git

    # Clean up
    apt-get clean -y
    rm -rf /var/lib/apt/lists/*
fi

# Install JAX for different backends.
if [[ "${JAX_VERSION}" != "none" ]] && [[ $(python --version) != "" ]]; then
    echo "Updating pip..."
    python -m pip install --no-cache-dir --upgrade pip wheel

    # Find jax version using soft match
    find_version_from_git_tags JAX_VERSION "https://github.com/google/jax" "tags/jax-v"
    echo "(*) Installing jax ${JAX_VERSION}..."
    python -m pip install --no-cache-dir --root-user-action=ignore jax=="${JAX_VERSION}"
    
    # Find jaxlib verison using soft match
    find_version_from_git_tags JAXLIB_VERSION "https://github.com/google/jax" "tags/jaxlib-v"
    if [ "${JAXLIB_BACKEND}" = "cuda" ]; then
        check_cuda
        JAXLIB_CUDA_VERSION="${JAXLIB_VERSION}+cuda${CUDA_MAJOR_VERSION}.cudnn${CUDNN_VERSION}"
        echo "Installing jaxlib ${JAXLIB_VERSION} CUDA backend..."
        python -m pip install --no-cache-dir --root-user-action=ignore jaxlib=="${JAXLIB_CUDA_VERSION}" -f https://storage.googleapis.com/jax-releases/jax_cuda_releases.html
    elif [ "${JAXLIB_BACKEND}" = "tpu" ]; then
        echo "Installing jaxlib ${JAXLIB_VERSION} TPU backend..."    
        python -m pip install --no-cache-dir --root-user-action=ignore jaxlib=="${JAXLIB_VERSION}" libtpu_nightly requests
    else
        echo "Installing jaxlib ${JAXLIB_VERSION} CPU backend..." 
        python -m pip install --no-cache-dir --root-user-action=ignore jaxlib=="${JAXLIB_VERSION}"
    fi
fi

# Install NN libraries if needed
if [ "${INSTALL_NN_LIBS}" = "true" ]; then
    echo "Updating pip..."
    python -m pip install --no-cache-dir --upgrade --root-user-action=ignore pip

    package_list="tensorflow-cpu \
        tensorflow-datasets \
        haiku \
        optax \
        ml-collections \
        jaxline[customized]"

    echo "Installing ${package_list}..."
    python -m pip install --no-cache-dir --root-user-action=ignore \
        tensorflow-cpu \
        tensorflow-datasets \
        dm-haiku \
        optax \
        ml-collections \
        git+https://github.com/mazhengcn/jaxline
fi

echo "Done!"

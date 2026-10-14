#!/bin/bash
# Conda-free variant of auto_setup_env.sh.
# Uses a uv-managed Python virtual environment instead of a Conda environment.
#
# Usage: bash auto_setup_env_wo_conda.sh <4.5|5.0|5.1> <env_name> [cuda_version (e.g., cu121, cu126, cu128)]
#   The venv is created at ${VENV_ROOT:-$HOME/.venvs}/<env_name>.
#   Activate it later with: source ${VENV_ROOT:-$HOME/.venvs}/<env_name>/bin/activate
set -e
set -o pipefail

# 0. Directory safety check
if [ ! -d "teleimager" ] || [ ! -f "requirements.txt" ]; then
    echo "Error: Please place and run this script from the root of the unitree_sim_isaaclab project!"
    exit 1
fi

# 1. Check Arguments
if [ "$#" -lt 2 ]; then
    echo "Usage: bash auto_setup_env_wo_conda.sh <4.5|5.0|5.1> <env_name> [cuda_version (e.g., cu121, cu126, cu128)]"
    echo "Example: bash auto_setup_env_wo_conda.sh 5.1 unitree_sim_env"
    exit 1
fi

ISAAC_VERSION=$1
ENV_NAME=$2
CUDA_VER=$3
VENV_ROOT=${VENV_ROOT:-$HOME/.venvs}
VENV_DIR="$VENV_ROOT/$ENV_NAME"
# The uv cache and the venv may live on different filesystems; copy instead of hardlink without warnings.
export UV_LINK_MODE=${UV_LINK_MODE:-copy}

# `isaaclab.sh --install` launches Isaac Sim, which asks to accept the NVIDIA Omniverse EULA.
# Without a terminal the prompt reads EOF and the install fails, so require explicit acceptance.
if [ ! -t 0 ] && [ "$OMNI_KIT_ACCEPT_EULA" != "YES" ]; then
    echo "Error: Running non-interactively. Accept the NVIDIA Omniverse EULA with OMNI_KIT_ACCEPT_EULA=YES"
    echo "       (https://docs.omniverse.nvidia.com/platform/latest/common/NVIDIA_Omniverse_License_Agreement.html)"
    exit 1
fi

# uv provides both the Python interpreter (python-build-standalone, which ships
# Python.h so the cyclonedds C extension builds without python3.x-dev) and the venv.
if ! command -v uv &> /dev/null; then
    echo "Error: uv is required. Install it with: curl -LsSf https://astral.sh/uv/install.sh | sh"
    exit 1
fi

# Install only the system packages that are missing, so sudo is not needed when everything is present.
MISSING_PKGS=()
command -v cmake &> /dev/null || MISSING_PKGS+=(cmake)
command -v g++ &> /dev/null || MISSING_PKGS+=(build-essential)
command -v openssl &> /dev/null || MISSING_PKGS+=(openssl)
command -v git-lfs &> /dev/null || MISSING_PKGS+=(git-lfs)
command -v unzip &> /dev/null || MISSING_PKGS+=(unzip)
if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo "Installing missing system packages: ${MISSING_PKGS[*]}"
    sudo apt-get update && sudo apt-get install -y "${MISSING_PKGS[@]}"
fi

# 2. Assign Version-Specific Variables
# Isaac Lab is pinned because its main branch tracks the newest Isaac Sim release
# (Isaac Lab 3.x requires Isaac Sim 6.x).
if [ "$ISAAC_VERSION" == "4.5" ]; then
    PYTHON_VER="3.10"
    TORCH_PKG="torch==2.5.1 torchvision==0.20.1"
    DEFAULT_CUDA="cu121"
    ISAAC_SIM_PKG="isaacsim[all,extscache]==4.5.0"
    ISAAC_LAB_COMMIT="91ad4944f2b7fad29d52c04a5264a082bcaad71d"  # v2.1.0
elif [ "$ISAAC_VERSION" == "5.0" ]; then
    PYTHON_VER="3.11"
    TORCH_PKG="torch==2.7.0 torchvision==0.22.0 torchaudio==2.7.0"
    DEFAULT_CUDA="cu126"
    ISAAC_SIM_PKG="isaacsim[all,extscache]==5.0.0"
    ISAAC_LAB_COMMIT="v2.2.0"
elif [ "$ISAAC_VERSION" == "5.1" ]; then
    PYTHON_VER="3.11"
    TORCH_PKG="torch==2.7.0 torchvision==0.22.0 torchaudio==2.7.0"
    # Isaac Lab v2.3.x reinstalls torch 2.7.0+cu128 during --install, so use cu128 up front.
    DEFAULT_CUDA="cu128"
    ISAAC_SIM_PKG="isaacsim[all,extscache]==5.1.0"
    ISAAC_LAB_COMMIT="80094be3245aa5c8376a7464d29cb4412ea518f5"  # v2.3.2
else
    echo "Error: Unsupported version. Please use 4.5, 5.0, or 5.1."
    exit 1
fi

if [ -z "$CUDA_VER" ]; then
    CUDA_VER=$DEFAULT_CUDA
fi

UNITREE_DIR=$(pwd)


# ==========================================
# PHASE 1: PRE-CLONE ALL REPOSITORIES
# ==========================================
echo "=================================================="
echo "=== Phase 1: Cloning all required repositories ==="
echo "=================================================="

cd ..

if [ ! -d "IsaacLab" ]; then
    echo "Cloning Isaac Lab..."
    git clone https://github.com/isaac-sim/IsaacLab.git
fi

if [ ! -d "cyclonedds" ]; then
    echo "Cloning CycloneDDS..."
    git clone https://github.com/eclipse-cyclonedds/cyclonedds -b releases/0.10.x
fi

if [ ! -d "unitree_sdk2_python" ]; then
    echo "Cloning unitree_sdk2_python..."
    git clone https://github.com/unitreerobotics/unitree_sdk2_python
fi


cd "$UNITREE_DIR"
echo "**************************************************"
echo "Initializing submodules for unitree_sim_isaaclab..."
echo "**************************************************"
git submodule update --init --depth 1


echo "**************************************************"
echo "Generate certificate files..."
echo "**************************************************"
if [ -f ~/.config/xr_teleoperate/cert.pem ] && [ -f ~/.config/xr_teleoperate/key.pem ]; then
    echo "Certificate already exists in ~/.config/xr_teleoperate/, skipping."
else
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout key.pem -out cert.pem -subj "/CN=localhost"
    mkdir -p ~/.config/xr_teleoperate/
    cp key.pem cert.pem ~/.config/xr_teleoperate/
    rm key.pem cert.pem
fi


echo "**************************************************"
echo "Downloading Isaac Lab assets..."
echo "**************************************************"
if [ -d "assets" ]; then
    echo "assets/ already exists, skipping download (run fetch_assets.sh manually to refresh)."
else
    bash fetch_assets.sh
fi

# ==========================================
# PHASE 2: BUILD C++ DEPENDENCIES
# ==========================================
echo "=================================================="
echo "=== Phase 2: Pre-compiling CycloneDDS ==="
echo "=================================================="
cd ../cyclonedds
if [ ! -d "install" ]; then
    mkdir -p build install
    cd build
    cmake .. -DCMAKE_INSTALL_PREFIX=../install
    cmake --build . --target install
    cd ..
fi

export CYCLONEDDS_HOME="$(pwd)/install"
cd "$UNITREE_DIR"


# ==========================================
# PHASE 3: PYTHON VENV & INSTALLATION
# ==========================================
echo "=================================================="
echo "=== Phase 3: Setting up venv and installing packages ==="
echo "=================================================="
echo "**************************************************"
echo "Creating venv: $VENV_DIR (Python $PYTHON_VER)..."
echo "**************************************************"
if [ ! -x "$VENV_DIR/bin/python" ]; then
    mkdir -p "$VENV_ROOT"
    uv venv --seed --managed-python --python "$PYTHON_VER" "$VENV_DIR"
fi
source "$VENV_DIR/bin/activate"

echo "Installing PyTorch (CUDA: $CUDA_VER)..."
uv pip install $TORCH_PKG --index-url "https://download.pytorch.org/whl/$CUDA_VER"

echo "Installing Isaac Sim $ISAAC_VERSION..."
uv pip install "$ISAAC_SIM_PKG" --extra-index-url https://pypi.nvidia.com --index-strategy unsafe-best-match

echo "**************************************************"
echo "Modifying teleimager configurations..."
echo "**************************************************"
sed -i 's/type:.*/type: isaacsim/' teleimager/cam_config_server.yaml
sed -i 's/image_shape:.*/image_shape: [480, 640]/' teleimager/cam_config_server.yaml

echo "**************************************************"
echo "Installing Isaac Lab ($ISAAC_LAB_COMMIT)..."
echo "**************************************************"
cd ../IsaacLab
git checkout "$ISAAC_LAB_COMMIT"
./isaaclab.sh --install

echo "**************************************************"
echo "Installing unitree_sdk2_python..."
echo "**************************************************"
cd ../unitree_sdk2_python
uv pip install -e .
echo "**************************************************"
echo "Installing remaining requirements and teleimager..."
echo "**************************************************"
cd "$UNITREE_DIR"
# rerun-sdk pulls the newest pyarrow, which needs NumPy 2; Isaac Sim pins numpy 1.26.
uv pip install -r requirements.txt "pyarrow<21"
cd teleimager
uv pip install -e .
cd ..

# The Conda variant needs `conda install libstdcxx-ng` because Conda ships an old libstdc++.
# A venv uses the system libstdc++, so only verify it is new enough for Isaac Sim 5.x.
if [ "$ISAAC_VERSION" == "5.0" ] || [ "$ISAAC_VERSION" == "5.1" ]; then
    # No early-exiting readers in these pipes: with pipefail, SIGPIPE would abort the script.
    LIBSTDCXX=$(ldconfig -p | awk '!found && /libstdc\+\+\.so\.6 .*x86-64/ {print $NF; found=1}')
    if [ -n "$LIBSTDCXX" ] && ! grep -q GLIBCXX_3.4.30 "$LIBSTDCXX"; then
        echo "Warning: $LIBSTDCXX lacks GLIBCXX_3.4.30 required by Isaac Sim $ISAAC_VERSION."
        echo "         Upgrade libstdc++6 (e.g. via ppa:ubuntu-toolchain-r/test)."
    fi
fi


echo "=================================================="
echo "Environment $ENV_NAME setup complete for Isaac Sim $ISAAC_VERSION!"
echo "To begin using it, run: source $VENV_DIR/bin/activate"
echo "=================================================="

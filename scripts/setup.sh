#!/usr/bin/env bash
#
# setup_ros2_package.sh
#
# Automated setup for the v4ShinBoom ROS2 workspace:
#   1. Detects the installed ROS2 distro and its install location
#   2. Ensures build/runtime dependencies are present
#   3. Clones/updates external package repos into src/ (with submodules)
#   4. Runs rosdep to pull in package dependencies
#   5. Builds the workspace with colcon IN THE WORKSPACE ROOT (build/, install/,
#      log/ live next to src/, not inside it)
#   6. Regenerates scripts/launch.sh to source the fresh install and launch
#      the robot stack
#   7. Optionally installs a systemd service so launch.sh runs on boot
#
# Usage:
#   ./scripts/setup_ros2_package.sh [options]
#
# Options:
#   -y, --yes           Non-interactive: assume "yes" to all prompts
#   --no-systemd        Skip the systemd boot-service step entirely
#   --systemd           Force-create the systemd boot-service (no prompt)
#   -h, --help          Show this help text
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" # repo root, NOT src/
SRC_DIR="${WORKSPACE_DIR}/src"
BUILD_DIR="${WORKSPACE_DIR}/build"
INSTALL_DIR="${WORKSPACE_DIR}/install"
LOG_DIR="${WORKSPACE_DIR}/log"
LAUNCH_SCRIPT="${SCRIPT_DIR}/launch.sh"

# External repos that need to live under src/<pkg_name>
# (cloned --recursive because they pull in submodules)
declare -A EXTERNAL_PKGS=(
  [ak_v3_driver]="https://github.com/NaCl-Salt-12/ak_v3_driver"
  [odrive_node]="https://github.com/dmj17b/ros_odrive"
)

# Packages expected to exist in src/ once setup is done
EXPECTED_PKGS=(main_ctrl ak_v3_driver odrive_node)

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------
ASSUME_YES=0
SYSTEMD_MODE="prompt" # prompt | force | skip

for arg in "$@"; do
  case "$arg" in
  -y | --yes) ASSUME_YES=1 ;;
  --no-systemd) SYSTEMD_MODE="skip" ;;
  --systemd) SYSTEMD_MODE="force" ;;
  -h | --help)
    grep '^#' "$0" | sed 's/^#//'
    exit 0
    ;;
  *)
    echo "Unknown option: $arg" >&2
    exit 1
    ;;
  esac
done

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
C_RESET="\e[0m"
C_RED="\e[31m"
C_YEL="\e[33m"
C_GRN="\e[32m"
C_BLU="\e[34m"
log() { echo -e "${C_BLU}[setup]${C_RESET} $*"; }
ok() { echo -e "${C_GRN}[setup]${C_RESET} $*"; }
warn() { echo -e "${C_YEL}[setup] WARNING:${C_RESET} $*"; }
err() { echo -e "${C_RED}[setup] ERROR:${C_RESET} $*" >&2; }
die() {
  err "$*"
  exit 1
}

confirm() {
  # confirm "question" -> 0 (yes) / 1 (no)
  local prompt="$1"
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    return 0
  fi
  read -r -p "$(echo -e "${C_YEL}[setup]${C_RESET} ${prompt} [y/N] ")" reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# 1. Detect ROS2 distro + install location
# ---------------------------------------------------------------------------
detect_ros2() {
  log "Detecting ROS2 installation..."

  local found_distros=()
  if [[ -d /opt/ros ]]; then
    for d in /opt/ros/*/; do
      [[ -d "$d" ]] && found_distros+=("$(basename "$d")")
    done
  fi

  [[ ${#found_distros[@]} -gt 0 ]] || die "No ROS2 installation found under /opt/ros. Install ROS2 first."

  if [[ -n "${ROS_DISTRO:-}" && " ${found_distros[*]} " == *" ${ROS_DISTRO} "* ]]; then
    ROS2_DISTRO="${ROS_DISTRO}"
    log "Using already-sourced ROS_DISTRO: ${ROS2_DISTRO}"
  elif [[ ${#found_distros[@]} -eq 1 ]]; then
    ROS2_DISTRO="${found_distros[0]}"
  else
    warn "Multiple ROS2 distros found: ${found_distros[*]}"
    ROS2_DISTRO="${found_distros[-1]}"
    warn "Defaulting to '${ROS2_DISTRO}'. Re-run with that distro sourced if this is wrong."
  fi

  ROS2_INSTALL_DIR="/opt/ros/${ROS2_DISTRO}"
  ROS2_SETUP_BASH="${ROS2_INSTALL_DIR}/setup.bash"
  [[ -f "${ROS2_SETUP_BASH}" ]] || die "Missing ${ROS2_SETUP_BASH}"

  # shellcheck disable=SC1090
  source "${ROS2_SETUP_BASH}"
  command -v ros2 >/dev/null 2>&1 || die "ros2 CLI not found on PATH after sourcing setup.bash"

  ok "ROS2 distro:   ${ROS2_DISTRO}"
  ok "Install dir:   ${ROS2_INSTALL_DIR}"
  ok "ros2 binary:   $(command -v ros2)"
  ok "Workspace dir: ${WORKSPACE_DIR}"
}

# ---------------------------------------------------------------------------
# 2. Ensure dependencies
# ---------------------------------------------------------------------------
ensure_dependencies() {
  log "Checking required build tools..."

  local tools=(git python3 pip3 colcon rosdep)
  local missing=()
  for t in "${tools[@]}"; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    warn "Missing tools: ${missing[*]}"
    log "Installing via apt (sudo required)..."
    sudo apt-get update -y
    for t in "${missing[@]}"; do
      case "$t" in
      colcon) sudo apt-get install -y python3-colcon-common-extensions ;;
      rosdep) sudo apt-get install -y python3-rosdep ;;
      git) sudo apt-get install -y git ;;
      python3) sudo apt-get install -y python3 ;;
      pip3) sudo apt-get install -y python3-pip ;;
      esac
    done
  fi

  for t in "${tools[@]}"; do
    command -v "$t" >/dev/null 2>&1 || die "'$t' still missing after install attempt; please install manually."
  done

  if [[ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]]; then
    log "Initializing rosdep (first run on this machine)..."
    sudo rosdep init || warn "rosdep init failed/already initialized, continuing."
  fi
  log "Updating rosdep database..."
  rosdep update || warn "rosdep update failed; dependency resolution may be stale."

  ok "Dependency check complete."
}

# ---------------------------------------------------------------------------
# 3. Fetch external package repos (recursive, for submodules)
# ---------------------------------------------------------------------------
fetch_external_packages() {
  log "Fetching external ROS2 packages into ${SRC_DIR}..."
  mkdir -p "${SRC_DIR}"

  for pkg in "${!EXTERNAL_PKGS[@]}"; do
    local url="${EXTERNAL_PKGS[$pkg]}"
    local dest="${SRC_DIR}/${pkg}"

    if [[ -d "${dest}/.git" ]]; then
      log "Updating existing repo: ${pkg}"
      git -C "${dest}" pull --ff-only || warn "Could not fast-forward ${pkg}; resolve manually if needed."
      git -C "${dest}" submodule update --init --recursive
    elif [[ -d "${dest}" ]]; then
      warn "${dest} exists but is not a git repo — leaving it untouched."
    else
      log "Cloning ${pkg} from ${url} (recursive)..."
      git clone --recursive "${url}" "${dest}"
    fi
  done

  ok "External packages ready."
}

# ---------------------------------------------------------------------------
# 4. Verify expected packages + resolve dependencies with rosdep
# ---------------------------------------------------------------------------
resolve_dependencies() {
  log "Verifying expected packages are present in src/..."
  local missing=()
  for pkg in "${EXPECTED_PKGS[@]}"; do
    [[ -d "${SRC_DIR}/${pkg}" ]] || missing+=("$pkg")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing package directories under src/: ${missing[*]}"
  fi
  ok "Found all expected packages: ${EXPECTED_PKGS[*]}"

  log "Resolving package dependencies with rosdep (this may prompt for sudo)..."
  cd "${WORKSPACE_DIR}"
  rosdep install --from-paths "${SRC_DIR}" --ignore-src -r -y ||
    warn "rosdep reported issues; build may still succeed if they're non-critical."
}

# ---------------------------------------------------------------------------
# 5. Build the workspace — at WORKSPACE ROOT, not inside src/
# ---------------------------------------------------------------------------
build_workspace() {
  log "Building workspace with colcon..."
  cd "${WORKSPACE_DIR}"

  # Explicitly point build/install/log at the workspace root so this can
  # never accidentally nest itself under src/, regardless of cwd.
  colcon build \
    --base-paths "${WORKSPACE_DIR}" \
    --build-base "${BUILD_DIR}" \
    --install-base "${INSTALL_DIR}" \
    --log-base "${LOG_DIR}" \
    --symlink-install

  [[ -f "${INSTALL_DIR}/setup.bash" ]] || die "Build finished but ${INSTALL_DIR}/setup.bash was not produced."
  ok "Build complete. Artifacts in: ${BUILD_DIR}, ${INSTALL_DIR}, ${LOG_DIR}"
}

# ---------------------------------------------------------------------------
# 6. Regenerate scripts/launch.sh
# ---------------------------------------------------------------------------
find_launch_target() {
  # Prefer a launch file in main_ctrl; fall back to the first one found.
  local candidate
  candidate="$(find "${SRC_DIR}/main_ctrl" -path '*/launch/*.py' 2>/dev/null | head -n1 || true)"
  if [[ -z "$candidate" ]]; then
    candidate="$(find "${SRC_DIR}" -path '*/launch/*.py' 2>/dev/null | head -n1 || true)"
  fi
  echo "$candidate"
}

update_launch_script() {
  log "Updating ${LAUNCH_SCRIPT}..."

  local launch_file launch_pkg launch_name
  launch_file="$(find_launch_target)"

  if [[ -n "$launch_file" ]]; then
    launch_pkg="$(basename "$(dirname "$(dirname "$launch_file")")")"
    launch_name="$(basename "$launch_file")"
  else
    warn "No launch/*.py file found yet; writing launch.sh with a placeholder you can edit."
    launch_pkg="main_ctrl"
    launch_name="CHANGE_ME.launch.py"
  fi

  cat >"${LAUNCH_SCRIPT}" <<EOF
#!/usr/bin/env bash
# Auto-generated by setup_ros2_package.sh on $(date -Is)
# Sources this workspace's install and launches the robot stack.
set -euo pipefail

WORKSPACE_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"

source "/opt/ros/${ROS2_DISTRO}/setup.bash"
source "\${WORKSPACE_DIR}/install/setup.bash"

exec ros2 launch ${launch_pkg} ${launch_name}
EOF

  chmod +x "${LAUNCH_SCRIPT}"
  ok "launch.sh -> ros2 launch ${launch_pkg} ${launch_name}"
  [[ "$launch_name" == "CHANGE_ME.launch.py" ]] &&
    warn "Edit ${LAUNCH_SCRIPT} once your launch file exists."
}

# ---------------------------------------------------------------------------
# 7. Optional: systemd boot service
# ---------------------------------------------------------------------------
setup_systemd() {
  [[ "$SYSTEMD_MODE" == "skip" ]] && {
    log "Skipping systemd setup (--no-systemd)."
    return
  }

  if [[ "$SYSTEMD_MODE" == "prompt" ]]; then
    confirm "Create a systemd service to run launch.sh automatically on boot?" || {
      log "Skipping systemd setup."
      return
    }
  fi

  local service_name="v4shinboom"
  local run_user="${SUDO_USER:-$USER}"
  local service_path="/etc/systemd/system/${service_name}.service"

  log "Installing systemd service '${service_name}' (runs as user: ${run_user})..."

  sudo tee "${service_path}" >/dev/null <<EOF
[Unit]
Description=v4ShinBoom ROS2 stack
After=network.target

[Service]
Type=simple
User=${run_user}
WorkingDirectory=${WORKSPACE_DIR}
ExecStart=${LAUNCH_SCRIPT}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable "${service_name}.service"

  ok "systemd service installed and enabled: ${service_name}.service"
  log "  Start now:  sudo systemctl start ${service_name}"
  log "  Status:     systemctl status ${service_name}"
  log "  Logs:       journalctl -u ${service_name} -f"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log "=== v4ShinBoom ROS2 workspace setup ==="
  detect_ros2
  ensure_dependencies
  fetch_external_packages
  resolve_dependencies
  build_workspace
  update_launch_script
  setup_systemd
  echo
  ok "=== Setup complete ==="
  log "To use the workspace in a new shell:"
  log "  source ${ROS2_SETUP_BASH}"
  log "  source ${INSTALL_DIR}/setup.bash"
  log "Or just run: ${LAUNCH_SCRIPT}"
}

main "$@"

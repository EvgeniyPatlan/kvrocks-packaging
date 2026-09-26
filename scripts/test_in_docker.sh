#!/usr/bin/env bash
# test_in_docker.sh — Run Kvrocks package tests inside systemd-enabled Docker containers
#
# Usage: scripts/test_in_docker.sh [OPTIONS]
#
# Launches Docker containers with systemd, installs packages (from local files
# or Percona repo), runs test_packages.sh, and reports results.

set -euo pipefail

###############################################################################
# Constants
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_SCRIPT="$SCRIPT_DIR/test_packages.sh"

# Supported images — order matters for display
DEB_IMAGES=(
    "ubuntu:jammy"
    "ubuntu:noble"
    "ubuntu:resolute"
    "debian:bookworm"
    "debian:trixie"
)
RPM_IMAGES=(
    "oraclelinux:8"
    "oraclelinux:9"
    "oraclelinux:10"
    "amazonlinux:2023"
)
ALL_IMAGES=("${DEB_IMAGES[@]}" "${RPM_IMAGES[@]}")

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

###############################################################################
# CLI state
###############################################################################
PKG_DIR=""
USE_REPO=false
REPO_CHANNEL="testing"
TARGET_IMAGE=""
RUN_ALL=false
NO_DOCKER=false
EXPECTED_VERSION=""
KEEP_CONTAINERS=false

# Runtime state
CONTAINERS_STARTED=()
TEMP_IMAGES=()
declare -A RESULTS=()

###############################################################################
# Usage
###############################################################################
usage() {
    cat <<'EOF'
Usage: scripts/test_in_docker.sh [OPTIONS]

Install source (one required):
  --pkg-dir=DIR           Install from local .deb/.rpm files in DIR
  --repo                  Install from Percona repository
  --repo-channel=CHANNEL  Repo channel: testing (default), release, or experimental

Target selection:
  --image=IMAGE           Run on a single Docker image (e.g. ubuntu:noble)
  --all                   Run on all supported images matching the package type
  --no-docker             Run test_packages.sh directly on current host (no Docker)

Options:
  --version=X.Y.Z         Expected Kvrocks version (passed to test_packages.sh)
  --keep                   Don't remove containers after run (debugging)
  --help                   Show usage

Supported images:
  DEB: ubuntu:jammy, ubuntu:noble, ubuntu:resolute, debian:bookworm, debian:trixie
  RPM: oraclelinux:8, oraclelinux:9, oraclelinux:10, amazonlinux:2023

Examples:
  # Single OS, repo-based
  scripts/test_in_docker.sh --repo --image=ubuntu:noble

  # Single OS, local packages
  scripts/test_in_docker.sh --pkg-dir=./build/deb --image=debian:bookworm

  # Full matrix with local packages
  scripts/test_in_docker.sh --pkg-dir=./build/deb --all

  # VM-based (no Docker)
  scripts/test_in_docker.sh --repo --no-docker
EOF
}

###############################################################################
# Helpers
###############################################################################
log()  { printf "${CYAN}>>>${RESET} %s\n" "$*"; }
warn() { printf "${YELLOW}WARNING:${RESET} %s\n" "$*" >&2; }
err()  { printf "${RED}ERROR:${RESET} %s\n" "$*" >&2; }
die()  { err "$@"; exit 1; }

# Return "deb" or "rpm" for a given image name
image_family() {
    local img="$1"
    case "$img" in
        ubuntu:*|debian:*) echo "deb" ;;
        *)                 echo "rpm" ;;
    esac
}

# Slugify image name for container naming (e.g. "ubuntu:noble" -> "ubuntu-noble")
slug() {
    echo "$1" | tr ':/' '-_'
}

###############################################################################
# Cleanup
###############################################################################
# shellcheck disable=SC2317  # invoked indirectly via `trap cleanup EXIT`
cleanup() {
    if [[ "$KEEP_CONTAINERS" == true ]]; then
        if [[ ${#CONTAINERS_STARTED[@]} -gt 0 ]]; then
            warn "Keeping containers (--keep): ${CONTAINERS_STARTED[*]}"
        fi
    else
        for cname in "${CONTAINERS_STARTED[@]}"; do
            if docker inspect "$cname" &>/dev/null; then
                docker rm -f "$cname" >/dev/null 2>&1 || true
            fi
        done
    fi
    # Always clean up temporary images
    for img in "${TEMP_IMAGES[@]}"; do
        docker rmi -f "$img" >/dev/null 2>&1 || true
    done
}

###############################################################################
# Docker operations
###############################################################################

# Ensure the image has systemd + /sbin/init. Base images like ubuntu:noble
# ship without it. Returns the image name to use (original or prepared).
prepare_image() {
    local image="$1" family="$2"
    local prepared_tag
    prepared_tag="kvrocks-test-prepared-$(slug "$image")"

    # Check if /sbin/init exists in the image
    if docker run --rm "$image" test -x /sbin/init 2>/dev/null; then
        echo "$image"
        return
    fi

    log "Base image $image lacks /sbin/init — installing systemd..." >&2
    local install_cmd
    if [[ "$family" == "deb" ]]; then
        install_cmd="apt-get update -qq && apt-get install -y -qq systemd systemd-sysv >/dev/null 2>&1"
    else
        install_cmd="yum install -y systemd >/dev/null 2>&1"
    fi

    local tmp_container
    tmp_container="kvrocks-prep-$(slug "$image")-$$"
    docker run --name "$tmp_container" "$image" bash -c "$install_cmd" >&2
    docker commit "$tmp_container" "$prepared_tag" >/dev/null
    docker rm -f "$tmp_container" >/dev/null 2>&1 || true

    log "Prepared image: $prepared_tag" >&2
    echo "$prepared_tag"
}

start_container() {
    local image="$1" name="$2"

    log "Starting container $name ($image)..."
    docker run -d \
        --privileged \
        --name "$name" \
        --tmpfs /run \
        --tmpfs /run/lock \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        "$image" /sbin/init >/dev/null

    CONTAINERS_STARTED+=("$name")
}

wait_for_systemd() {
    local name="$1" timeout=30 elapsed=0
    log "Waiting for systemd to be ready in $name..."
    while [[ $elapsed -lt $timeout ]]; do
        local state
        state="$(docker exec "$name" systemctl is-system-running 2>/dev/null)" || true
        if [[ "$state" == "running" ]] || [[ "$state" == "degraded" ]]; then
            log "systemd ready ($state) after ${elapsed}s"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    warn "systemd did not reach running/degraded state within ${timeout}s (last: ${state:-unknown})"
    return 1
}

install_prereqs() {
    local name="$1" family="$2"
    log "Installing prerequisites in $name..."
    if [[ "$family" == "deb" ]]; then
        docker exec "$name" bash -c \
            "apt-get update -qq && apt-get install -y -qq procps iproute2 wget binutils >/dev/null 2>&1"
    else
        docker exec "$name" bash -c \
            "yum install -y procps-ng iproute wget binutils >/dev/null 2>&1"
    fi
}

# Map an image name to the dist tag suffix used in kvrocks package filenames.
# Jenkins may pass a dated ubuntu:resolute-YYYYMMDD tag; strip that suffix
# before computing the codename-based tag.
dist_tag() {
    local img="$1"
    case "$img" in
        oraclelinux:8) echo ".el8." ;;
        oraclelinux:9) echo ".el9." ;;
        oraclelinux:10) echo ".el10." ;;
        amazonlinux:2023) echo ".amzn2023." ;;
        ubuntu:*|debian:*)
            local codename="${img#*:}"
            codename="${codename%-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]}"
            echo ".${codename}_"
            ;;
    esac
}

# Copy only the packages matching this image's dist tag into the container.
copy_packages() {
    local cname="$1" image="$2" tag f n=0
    tag="$(dist_tag "$image")"
    docker exec "$cname" mkdir -p /packages
    for f in "$PKG_DIR"/*; do
        [[ "$(basename "$f")" == *"$tag"* ]] || continue
        docker cp "$f" "$cname:/packages/"
        n=$((n + 1))
    done
    [[ "$n" -gt 0 ]] || { err "no packages matching '$tag' in $PKG_DIR"; return 1; }
}

###############################################################################
# Run test on a single Docker image
###############################################################################
run_test_on_image() {
    local image="$1"
    local family
    family="$(image_family "$image")"
    local cname
    cname="kvrocks-test-$(slug "$image")-$$"

    printf '\n%s================================================================%s\n' "$BOLD" "$RESET"
    log "Testing on $image ($family)"
    printf '%s================================================================%s\n' "$BOLD" "$RESET"

    # Prepare image (install systemd if missing)
    local run_image
    run_image="$(prepare_image "$image" "$family")"
    # prepare_image runs in a command-substitution subshell, so track the
    # prepared image here for cleanup rather than inside that function.
    [[ "$run_image" == "$image" ]] || TEMP_IMAGES+=("$run_image")

    # Start container
    if ! start_container "$run_image" "$cname"; then
        err "Failed to start container for $image"
        RESULTS["$image"]="FAIL"
        return 1
    fi

    # Wait for systemd
    if ! wait_for_systemd "$cname"; then
        err "Systemd not ready in $image — continuing anyway"
    fi

    # Install prereqs
    install_prereqs "$cname" "$family"

    # Copy test script into container
    docker cp "$TEST_SCRIPT" "$cname:/usr/local/bin/test_packages.sh"
    docker exec "$cname" chmod +x /usr/local/bin/test_packages.sh

    # Build the test command args
    local test_args=()
    if [[ -n "$PKG_DIR" ]]; then
        copy_packages "$cname" "$image" || { RESULTS["$image"]="FAIL"; return 1; }
        test_args+=(--pkg-dir=/packages)
    fi
    if [[ "$USE_REPO" == true ]]; then
        test_args+=(--repo "--repo-channel=$REPO_CHANNEL")
    fi
    if [[ -n "$EXPECTED_VERSION" ]]; then
        test_args+=("--version=$EXPECTED_VERSION")
    fi

    # Run the test
    log "Running test_packages.sh ${test_args[*]}..."
    local rc=0
    docker exec "$cname" bash /usr/local/bin/test_packages.sh "${test_args[@]}" || rc=$?

    if [[ $rc -eq 0 ]]; then
        RESULTS["$image"]="PASS"
    else
        RESULTS["$image"]="FAIL"
    fi

    # Cleanup container (unless --keep)
    if [[ "$KEEP_CONTAINERS" != true ]]; then
        docker rm -f "$cname" >/dev/null 2>&1 || true
        # Remove from CONTAINERS_STARTED so cleanup trap doesn't double-remove
        local new_list=()
        for c in "${CONTAINERS_STARTED[@]}"; do
            [[ "$c" != "$cname" ]] && new_list+=("$c")
        done
        CONTAINERS_STARTED=("${new_list[@]}")
    fi

    return $rc
}

###############################################################################
# Run test directly on host (no Docker)
###############################################################################
run_test_no_docker() {
    printf '\n%s================================================================%s\n' "$BOLD" "$RESET"
    log "Running test_packages.sh directly on current host (no Docker)"
    printf '%s================================================================%s\n' "$BOLD" "$RESET"

    local test_args=()
    if [[ -n "$PKG_DIR" ]]; then
        test_args+=("--pkg-dir=$PKG_DIR")
    fi
    if [[ "$USE_REPO" == true ]]; then
        test_args+=(--repo "--repo-channel=$REPO_CHANNEL")
    fi
    if [[ -n "$EXPECTED_VERSION" ]]; then
        test_args+=("--version=$EXPECTED_VERSION")
    fi

    exec bash "$TEST_SCRIPT" "${test_args[@]}"
}

###############################################################################
# Print summary table
###############################################################################
print_summary() {
    local images=("$@")
    local fail_count=0 total=${#images[@]}

    printf '\n%s=== Results ===%s\n' "$BOLD" "$RESET"
    for img in "${images[@]}"; do
        local result="${RESULTS[$img]:-SKIP}"
        if [[ "$result" == "PASS" ]]; then
            printf "  %-25s ${GREEN}%s${RESET}\n" "$img" "$result"
        else
            printf "  %-25s ${RED}%s${RESET}\n" "$img" "$result"
            fail_count=$((fail_count + 1))
        fi
    done

    printf "\n"
    if [[ $fail_count -eq 0 ]]; then
        printf "${GREEN}${BOLD}All %d image(s) passed.${RESET}\n" "$total"
    else
        printf "${RED}${BOLD}%d of %d image(s) failed.${RESET}\n" "$fail_count" "$total"
    fi

    return $fail_count
}

###############################################################################
# Determine which images to run
###############################################################################
determine_images() {
    if [[ -n "$TARGET_IMAGE" ]]; then
        echo "$TARGET_IMAGE"
        return
    fi

    if [[ "$USE_REPO" == true ]]; then
        # Repo mode: run all images
        printf '%s\n' "${ALL_IMAGES[@]}"
        return
    fi

    if [[ -n "$PKG_DIR" ]]; then
        # Detect deb vs rpm from file extensions
        local has_deb=false has_rpm=false
        for f in "$PKG_DIR"/percona-kvrocks*; do
            [[ -f "$f" ]] || continue
            case "$f" in
                *.deb) has_deb=true ;;
                *.rpm) has_rpm=true ;;
            esac
        done

        if [[ "$has_deb" == true ]]; then
            printf '%s\n' "${DEB_IMAGES[@]}"
        fi
        if [[ "$has_rpm" == true ]]; then
            printf '%s\n' "${RPM_IMAGES[@]}"
        fi
        if [[ "$has_deb" == false ]] && [[ "$has_rpm" == false ]]; then
            die "No .deb or .rpm files found in $PKG_DIR"
        fi
        return
    fi

    die "Cannot determine image list"
}

###############################################################################
# Main
###############################################################################
main() {
    # Parse arguments
    for arg in "$@"; do
        case "$arg" in
            --pkg-dir=*)
                PKG_DIR="${arg#*=}"
                ;;
            --repo)
                USE_REPO=true
                ;;
            --repo-channel=*)
                REPO_CHANNEL="${arg#*=}"
                ;;
            --image=*)
                TARGET_IMAGE="${arg#*=}"
                ;;
            --all)
                RUN_ALL=true
                ;;
            --no-docker)
                NO_DOCKER=true
                ;;
            --version=*)
                EXPECTED_VERSION="${arg#*=}"
                ;;
            --keep)
                KEEP_CONTAINERS=true
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                die "Unknown argument: $arg"
                ;;
        esac
    done

    # Validate install source
    if [[ -z "$PKG_DIR" ]] && [[ "$USE_REPO" != true ]]; then
        die "Either --pkg-dir or --repo is required"
    fi
    if [[ -n "$PKG_DIR" ]] && [[ "$USE_REPO" == true ]]; then
        die "--pkg-dir and --repo are mutually exclusive"
    fi

    # Validate pkg-dir exists
    if [[ -n "$PKG_DIR" ]]; then
        [[ -d "$PKG_DIR" ]] || die "Package directory does not exist: $PKG_DIR"
        PKG_DIR="$(cd "$PKG_DIR" && pwd)"
    fi

    # --no-docker mode: run directly on host
    if [[ "$NO_DOCKER" == true ]]; then
        run_test_no_docker
        # exec replaces the process, so this is unreachable
        exit $?
    fi

    # Validate target selection
    if [[ -z "$TARGET_IMAGE" ]] && [[ "$RUN_ALL" != true ]]; then
        die "Either --image, --all, or --no-docker is required"
    fi

    # Check Docker is available
    if ! command -v docker &>/dev/null; then
        die "Docker is not installed or not in PATH"
    fi
    if ! docker info &>/dev/null; then
        die "Docker daemon is not running or current user lacks permissions"
    fi

    # Determine image list
    local images=()
    while IFS= read -r img; do
        [[ -n "$img" ]] && images+=("$img")
    done < <(determine_images)

    if [[ ${#images[@]} -eq 0 ]]; then
        die "No images to test"
    fi

    log "Images to test: ${images[*]}"
    if [[ "$USE_REPO" == true ]]; then
        log "Install mode: repo (channel=$REPO_CHANNEL)"
    else
        log "Install mode: local packages from $PKG_DIR"
    fi

    # Set up cleanup trap
    trap cleanup EXIT

    # Run tests
    for image in "${images[@]}"; do
        run_test_on_image "$image" || true
    done

    # Print summary
    local fail_count=0
    print_summary "${images[@]}" || fail_count=$?

    if [[ $fail_count -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main "$@"

#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals read indirectly via print_settings' ${!v} and by functions later tasks append above print_settings
set -euo pipefail

readonly PRODUCT="kvrocks"
readonly PACKAGE_NAME="percona-kvrocks"
readonly DEFAULT_VERSION="2.17.0"
readonly DEFAULT_BRANCH="v2.17.0"
readonly DEFAULT_RELEASE="1"
readonly DEFAULT_REPO="https://github.com/apache/kvrocks.git"
readonly PACKAGING_REPO="https://github.com/EvgeniyPatlan/kvrocks-packaging.git"

# dch falls back to a "user@hostname" address when these are unset, which
# lintian flags as bogus-mail-host-in-debian-changelog; default to the
# maintainer already recorded in debian/control and debian/changelog, but
# let a caller's own DEBFULLNAME/DEBEMAIL win.
: "${DEBFULLNAME:=Evgeniy Patlan}"
: "${DEBEMAIL:=evgeniy.patlan@percona.com}"
export DEBFULLNAME DEBEMAIL

BUILDER_SCRIPT_DIR="$(dirname "$(readlink -e "${0}")")"
readonly BUILDER_SCRIPT_DIR

log_info()  { printf '\033[1;32m[INFO]\033[0m  %s\n' "$*"; }
log_warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" >&2; }
log_error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
die()       { log_error "$@"; exit 1; }

harden_apt() {
    [[ -d /etc/apt ]] || return 0
    mkdir -p /etc/apt/apt.conf.d
    cat > /etc/apt/apt.conf.d/80-retries <<'EOF'
Acquire::Retries "5";
Acquire::Retries::Delay "true";
Acquire::http::Timeout "120";
Acquire::https::Timeout "120";
Acquire::http::Pipeline-Depth "0";
EOF
}

apt_get() {
    harden_apt
    local attempt rc
    for attempt in 1 2 3 4 5; do
        if DEBIAN_FRONTEND=noninteractive command apt-get "$@"; then
            return 0
        fi
        rc=$?
        log_warn "apt-get $* failed (attempt ${attempt}/5, rc=${rc}); retrying"
        DEBIAN_FRONTEND=noninteractive command apt-get update -y >/dev/null 2>&1 || true
        sleep $(( attempt * 10 ))
    done
    die "apt-get $* failed after 5 attempts"
}

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]
    --builddir=DIR                  Absolute path to the dir where all actions will be performed
    --get_sources                   Clone kvrocks, vendor dependencies, create the source tarball
    --build_src_rpm                 Build the source RPM
    --build_rpm                     Build binary RPMs
    --build_src_deb                 Build the source DEB
    --build_deb                     Build binary DEBs
    --install_deps                  Install build dependencies (root privileges are required)
    --branch=BRANCH                 Git ref to build (default: ${DEFAULT_BRANCH})
    --repo=URL                      Git repo to build (default: ${DEFAULT_REPO})
    --version=VER                   Package version (default: ${DEFAULT_VERSION})
    --release=REL                   Package release (default: ${DEFAULT_RELEASE})
    --use_local_packaging_script    Use rpm/, debian/ and common/ from ${BUILDER_SCRIPT_DIR}/..
    --help                          Print usage
EOF
    exit 0
}

parse_arguments() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --builddir=*)                WORKDIR="${arg#*=}" ;;
            --get_sources|--get_sources=*)     SOURCE=1 ;;
            --build_src_rpm|--build_src_rpm=*) SRPM=1 ;;
            --build_rpm|--build_rpm=*)         RPM=1 ;;
            --build_src_deb|--build_src_deb=*) SDEB=1 ;;
            --build_deb|--build_deb=*)         DEB=1 ;;
            --install_deps|--install_deps=*)   INSTALL=1 ;;
            --use_local_packaging_script|--use_local_packaging_script=*) LOCAL_BUILD=1 ;;
            --branch=*)                  BRANCH="${arg#*=}" ;;
            --repo=*)                    REPO="${arg#*=}" ;;
            --version=*)                 VERSION="${arg#*=}" ;;
            --release=*)                 RELEASE="${arg#*=}" ;;
            --help)                      usage ;;
            *)                           die "Unknown option: $arg" ;;
        esac
    done
}

check_workdir() {
    [[ -n "$WORKDIR" ]] || die "--builddir is required"
    [[ "$WORKDIR" != "$CURDIR" ]] || die "Current directory cannot be used for building!"
    [[ -d "$WORKDIR" ]] || die "$WORKDIR is not a directory."
}

# find_and_copy_artifact SEARCH_SUBDIR GLOB_PATTERN
#   Looks in $WORKDIR/SEARCH_SUBDIR then $CURDIR/SEARCH_SUBDIR for the newest
#   match, copies it into $WORKDIR and sets FOUND_FILE to its basename.
find_and_copy_artifact() {
    local search_subdir="$1" glob_pattern="$2" found dir
    for dir in "$WORKDIR/$search_subdir" "$CURDIR/$search_subdir"; do
        found="$(find "$dir" -name "$glob_pattern" 2>/dev/null | sort | tail -n1 || true)"
        if [[ -n "$found" ]]; then
            FOUND_FILE="$(basename "$found")"
            cp "$found" "$WORKDIR/$FOUND_FILE"
            return 0
        fi
    done
    die "No artifact matching '$glob_pattern' found in $search_subdir"
}

# copy_artifacts DEST_SUBDIR FILE...
#   Copies the given files into both $WORKDIR/DEST_SUBDIR and $CURDIR/DEST_SUBDIR.
copy_artifacts() {
    local dest_subdir="$1"
    shift
    mkdir -p "$WORKDIR/$dest_subdir" "$CURDIR/$dest_subdir"
    cp "$@" "$WORKDIR/$dest_subdir/"
    cp "$@" "$CURDIR/$dest_subdir/"
}

get_system() {
    ARCH="$(uname -m)"
    if [[ -f /etc/redhat-release ]]; then
        OS="rpm"
        RHEL="$(rpm --eval %rhel)"
        OS_NAME="el${RHEL}"
        PLATFORM_FAMILY="rhel"
        [[ -f /etc/oracle-release ]] && PLATFORM_FAMILY="oracle"
    elif [[ -f /etc/system-release ]] && grep -qi amazon /etc/system-release; then
        OS="rpm"
        RHEL="0"
        OS_NAME="amzn2023"
        PLATFORM_FAMILY="amazon"
    elif [[ -f /etc/debian_version ]]; then
        OS="deb"
        # shellcheck disable=SC1091
        OS_NAME="$(. /etc/os-release; echo "${VERSION_CODENAME}")"
        PLATFORM_FAMILY="deb"
    else
        OS="unknown"
    fi
}

install_deps() {
    [[ "$INSTALL" -eq 1 ]] || return 0
    [[ "$(id -u)" -eq 0 ]] || die "Cannot install dependencies — please run as root"
    case "$OS" in
        rpm) install_deps_rpm ;;
        deb) install_deps_deb ;;
        *)   die "Unsupported OS" ;;
    esac
}

install_deps_rpm() {
    local pm="yum"
    command -v dnf >/dev/null && pm="dnf"

    # Oracle Linux ships gcc-toolset-12 and libstdc++-static in CodeReady
    # Builder / AppStream, which is present but disabled by default.
    if [[ "$PLATFORM_FAMILY" == "oracle" ]]; then
        "$pm" install -y dnf-plugins-core >/dev/null 2>&1 || true
        "$pm" config-manager --enable "ol${RHEL}_codeready_builder" >/dev/null 2>&1 || true
    fi

    local -a pkgs=(rpm-build rpmdevtools git make cmake autoconf automake libtool
                   python3 perl which tar gzip unzip patch openssl-devel
                   systemd-rpm-macros shadow-utils)
    case "$RHEL" in
        8|9)
            pkgs+=(gcc-toolset-12-gcc gcc-toolset-12-gcc-c++ gcc-toolset-12-libstdc++-devel
                   gcc-toolset-12-binutils gcc-toolset-12-annobin-plugin-gcc)
            ;;
        *)
            pkgs+=(gcc gcc-c++ libstdc++-static)
            ;;
    esac
    "$pm" install -y "${pkgs[@]}"
    "$pm" clean all
}

install_deps_deb() {
    apt_get update
    apt_get -y install build-essential debhelper devscripts dpkg-dev fakeroot \
        lsb-release ca-certificates git cmake autoconf automake libtool \
        python3 perl unzip patch libssl-dev pkg-config
}

get_sources() {
    [[ "$SOURCE" -eq 1 ]] || return 0

    if [[ -f /opt/rh/gcc-toolset-12/enable ]]; then
        set +u
        # shellcheck disable=SC1091
        . /opt/rh/gcc-toolset-12/enable
        set -u
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local srcdir="${PACKAGE_NAME}-${VERSION}"
    rm -rf "$srcdir"
    git clone "$REPO" "$srcdir" || die "Failed to clone $REPO"
    cd "$srcdir" || die "Cannot cd to $srcdir"
    git checkout "$BRANCH" || die "Cannot checkout $BRANCH"
    local revision
    revision="$(git rev-parse --short HEAD)"

    [[ "$(cat src/VERSION.txt)" == "$VERSION" ]] \
        || die "src/VERSION.txt is '$(cat src/VERSION.txt)', expected '$VERSION'"

    if [[ "$LOCAL_BUILD" -eq 1 ]]; then
        mkdir packaging
        [[ -d "${BUILDER_SCRIPT_DIR}/../common" ]] || die "${BUILDER_SCRIPT_DIR}/../common is required by --use_local_packaging_script"
        local d
        local -a dirs=()
        for d in rpm debian common; do
            [[ -d "${BUILDER_SCRIPT_DIR}/../${d}" ]] && dirs+=("$d")
        done
        # Build artifacts that may sit next to the packaging sources when the
        # builder runs from the repo root must not end up in the tarball.
        tar -C "${BUILDER_SCRIPT_DIR}/.." -cf - \
            --exclude='*.rpm' --exclude='*.deb' --exclude='*.ddeb' \
            --exclude='*.changes' --exclude='*.buildinfo' \
            --exclude='debian/tmp' --exclude='debian/.debhelper' --exclude='debian/files' \
            --exclude='debian/percona-kvrocks-server' --exclude='debian/percona-kvrocks-tools' \
            --exclude='debian/*.substvars' --exclude='debian/*.debhelper' \
            --exclude='debian/*.debhelper.log' --exclude='debian/debhelper-build-stamp' \
            "${dirs[@]}" | tar -C packaging -xf - || die "Failed to copy local packaging files"
    else
        git clone --depth 1 --branch "${PACKAGING_BRANCH:-main}" "$PACKAGING_REPO" packaging \
            || die "Failed to clone packaging from $PACKAGING_REPO"
        rm -rf packaging/.git
    fi

    python3 x.py fetch-deps "$PWD/deps" -DENABLE_OPENSSL=ON -DPORTABLE=1 \
        || die "fetch-deps failed"
    bash "${BUILDER_SCRIPT_DIR}/vendor-licenses.sh" "$PWD" || die "vendor-licenses.sh failed"
    python3 "${BUILDER_SCRIPT_DIR}/gen-sbom.py" --src "$PWD" --name "$PACKAGE_NAME" \
        --version "$VERSION" --out "$PWD/sbom" || die "gen-sbom.py failed"

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"
    tar --owner=0 --group=0 --exclude=.git -czf "${srcdir}.tar.gz" "$srcdir"

    cat > kvrocks.properties <<EOF
PRODUCT=${PRODUCT}
PRODUCT_FULL=${srcdir}
VERSION=${VERSION}
RELEASE=${RELEASE}
BRANCH=${BRANCH}
REPO=${REPO}
REVISION=${revision}
BUILD_NUMBER=${BUILD_NUMBER:-}
BUILD_ID=${BUILD_ID:-}
UPLOAD=UPLOAD/experimental/BUILDS/${PRODUCT}/${srcdir}/${BRANCH}/${revision}/${BUILD_ID:-}
EOF

    copy_artifacts "source_tarball" "${srcdir}.tar.gz"
    cd "$CURDIR" || die "Cannot cd to $CURDIR"
}

build_srpm() {
    [[ "$SRPM" -eq 1 ]] || return 0
    [[ "$OS" == "rpm" ]] || die "Cannot build src rpm on a non-RPM system"
    cd "$WORKDIR"
    find_and_copy_artifact "source_tarball" "${PACKAGE_NAME}-*.tar.gz"
    local tarfile="$FOUND_FILE"
    rm -rf rpmbuild
    mkdir -p rpmbuild/{SOURCES,SPECS,BUILD,SRPMS,RPMS}
    # -C must precede the member pattern: GNU tar only honors -C for
    # filename operands that follow it on the command line.
    tar xzf "$tarfile" -C rpmbuild/SPECS --wildcards '*/packaging/rpm/percona-kvrocks.spec' --strip-components=3
    mv "$tarfile" rpmbuild/SOURCES/
    local spec="rpmbuild/SPECS/${PACKAGE_NAME}.spec"
    sed -i "s/^Version:.*$/Version:        ${VERSION}/" "$spec"
    sed -i "s/^Release:.*$/Release:        ${RELEASE}%{?dist}/" "$spec"
    rpmbuild -bs --define "_topdir ${WORKDIR}/rpmbuild" --define "dist .generic" "$spec"
    copy_artifacts "srpm" rpmbuild/SRPMS/*.src.rpm
}

build_rpm() {
    [[ "$RPM" -eq 1 ]] || return 0
    [[ "$OS" == "rpm" ]] || die "Cannot build rpm on a non-RPM system"
    cd "$WORKDIR"
    find_and_copy_artifact "srpm" "${PACKAGE_NAME}-*.src.rpm"
    local src_rpm="$FOUND_FILE"
    rm -rf rb
    mkdir -p rb/{SOURCES,SPECS,BUILD,SRPMS,RPMS,BUILDROOT}
    mv "$src_rpm" rb/SRPMS/
    rpmbuild --define "_topdir ${WORKDIR}/rb" --define "dist .${OS_NAME}" \
        --rebuild "rb/SRPMS/${src_rpm}"
    copy_artifacts "rpm" rb/RPMS/*/*.rpm
}

build_source_deb() {
    [[ "$SDEB" -eq 1 ]] || return 0
    [[ "$OS" == "deb" ]] || die "Cannot build source deb on a non-DEB system"
    cd "$WORKDIR"
    rm -rf "${PACKAGE_NAME}-${VERSION}" ./*.dsc ./*.orig.tar.gz ./*.debian.tar.* ./*_source.changes
    find_and_copy_artifact "source_tarball" "${PACKAGE_NAME}-*.tar.gz"
    local tarfile="$FOUND_FILE"
    mv "$tarfile" "${PACKAGE_NAME}_${VERSION}.orig.tar.gz"
    tar xzf "${PACKAGE_NAME}_${VERSION}.orig.tar.gz"
    cd "${PACKAGE_NAME}-${VERSION}"
    cp -r packaging/debian ./debian
    # debian/changelog is checked in with the release's own top entry
    # already at ${VERSION}-${RELEASE}; only add a new stanza when that
    # isn't already the case (e.g. a different --version/--release), so a
    # default run doesn't ship two consecutive identical-version entries.
    local current_version
    current_version="$(dpkg-parsechangelog -S Version)"
    if [[ "$current_version" != "${VERSION}-${RELEASE}" ]]; then
        dch -D unstable --force-distribution -v "${VERSION}-${RELEASE}" \
            "Update to ${PACKAGE_NAME} ${VERSION}"
    fi
    dpkg-buildpackage -S -us -uc -d
    cd "$WORKDIR"
    copy_artifacts "source_deb" ./*_source.changes ./*.dsc ./*.orig.tar.gz ./*.debian.tar.*
}

build_deb() {
    [[ "$DEB" -eq 1 ]] || return 0
    [[ "$OS" == "deb" ]] || die "Cannot build deb on a non-DEB system"
    local f
    for f in dsc orig.tar.gz debian.tar.xz; do
        find_and_copy_artifact "source_deb" "${PACKAGE_NAME}_*.${f}"
    done
    cd "$WORKDIR"
    rm -rf "${PACKAGE_NAME}-${VERSION}" ./*.deb ./*.ddeb
    dpkg-source -x "${PACKAGE_NAME}_${VERSION}-${RELEASE}.dsc"
    cd "${PACKAGE_NAME}-${VERSION}"
    dch -m -D "$OS_NAME" --force-distribution \
        -v "${VERSION}-${RELEASE}.${OS_NAME}" "Update distribution"
    dpkg-buildpackage -rfakeroot -us -uc -b
    cd "$WORKDIR"
    echo "DEBIAN=${OS_NAME}" >> kvrocks.properties
    echo "ARCH=${ARCH}" >> kvrocks.properties
    # dbgsym packages are .ddeb on older dpkg, .deb-named on newer; nullglob
    # avoids passing a literal unmatched "*.ddeb" to copy_artifacts.
    shopt -s nullglob
    local ddebs=( ./*.ddeb )
    shopt -u nullglob
    copy_artifacts "deb" ./*.deb "${ddebs[@]}"
}

print_settings() {
    local v
    for v in WORKDIR SOURCE SRPM RPM SDEB DEB INSTALL LOCAL_BUILD REPO BRANCH VERSION RELEASE; do
        printf '%s=%s\n' "$v" "${!v}"
    done
}

CURDIR="$(pwd)"
WORKDIR=""
SOURCE=0; SRPM=0; RPM=0; SDEB=0; DEB=0; INSTALL=0; LOCAL_BUILD=0
REPO="$DEFAULT_REPO"; BRANCH="$DEFAULT_BRANCH"; VERSION="$DEFAULT_VERSION"; RELEASE="$DEFAULT_RELEASE"
OS=""; OS_NAME=""; PLATFORM_FAMILY=""; RHEL="0"; ARCH=""; FOUND_FILE=""

parse_arguments "$@"
check_workdir

if [[ "${KVROCKS_BUILDER_DRY_RUN:-0}" == "1" ]]; then
    print_settings
    exit 0
fi

get_system
install_deps
get_sources
build_srpm
build_rpm
build_source_deb
build_deb

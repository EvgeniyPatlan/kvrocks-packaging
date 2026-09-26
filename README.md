# kvrocks-packaging

RPM and DEB packaging for [Apache Kvrocks](https://kvrocks.apache.org) as `percona-kvrocks`.

## Packages

- `percona-kvrocks-server` — `kvrocks`, `/etc/kvrocks/kvrocks.conf`, `kvrocks.service`
- `percona-kvrocks-tools` — `kvrocks2redis`

## Build

All steps use `scripts/kvrocks_builder.sh`. `--builddir` is required and must differ from the current directory.

```bash
mkdir -p /tmp/BUILD

# source tarball (vendors all third-party dependencies)
scripts/kvrocks_builder.sh --builddir=/tmp/BUILD --install_deps --get_sources \
  --version=2.17.0 --branch=v2.17.0 --use_local_packaging_script

# RPM host
scripts/kvrocks_builder.sh --builddir=/tmp/BUILD --install_deps --build_src_rpm --build_rpm

# DEB host
scripts/kvrocks_builder.sh --builddir=/tmp/BUILD --install_deps --build_src_deb --build_deb
```

Output: `source_tarball/`, `srpm/`, `rpm/`, `source_deb/`, `deb/` in the build directory and the current directory.
The SBOM is installed under `/usr/share/percona-kvrocks/sbom/`.

## Test

```bash
scripts/test_in_docker.sh --pkg-dir=./rpm --all --version=2.17.0
scripts/test_in_docker.sh --pkg-dir=./deb --image=ubuntu:noble --version=2.17.0
tests/run.sh
```

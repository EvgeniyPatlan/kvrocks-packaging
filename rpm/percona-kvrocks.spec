%global srcname percona-kvrocks
# EL10 and Amazon Linux 2023 auto-export hardened CFLAGS/LDFLAGS (-pie,
# via redhat-hardened-ld) at the start of the build section; vendored
# LuaJIT's Makefile picks up LDFLAGS while linking its host/minilua tool
# without a matching PIE-enabled compile, breaking the link. EL8/EL9
# never auto-export these flags, which is why only EL10/AL2023 hit it.
# The controlling macro must be undefined, not set to zero, to suppress
# the auto-export (redhat/macros only checks whether it is defined at
# all); undefining a macro that was never defined is a safe no-op, so
# this line is harmless on EL8/EL9.
%undefine _auto_set_build_flags

Name:           percona-kvrocks
Version:        2.17.0
Release:        1%{?dist}
Summary:        Apache Kvrocks, a Redis-protocol compatible key-value database on RocksDB
License:        Apache-2.0
URL:            https://kvrocks.apache.org
Source0:        %{srcname}-%{version}.tar.gz

%if 0%{?rhel} == 8 || 0%{?rhel} == 9
BuildRequires:  gcc-toolset-12-gcc
BuildRequires:  gcc-toolset-12-gcc-c++
BuildRequires:  gcc-toolset-12-libstdc++-devel
BuildRequires:  gcc-toolset-12-annobin-plugin-gcc
%else
BuildRequires:  gcc
BuildRequires:  gcc-c++
BuildRequires:  libstdc++-static
%endif
BuildRequires:  cmake >= 3.16
BuildRequires:  make
BuildRequires:  autoconf
BuildRequires:  automake
BuildRequires:  libtool
BuildRequires:  git
BuildRequires:  python3
BuildRequires:  perl
BuildRequires:  openssl-devel
BuildRequires:  systemd-rpm-macros

%description
Apache Kvrocks is a distributed key-value NoSQL database that uses RocksDB
as its storage engine and is compatible with the Redis protocol.

%package server
Summary:        Apache Kvrocks server
Requires(pre):  shadow-utils
%{?systemd_requires}

%description server
Apache Kvrocks server daemon, configuration and systemd unit.

%package tools
Summary:        Apache Kvrocks tools

%description tools
kvrocks2redis, a tool that replicates Kvrocks data to a Redis-protocol server.

%prep
%autosetup -n %{srcname}-%{version}

%build
%if 0%{?rhel} == 8 || 0%{?rhel} == 9
. /opt/rh/gcc-toolset-12/enable
%endif
# CMake's FetchContent extraction (libarchive) needs a UTF-8 locale to read
# non-ASCII member names in vendored dep archives (e.g. PEGTL's test fixtures);
# the rpmbuild scriptlet environment defaults to POSIX/C.
export LC_ALL=C.utf8
cmake -S . -B build \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DDEPS_FETCH_DIR="$PWD/deps" \
    -DENABLE_OPENSSL=ON \
    -DPORTABLE=1
cmake --build build %{?_smp_mflags} --target kvrocks kvrocks2redis

%install
install -Dpm 0755 build/kvrocks %{buildroot}%{_bindir}/kvrocks
install -Dpm 0755 build/kvrocks2redis %{buildroot}%{_bindir}/kvrocks2redis
sh packaging/common/prepare-conf.sh kvrocks.conf kvrocks.conf.packaged
install -Dpm 0640 kvrocks.conf.packaged %{buildroot}%{_sysconfdir}/kvrocks/kvrocks.conf
install -Dpm 0644 packaging/common/kvrocks.service %{buildroot}%{_unitdir}/kvrocks.service
install -d -m 0750 %{buildroot}%{_sharedstatedir}/kvrocks %{buildroot}%{_localstatedir}/log/kvrocks
install -Dpm 0644 sbom/%{name}.spdx.json %{buildroot}%{_datadir}/%{name}/sbom/%{name}.spdx.json
install -Dpm 0644 sbom/%{name}.cdx.json %{buildroot}%{_datadir}/%{name}/sbom/%{name}.cdx.json
cp utils/kvrocks2redis/kvrocks2redis.conf kvrocks2redis.conf.example

%pre server
getent group kvrocks >/dev/null || groupadd -r kvrocks
getent passwd kvrocks >/dev/null || \
    useradd -r -g kvrocks -d %{_sharedstatedir}/kvrocks -s /sbin/nologin -c "Apache Kvrocks" kvrocks
exit 0

%post server
%systemd_post kvrocks.service

%preun server
%systemd_preun kvrocks.service

%postun server
%systemd_postun_with_restart kvrocks.service

%files server
%license LICENSE NOTICE
%doc README.md
%{_bindir}/kvrocks
%dir %attr(0750,root,kvrocks) %{_sysconfdir}/kvrocks
%config(noreplace) %attr(0640,root,kvrocks) %{_sysconfdir}/kvrocks/kvrocks.conf
%{_unitdir}/kvrocks.service
%dir %attr(0750,kvrocks,kvrocks) %{_sharedstatedir}/kvrocks
%dir %attr(0750,kvrocks,kvrocks) %{_localstatedir}/log/kvrocks
%{_datadir}/%{name}

%files tools
%license LICENSE NOTICE
%doc kvrocks2redis.conf.example
%{_bindir}/kvrocks2redis

%changelog
* Fri Sep 25 2026 Evgeniy Patlan <evgeniy.patlan@percona.com> - 2.17.0-1
- Initial packaging

# ReiNAS 系统身份包
#
# 作用：把「Fedora 45」变成「ReiNAS 0.2.0」，同时保留一切让 Fedora 仓库、
# 依赖解析、第三方工具继续正常工作的元数据。
#
# 设计原则：**改身份，不改兼容性。**
#   外观（os-release / CPE / issue）        → ReiNAS
#   机制（dist 宏 / preset / releasever）   → 原样保留
#
# 升级到 Fedora 46 时需要改的只有三处（都在本文件或同级 files/ 里）：
#   1. 下面的 %global fedora_release
#   2. files/os-release 的 VERSION / PLATFORM_ID / CPE_NAME
#   3. files/releasever 与 files/system-release-cpe

%global fedora_release 45

# 纯数据包：没有上游 tarball，直接以 spec 所在目录为源。
%global srcroot %{_sourcedir}

Name:           reinas-release
Version:        0.2.0
Release:        1%{?dist}
Summary:        ReiNAS release files and system identity

License:        MIT
URL:            https://github.com/ReiNAS-OS
BuildArch:      noarch
BuildRequires:  systemd-rpm-macros

# ─────────────────────────────────────────────────────────────────────
# 兼容性层
# ─────────────────────────────────────────────────────────────────────

Provides:       system-release
Provides:       system-release(%{fedora_release})

# ⚠️ 关键行：libdnf 的 detect_releasever() 优先读这个 provide 的值，
#    而不是包本身的 Version。没有它 $releasever 会变成 0.2.0，
#    于是 metalink?repo=fedora-$releasever 全部 404。
Provides:       system-release(releasever) = %{fedora_release}

Provides:       fedora-release = %{fedora_release}
Provides:       fedora-release-common = %{fedora_release}
Provides:       fedora-release-identity-container = %{fedora_release}
Provides:       fedora-release-container = %{fedora_release}
Provides:       fedora-release-server = %{fedora_release}

Obsoletes:      fedora-release <= %{fedora_release}
Obsoletes:      fedora-release-common <= %{fedora_release}
Obsoletes:      fedora-release-identity-container <= %{fedora_release}
Obsoletes:      fedora-release-container <= %{fedora_release}
Obsoletes:      fedora-release-server <= %{fedora_release}

Requires:       dnf5
Requires:       systemd

%description
ReiNAS release files: system identity (/etc/os-release, CPE name, login
banners) plus the Fedora compatibility metadata (RPM dist macros, systemd
presets, DNF defaults) needed for Fedora repositories and third-party tools
to keep working, and the $releasever override that pins the base release.

This package replaces the fedora-release package family.

%prep
# 刻意不使用 Source0 和 %setup：
# RPM 6.0 会自动解包 Source0，而 GNU tar 在 Apple Silicon + Rosetta 的
# x86_64 模拟环境里会报 ENOSYS（Function not implemented）。
# 这是纯数据包，install 段直接从源目录取文件即可。

%build
# 纯数据包，无需构建

%install
cd %{srcroot}

install -d %{buildroot}%{_prefix}/lib
install -d %{buildroot}%{_sysconfdir}/dnf/vars
install -d %{buildroot}%{_rpmconfigdir}/macros.d
install -d %{buildroot}%{_presetdir}
install -d %{buildroot}%{_userpresetdir}
install -d %{buildroot}%{_datadir}/dnf5/libdnf.conf.d

# ── 系统身份 ─────────────────────────────────────────────────────────
install -m 0644 files/os-release         %{buildroot}%{_prefix}/lib/os-release
install -m 0644 files/reinas-release     %{buildroot}%{_prefix}/lib/reinas-release
install -m 0644 files/system-release-cpe %{buildroot}%{_prefix}/lib/system-release-cpe
install -m 0644 files/issue              %{buildroot}%{_prefix}/lib/issue
install -m 0644 files/issue.net          %{buildroot}%{_prefix}/lib/issue.net

ln -sf ../usr/lib/os-release         %{buildroot}%{_sysconfdir}/os-release
ln -sf ../usr/lib/reinas-release     %{buildroot}%{_sysconfdir}/reinas-release
ln -sf ../usr/lib/system-release-cpe %{buildroot}%{_sysconfdir}/system-release-cpe
ln -sf ../usr/lib/issue              %{buildroot}%{_sysconfdir}/issue
ln -sf ../usr/lib/issue.net          %{buildroot}%{_sysconfdir}/issue.net

# 兼容文件：很多第三方脚本只检查这两个文件是否存在
install -m 0644 files/reinas-release %{buildroot}%{_sysconfdir}/redhat-release
install -m 0644 files/reinas-release %{buildroot}%{_sysconfdir}/system-release

# ── $releasever 覆盖 ────────────────────────────────────────────────
install -m 0644 files/releasever %{buildroot}%{_sysconfdir}/dnf/vars/releasever

# ── Fedora 兼容元数据（原样复制，一个字不改）────────────────────────
install -m 0644 base/macros.dist            %{buildroot}%{_rpmconfigdir}/macros.d/macros.dist
install -m 0644 base/system-preset/*.preset %{buildroot}%{_presetdir}/
install -m 0644 base/user-preset/*.preset   %{buildroot}%{_userpresetdir}/
install -m 0644 files/dnf-defaults.conf     %{buildroot}%{_datadir}/dnf5/libdnf.conf.d/20-reinas-defaults.conf

# ── 许可证 ──────────────────────────────────────────────────────────
install -d %{buildroot}%{_datadir}/licenses/%{name}
install -m 0644 LICENSE %{buildroot}%{_datadir}/licenses/%{name}/LICENSE

%post
# 不调用 systemctl preset-all：
# preset 只在 unit 首次安装时生效，强制重跑会关掉用户手动 enable 的服务。

%files
%license %{_datadir}/licenses/%{name}/LICENSE

%{_prefix}/lib/os-release
%{_prefix}/lib/reinas-release
%{_prefix}/lib/system-release-cpe
%{_prefix}/lib/issue
%{_prefix}/lib/issue.net
%{_sysconfdir}/os-release
%{_sysconfdir}/reinas-release
%{_sysconfdir}/system-release-cpe
%config(noreplace) %{_sysconfdir}/issue
%config(noreplace) %{_sysconfdir}/issue.net
%{_sysconfdir}/redhat-release
%{_sysconfdir}/system-release

%dir %{_sysconfdir}/dnf/vars
%{_sysconfdir}/dnf/vars/releasever

%{_rpmconfigdir}/macros.d/macros.dist
%{_presetdir}/85-display-manager.preset
%{_presetdir}/90-default.preset
%{_presetdir}/99-default-disable.preset
%{_userpresetdir}/90-default-user.preset
%{_userpresetdir}/99-default-disable.preset
%{_datadir}/dnf5/libdnf.conf.d/20-reinas-defaults.conf

%changelog
* Sun Nov 23 2026 ReiNAS <dev@reinas.invalid> - 0.2.0-1
- 迁移到 Fedora 45 基线
- 收敛为最小 NAS 包集

* Sat Oct 10 2026 mouyase <mouyase@users.noreply.github.com> - 0.1.0-1
- 初始版本，基于 Fedora 44

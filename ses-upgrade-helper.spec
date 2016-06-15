#
# spec file for package ses-upgrade-helper
#
# Copyright (c) 2016 SUSE LINUX Products GmbH, Nuernberg, Germany.
#
# All modifications and additions to the file contributed by third parties
# remain the property of their copyright owners, unless otherwise agreed
# upon. The license for this file, and modifications and additions to the
# file, is the same license as for the pristine package itself (unless the
# license for the pristine package is not an Open Source License, in which
# case the license is the MIT License). An "Open Source License" is a
# license that conforms to the Open Source Definition (Version 1.9)
# published by the Open Source Initiative.

# Please submit bugfixes or comments via http://bugs.opensuse.org/
#

Name:         ses-upgrade-helper
Summary:      SES upgrade helper script
Version:      0.1
Release:      1
License:      GPL-2.0
Group:        Productivity/Other
URL:          https://github.com/SUSE/ses-upgrade-helper
Source:       ses-upgrade-helper-%{version}.tar.xz
BuildArch:    noarch

%description
Script to help the admin upgrade cluster nodes from SES 2.1 to SES 3

%prep
%setup -q

%build

%install
cd src
make DESTDIR=%{buildroot} install
cd ../man
make DESTDIR=%{buildroot} install

%clean
rm -rf %{buildroot}

%files
%defattr(-,root,root)
%doc AUTHORS LICENSE README
%{_bindir}/upgrade-to-ses3.sh
%{_mandir}/man8/upgrade-to-ses3.sh.8*

%changelog


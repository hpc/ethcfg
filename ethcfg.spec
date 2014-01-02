%define	_source_filedigest_algorithm	md5
%define	_binary_filedigest_algorithm	md5

Summary: Perform external ethernet device configuration
Name: ethcfg
Version: 1.0
Release: 19%{?dist}
Group: Applications/System
Source0: %{name}.pl
Source1: %{name}.sysconfig
BuildRoot: %{_tmppath}/%{name}-%{version}-root
License: LANL
Requires: perl net-tools module-init-tools iputils /sbin/ip /sbin/service /sbin/chkconfig
BuildArch: noarch
Packager: dwg@lanl.gov

%description
System startup script configuring external ethernet devices and hostnames.

# no prep required
#%setup

# no build required
#%build

%install
umask 022
%{__rm} -rf $RPM_BUILD_ROOT

%{__mkdir_p} $RPM_BUILD_ROOT%{_initrddir}
%{__install} -m 0755 %SOURCE0 $RPM_BUILD_ROOT%{_initrddir}/%{name}

%{__mkdir_p} $RPM_BUILD_ROOT%{_sysconfdir}/sysconfig
%{__install} -m 0644 %SOURCE1 $RPM_BUILD_ROOT%{_sysconfdir}/sysconfig/%{name}

%{__mkdir_p} $RPM_BUILD_ROOT%{_mandir}/man1
pod2man %SOURCE0 $RPM_BUILD_ROOT%{_mandir}/man1/%{name}.1

%clean
%{__rm} -rf $RPM_BUILD_ROOT

%post
if [ "$1" = 1 ]; then
   /sbin/chkconfig --add %{name}
   /sbin/chkconfig %{name} off
fi

%preun
if [ "$1" = 0 ]; then
   /sbin/service %{name} stop > /dev/null 2>&1
   /sbin/chkconfig --del %{name} > /dev/null 2>&1
fi

%files
%defattr(-,root,root)
%attr(0755,root,root) %{_initrddir}/%{name}
%attr(0644,root,root) %config(noreplace) %{_sysconfdir}/sysconfig/%{name}
%attr(0644,root,root) %{_mandir}/man1/%{name}.1.gz

%changelog
* Wed Jul 31 2013 Daryl W. Grunau <dwg@lanl.gov> 1.0-19
- Suse chkconfig Required-Start=$local_fs+dbus and Required-Stop=$null to get
  this started early in the boot cycle.

* Mon Jul 29 2013 Daryl W. Grunau <dwg@lanl.gov> 1.0-18
- Provide a "generate" target which produces Interface Rulesets on STDOUT to
  aid the population of config files; document this.

* Wed Jun 27 2012 Daryl W. Grunau <dwg@lanl.gov> 1.0-17
- option --[no]ping-cache to cache ping responses when evaluating ECMP
  routes; document this.
- bugfix: process kmods in the order in which their associated devices
  appear in the config file.
- Generate a "universal" {S}RPM that can be built on/for any platform by
  setting the _source_filedigest_algorithm and _binary_filedigest_algorithm
  to the lowest common denominator (md5).

* Tue Mar 20 2012 Daryl W. Grunau <dwg@lanl.gov> 1.0-16
- option --force to force a reconfiguration when no change is detected; document this.
- option --[no]blocking to prevent/require such behavior; document this.
- bugfix: process rulesets in the order in which they appear in the config file.
- warn if no ruleset matches for the host on which ethcfg was run.
- bind ECMP ping to the src IP in the config file, if provided.
- show ECMP route progress.

* Sat Jan 07 2012 Daryl W. Grunau <dwg@lanl.gov> 1.0-15
- buffer warnings to syslog at the end of execution.
- exact-match user-defined variables during config parsing.
- bugfix: variable expansion was not well-defined in the case where
  a var was defined which was a substring of another.
- improve "die" messages.

* Thu Oct 27 2011 Daryl W. Grunau <dwg@lanl.gov> 1.0-14
- print to STDOUT, not STDERR.
- restart and status functions.
- cache currently loaded kmods; don't load if unnecessary.
- identify all required kmods in a single pass and load initially.
- only (re)set link and MTU if necessary.
- only (re)route if necessary.
- permit DEBUG and VERBOSE keywords in the config file to enable/disable
  contextually; document this.

* Mon Sep 26 2011 Daryl W. Grunau <dwg@lanl.gov> 1.0-13
- really support a route-only rule through a (supplied) device; document this.

* Mon Sep 19 2011 Daryl W. Grunau <dwg@lanl.gov> 1.0-12
- block-retry if no accessible ECMP route is found.

* Wed Jul 27 2011 Daryl W. Grunau <dwg@lanl.gov> 1.0-11
- slightly older perl versions don't support \K (see perlre(1)).

* Wed Jul 13 2011 Daryl W. Grunau <dwg@lanl.gov> 1.0-10
- don't set the hostname of a host that is already correct.
- don't set connected mode on a host that is already set.

* Wed Jul 13 2011 Daryl W. Grunau <dwg@lanl.gov> 1.0-9
- don't try to ifenslave a device which is already enslaved.

* Fri Jul 08 2011 Daryl W. Grunau <dwg@lanl.gov> 1.0-8
- option --dry-run; document this.

* Thu Jul 07 2011 Daryl W. Grunau <dwg@lanl.gov> 1.0-7
- modprobe slave device kmod aliases too.

* Thu Jul 07 2011 Daryl W. Grunau <dwg@lanl.gov> 1.0-6
- modprobe as many kmod aliases as there are defined for device (permitting
  heterogeneous hardware).

* Wed Jul 06 2011 Daryl W. Grunau <dwg@lanl.gov> 1.0-5
- modprobe any aliases listed for devices in the configuration file, unless
  the alias is "off" or the install cmd is "/bin/true"; document this.
- Only add an IP address to device if it does not match any existing
  assignment (if any).

* Wed Jul 06 2011 Daryl W. Grunau <dwg@lanl.gov> 1.0-4
- S13 -> S10 for RH.
- Print the device for which carrier is 'OK'.

* Sat Jun 25 2011 Daryl W. Grunau <dwg@lanl.gov> 1.0-3
- Set IB connected mode before link/mtu up.

* Fri Jun 24 2011 Daryl W. Grunau <dwg@lanl.gov> 1.0-2
- S09 -> S13 for RH.

* Fri Jun 24 2011 Daryl W. Grunau <dwg@lanl.gov> 1.0-1
- Support RedHat chkconfig syntax.
- Permit ECMP gw definition & validation (ping w/ backoff).
- Support for Perceus/Warewulf node gleaning from /proc/cmdline.
- New cmdline options: --debug, --verbose, --help, --man.
- Permit the assignment of a variable in the config file.
- Check if a node has multiple hostname assignments.
- Check if a device has multiple MTU assignments.
- Check carrier on ifenslaved devices 
- Support IB devices; set connected mode if MTU > 2044.
- Deprecate use of /sbin/ifconfig; solely use /sbin/ip.
- Modified BSD license and HPC Operational Suite LA-CC.
- Update the sample sysconfig file with new examples.
- POD documentation.

* Tue Mar 22 2011 Daryl W. Grunau <dwg@lanl.gov> 0.1-2
- Sanity checks for valid IPs, prefixes and conflicting/duplicate routes.
- ENHANCEMENT: permit a non-default gateway (a.k.a. "route") to specified
  network(s) via additional field in the config file, comma separated.
  Specifying a GW but not providing said network(s) implies the GW will be
  the default route, for backward compatibility.
- Better describe the RPM Requires of this package.

* Wed Oct 20 2010 Daryl W. Grunau <dwg@lanl.gov> 0.1-1SSI
- First cut

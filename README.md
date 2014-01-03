ethcfg
======

Perform external ethernet interface configuration and hostnames

Usage
-----
ethcfg will install itself as a sysv init script.  Add configuration to the /etc/sysconfig/ethcfg file.  All node definitions can be in the same file as ethcfg will only honor lines begining with the current hostname.  We have found that DHCP can be chatty and unstable on a large network.  ethcfg offers static IP configuration of all interfaces of all nodes within a single file.  The only trick needed is to get the hostname before interface configuration.  This has been done in several ways, but here are the ones currently used:

2 stage boot (original warewulf/xcat1, and perceus):
```
stage 1: boot generic kernel/initramfs
get host information from server
download stage 2 kernel and initramfs
pass host information on the APPEND line
stage 2: kexec new kernel/initramfs/custom APPEND
```

or generate pxe config files with hostname (genpxe, xcat2):
see [genpxe](http://github.com/hpc/genpxe)

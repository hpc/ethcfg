#!/usr/bin/perl -w
#
# Copyright (C) 2013  Daryl W. Grunau
#
# Unless otherwise indicated, this information has been authored by an employee
# or employees of the Los Alamos National Security, LLC (LANS), operator of the
# Los Alamos National Laboratory under Contract No.  DE-AC52-06NA25396 with the
# U.S. Department of Energy.  The U.S. Government has rights to use, reproduce,
# and distribute this information. The public may copy and use this information
# without charge, provided that this Notice and any statement of authorship are
# reproduced on all copies. Neither the Government nor LANS makes any warranty,
# express or implied, or assumes any liability or responsibility for the use of
# this information.
#
# This program has been approved for release from LANS by LA-CC Number 10-066,
# being part of the HPC Operational Suite.
#

#
# ethcfg               Configure external ethernet interfaces and hostnames
#
# chkconfig: 2345 10 90
# description: Perform external ethernet interface configuration and hostnames
# processname: none
# config: /etc/sysconfig/ethcfg

### BEGIN INIT INFO
# Provides:            ethcfg
# Required-Start:      $local_fs dbus
# Required-Stop:       $null
# X-UnitedLinux-Should-Start:
# X-UnitedLinux-Should-Stop:
# Default-Start:       2 3 5
# Default-Stop:        0 1 6
# Description:         Perform external ethernet interface configuration and hostnames
### END INIT INFO


$| = 1;
(our $prog = $0) =~ s|.*/(S\d{2,2})?||;

# Backoff retry options
our $BACKOFF_min = 1;		# never delay less than BACKOFF_min (sec) per try
our $BACKOFF_max = 5;		# never delay more than BACKOFF_max (sec) per try
our $BACKOFF_tot = 30;		# never delay more than BACKOFF_tot (sec) aggregate

our $BACKOFF_rnd = 0.1;		# random fudge factor (+-)
our $BACKOFF_pow = 1.2;		# backoff factor

our $tired = 0;			# backed off (bool)?
our %RC = ();			# control hash

# Blocking options
our $blocked = 0;		# blocked count
our $BLOCKING_max = 2;		# never block more than BLOCKING_max times

use Socket;
use Net::Ping;
use Pod::Usage;
use Getopt::Long;
use Sys::Hostname;
our $FQDN = hostname || die "unable to determine hostname!\n";

&Getopt::Long::config('bundling');		# allow bundling of options

# Help options
our $opt_man;
our $opt_help;
our $opt_debug = undef;
our $opt_verbose = undef;
# Service options
our $opt_force;
our $opt_blocking = undef;
our $opt_pingcache = undef;
our $opt_file = '/etc/sysconfig/ethcfg';
# Generate options
our $opt_cidr;
our @opt_nodes;
our $opt_interface;
our $opt_mtu = undef;
our $opt_hostname = '*';
our $opt_gateway = undef;
our $opt_network = undef;

pod2usage(2) unless &GetOptions(
# Help options
   'd|n|debug|dry-run!'		=> \$opt_debug,		# [don't] dry-run
   'h|help'			=> \$opt_help,		# help
   'man'			=> \$opt_man,		# print the manpage
   'v|verbose!'			=> \$opt_verbose,	# [don't] be verbose
# Sercice options
   'b|blocking!'		=> \$opt_blocking,	# [don't] permit blocking
   'c|config=s'			=> \$opt_file,		# config file
   'force'			=> \$opt_force,		# force {re}configuration
   'p|ping-cache|cache-ping!'	=> \$opt_pingcache,	# [don't] cache ping responses
# Generate options
   'gw|gateway=s'		=> \$opt_gateway,	# specify a GW
   'hostname=s'			=> \$opt_hostname,	# specify a Host
   'ipaddr=s'			=> \$opt_cidr,		# specify an IP/Prefix
   'if|interface=s'		=> \$opt_interface,	# specify an IF
   'mtu=s'			=> \$opt_mtu,		# specify an MTU
   'nodes=s'			=> \@opt_nodes,		# specify a Node
   'nw|network=s'		=> \$opt_network,	# specify a NW/Prefix
);

pod2usage(1) if ($opt_help);
if ($opt_man) {				# print the man page
   $ENV{'LANG'} = 'C';
   if ($< && $>) {			# no root privs
      pod2usage(-verbose => 2);
   } else {
      my $id = getpwnam("nobody") || getpwnam("nouser") || -2;
      eval {
	 $> = $id;			# drop euid first
	 $< = $id;			# drop ruid
      };
      if (!$@ && $< && $>) {		# success!
	 pod2usage(-verbose => 2)
      } else {				# failure!
	 pod2usage(1);
      }
   }
}

pod2usage(1) unless ((scalar(@ARGV) == 1));
pod2usage(1) unless (
   ($ARGV[0] eq 'generate') ||
   ($ARGV[0] eq 'restart')  ||
   ($ARGV[0] eq 'start')    ||
   ($ARGV[0] eq 'status')   ||
   ($ARGV[0] eq 'stop')
);

our $action = $ARGV[0];

our $blocking;
if (defined($opt_blocking)) {
   $blocking = $opt_blocking;
} else {
   $blocking = 1;			# block by default
}

our $debug;
if (defined($opt_debug)) {
   $debug = $opt_debug;
} else {
   $debug = 0;				# non-debug by default
}

our $pingcache;
if (defined($opt_pingcache)) {
   $pingcache = $opt_pingcache;
} else {
   $pingcache = 1;			# cache ping responses by default
}

our $verbose;
if (defined($opt_verbose)) {
   $verbose = $opt_verbose;
} else {
   $verbose = 0;			# non-verbose by default
}

our %HOSTENT = ();
our $HOSTNAME = undef;

our @Warnings = ();

sub __WARN__signal_handler {
   my $string = $_[0];

   push (@Warnings, $string);
   print STDOUT "   $string";
   return 0;
}

sub __DIE__signal_handler {
   my $string = $_[0];

   use Sys::Syslog;

   my $priority = ($debug ? LOG_INFO : LOG_ERR);
   openlog("$prog\[$$\]", 'ndelay', LOG_DAEMON);
   foreach my $warning (@Warnings) {
      syslog($priority, $warning);
   }
   syslog($priority, $string);
   closelog;

   print STDOUT "$prog\[$$\]: $string";
   exit -1;
}


# Process my config file of one of the following forms:
# (1) identifier = value
# (2) Node  Hostname  DEV[=if[,if]]  IPaddr/Prefix  MTU  Route[,Route]  Network/Prefix[,Network/Prefix]
sub get_config () {

   use POSIX qw(:limits_h);

   my $NODE = undef;
   my $NODEre = undef;
   my $HasMatch = 0;

   my %HasDevMTU = ();
   my $HasDefRoute = undef;

   my $CFGre = undef;
   my %CFGvars = ();

   my %MODALIAS = ();		# cache of the effective kmod configuration

   # Get my node name
   if (-e '/proc/cray_xt/cname') {
      open (CNAME, '/proc/cray_xt/cname') || die "/proc/cray_xt/cname: $!\n";
      $NODE = <CNAME>; chomp $NODE;
      close CNAME;
   } elsif (open (CMDLINE, '/proc/cmdline')) {
      my $cmdline = <CMDLINE>;
      close CMDLINE;
      if ($cmdline =~ /node=(\S+)/i) {
	 $NODE = $1;
      } else {
	 ($NODE = $FQDN) =~ s/\..*$//g;		# hostname -s
      }
   } else {
      ($NODE = $FQDN) =~ s/\..*$//g;		# hostname -s
   }
   $NODEre = qr/^\Q$NODE\E\s+/io;

   # Parse the config file
   open (CFG, $opt_file) || die "$opt_file: $!\n";
   while (defined(my $hostent = <CFG>)) {

      next if ($hostent =~ /^#/);	# skip comments
      next if ($hostent =~ /^\s*$/);	# skip whitespace

      # Permit the assignment of a variable to a value.  The variable MUST
      # follow the form of a valid perl scalar, namely a string beginning with
      # a letter or underscore followed by any combination of letters,
      # underscores, or digits.  This code will simply auto-vivify the
      # variable as a hash key and substitute value in CFG *thereafter*.
      # Valid syntax for variable assignment: (1) identifier resides in first
      # column (2) followed by optional white space (3) followed by '=' (4)
      # followed by optional whitespace (5) followed by value, which can
      # contain whitespace, and/or can be enclosed by single or double quotes.
      if ($hostent =~ /^([_a-z]+\w+)\s*=\s*[\'\"]?(.*?)[\'\"]?$/i) {
	 my $key = $1; my $value = $2;

	 # contextual blocking setting
	 if ($key =~ /^blocking$/i) {
	    if ((($value =~ /^\d+$/) && ($value > 0)) || ($value =~ /^(on|yes|true)$/i)) {
	       $blocking = 1 unless 		# cmdline overrides config file
		  (defined($opt_blocking) && ($opt_blocking == 0));
	    } elsif ((($value =~ /^\d+$/) && ($value == 0)) || ($value =~ /^(off|no|false)$/i)) {
	       $blocking = 0 unless 		# cmdline overrides config file
		  ((defined($opt_blocking) && $opt_blocking == 1));
	    }
	    next;
	 }

	 # contextual debug setting
	 if ($key =~ /^debug$/i) {
	    if ((($value =~ /^\d+$/) && ($value > 0)) || ($value =~ /^(on|yes|true)$/i)) {
	       $debug = 1 unless 		# cmdline overrides config file
		  (defined($opt_debug) && ($opt_debug == 0));
	    } elsif ((($value =~ /^\d+$/) && ($value == 0)) || ($value =~ /^(off|no|false)$/i)) {
	       $debug = 0 unless 		# cmdline overrides config file
		  ((defined($opt_debug) && $opt_debug == 1));
	    }
	    next;
	 }

	 # contextual pingcache setting
	 if ($key =~ /^pingcache$/i) {
	    if ((($value =~ /^\d+$/) && ($value > 0)) || ($value =~ /^(on|yes|true)$/i)) {
	       $pingcache = 1 unless 		# cmdline overrides config file
		  (defined($opt_pingcache) && ($opt_pingcache == 0));
	    } elsif ((($value =~ /^\d+$/) && ($value == 0)) || ($value =~ /^(off|no|false)$/i)) {
	       $pingcache = 0 unless 		# cmdline overrides config file
		  ((defined($opt_pingcache) && $opt_pingcache == 1));
	    }
	    next;
	 }

	 # contextual verbosity setting
	 if ($key =~ /^verbose$/i) {
	    if ((($value =~ /^\d+$/) && ($value > 0)) || ($value =~ /^(yes|true)$/i)) {
	       $verbose = 1 unless 		# cmdline overrides config file
		  (defined($opt_verbose) && ($opt_verbose == 0));
	    } elsif ((($value =~ /^\d+$/) && ($value == 0)) || ($value =~ /^(no|false)$/i)) {
	       $verbose = 0 unless	 	# cmdline overrides config file
		  ((defined($opt_verbose) && $opt_verbose == 1));
	    }
	    next;
	 }

	 print STDOUT qq|debug: assign: \$$key='$value'\n| if ($debug);
	 $CFGvars{"\$$key"} = "$value";
	 $CFGre = join('\b|', map { quotemeta($_) } keys %CFGvars) . '\b';
	 $CFGre = qr/($CFGre)/;
	 next;
      }

      # variable substitution
      if ((defined $CFGre) && ($hostent =~ /$CFGre/)) {
	 foreach my $identifier (
	    sort { length($CFGvars{$a}) <=> length($CFGvars{$b}) } keys %CFGvars
	 ) {
	    $hostent =~ s/\Q$identifier\E/$CFGvars{$identifier}/g;
	 }
      }

      next unless ($hostent =~ /$NODEre/); $HasMatch++;
      my $hostname = my $dev = my $if = my $ip_cidr = my $mtu = my $routes = my $networks = undef;
      (undef, $hostname, $dev, $ip_cidr, $mtu, $routes, $networks) = split(/\s+/, $hostent);

      if ((defined $hostname) && (length($hostname) > 1)) {
	 die "$opt_file line $.: hostname multiply defined for this host!\n"
	    if (defined($HOSTNAME));
	 $HOSTNAME = $hostname;
      }

      if ((defined $dev) && (length($dev) > 1)) {

	 # IF
	 if ($dev =~ /^([\w]+)=([\w,]+)$/) {		# e.g. bond0=eth0,eth1
	    $if = $1;
	    $HOSTENT{$if}->{'line#'} = $.
	       unless exists $HOSTENT{$if}->{'line#'};
	    $HOSTENT{$if}->{'device'} = $if;
	    foreach my $slave (split(',', $2)) {
	       push (@{ $HOSTENT{$if}->{'slaves'} }, $slave);
	    }
	 } elsif ($dev =~ /^((\w+)(:(\d+))?)$/) {	# e.g. eth0 OR eth1:0
	    $if = $1;
	    $HOSTENT{$if}->{'line#'} = $.
	       unless exists $HOSTENT{$if}->{'line#'};
	    if (defined $4) {
	       $HOSTENT{$if}->{'device'} = $2;
	       $HOSTENT{$if}->{'alias'} = $4;
	    } else {
	       $HOSTENT{$if}->{'device'} = $if;
	    }
	 } else {
	       die "$opt_file line $.: illegal device: $dev\n";
	 }

	 # IP CIDR
	 if ((defined $ip_cidr) && (length($ip_cidr) > 1)) {
	    my $ip = my $prefix = undef;
	    ($ip, $prefix) = split('/', $ip_cidr);	# w.x.y.z/p

	    if ((defined $ip) && ($ip =~ /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/)) {
	       die "$opt_file line $.: illegal IP address: $ip\n"
		  unless (($1 >= 0) && ($1 <= 256));
	       die "$opt_file line $.: illegal IP address: $ip\n"
		  unless (($2 >= 0) && ($2 <= 256));
	       die "$opt_file line $.: illegal IP address: $ip\n"
		  unless (($3 >= 0) && ($3 <= 256));
	       die "$opt_file line $.: illegal IP address: $ip\n"
		  unless (($4 >= 0) && ($4 <= 256));
	       $HOSTENT{$if}->{'ip'} = $ip;
	    } else {
	       die "$opt_file line $.: illegal IP address: $ip\n";
	    }

	    if ((defined $prefix) && ($prefix =~ /^\d+$/) && ($prefix >= 0) && ($prefix <= 32)) {
	       my $netmask = inet_ntoa( pack( 'N', ~((1<<(32-$prefix)) - 1) ) );
	       $HOSTENT{$if}->{'netmask'} = $netmask;
	       $HOSTENT{$if}->{'prefix'} = $prefix;
	    } else {
	       die "$opt_file line $.: illegal IP prefix: $prefix\n";
	    }
	 }

	 # MTU
	 if ((defined $mtu) && (length($mtu) > 1)) {
	    if (($mtu =~ /^\d+$/) && ($mtu > 0)) {
	       my $device = $HOSTENT{$if}->{'device'};
	       die "$opt_file line $.: MTU multiply defined for device $device!\n"
		  if (exists $HasDevMTU{$device});
	       $HasDevMTU{$device}++;
	       $HOSTENT{$if}->{'mtu'} = $mtu;
	       $HOSTENT{$if}->{'connected'} = 1
		  if (($mtu > 2044) && ($device =~ /^ib\d+/));
	    } else {
	       die "$opt_file line $.: illegal MTU: $mtu\n";
	    }
	 }

	 # Route(s) ...
	 if ((defined $routes) && length($routes) > 1) {
	    my @GW = ();
	    foreach my $gw (split(',', $routes)) {	# multiple routes are ECMP
	       if ($gw =~ /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/) {
		  die "$opt_file line $.: illegal GW address: $gw\n"
		     unless (($1 >= 0) && ($1 <= 256));
		  die "$opt_file line $.: illegal GW address: $gw\n"
		     unless (($2 >= 0) && ($2 <= 256));
		  die "$opt_file line $.: illegal GW address: $gw\n"
		     unless (($3 >= 0) && ($3 <= 256));
		  die "$opt_file line $.: illegal GW address: $gw\n"
		     unless (($4 >= 0) && ($4 <= 256));
		  push(@GW, $gw) unless (grep(/^\Q$gw\E$/, @GW));
	       } else {
		  die "$opt_file line $.: illegal Gateway route: $gw\n";
	       }
	    }
	    push(@{ $HOSTENT{$if}->{'gw'} }, \@GW);	# AoA

	    # ... to Network(s)
	    if ((defined $networks) && (length($networks) > 1)) {
	       my @NW = ();
	       foreach my $nw_cidr (split(',', $networks)) {
		  if ($nw_cidr =~
		     /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\/(\d{1,2})$/) { # w.x.y.z/p
			die "$opt_file line $.: illegal NW address: $nw_cidr\n"
			   unless (($1 >= 0) && ($1 <= 256));
			die "$opt_file line $.: illegal NW address: $nw_cidr\n"
			   unless (($2 >= 0) && ($2 <= 256));
			die "$opt_file line $.: illegal NW address: $nw_cidr\n"
			   unless (($3 >= 0) && ($3 <= 256));
			die "$opt_file line $.: illegal NW address: $nw_cidr\n"
			   unless (($4 >= 0) && ($4 <= 256));
			die "$opt_file line $.: illegal NW prefix: $nw_cidr\n"
			   unless (($5 >= 0) && ($5 <= 32));
			if ("$1.$2.$3.$4/$5" eq '0.0.0.0/0') {	# route is "default"
			   $nw_cidr = 'default';
			   die "$opt_file line $.: default route multiply defined for this host!\n"
			      if (defined($HasDefRoute));
			   $HasDefRoute++;
			}
			push(@NW, $nw_cidr) unless (grep(/^\Q$nw_cidr\E$/, @NW));
		  } elsif ($nw_cidr =~ /^default$/i) {
		     die "$opt_file line $.: default route multiply defined for this host!\n"
			if (defined($HasDefRoute));
		     $HasDefRoute++;
		     push(@NW, 'default');
		  } else {
		     die "$opt_file line $.: illegal Network/Prefix: $nw_cidr\n";
		  }
	       }
	       push(@{ $HOSTENT{$if}->{'network'} }, \@NW);
	    } else {	# route is "default" if no network(s) given!
	       die "$opt_file line $.: default route multiply defined for this host!\n"
		  if (defined($HasDefRoute));
	       $HasDefRoute++;
	       push(@{ $HOSTENT{$if}->{'network'} }, [ 'default' ]);
	    }

	    die "$opt_file line $. causes mismatched route to network (shouldn't happen)!\n"
	       unless ($#{ $HOSTENT{$if}->{'gw'} } == $#{ $HOSTENT{$if}->{'network'} });

	 } else {
	    die "$opt_file line $.: network statement must be accompained by a valid route!\n"
	       if ((defined $networks) && (length($networks) > 1));
	 }

	 $HOSTENT{$if}->{'blocking'} = $blocking;	# contextual blocking setting
	 $HOSTENT{$if}->{'debug'} = $debug;		# contextual debug setting
	 $HOSTENT{$if}->{'pingcache'} = $pingcache;	# contextual pingcache setting
	 $HOSTENT{$if}->{'verbose'} = $verbose;		# contextual verbosity setting

      }
   }

   close CFG;

   die "$opt_file: EOF reached without matching any ruleset for $NODE!\n"
      unless ($HasMatch);

   # Determine necessary kernel mods
   my $DEVre = join('|', map { $HOSTENT{$_}->{'device'} } keys %HOSTENT);
   if (open (PROBE, '/sbin/modprobe -c |')) {
      while (defined(my $line = <PROBE>)) {
	 if ($line =~ /^alias\s+(\S+)\s+(\S+)/) {
	    push(@{ $MODALIAS{$1} }, $2);
	 }
      }
      close PROBE;
   }

   foreach my $if (keys %HOSTENT) {
      $HOSTENT{$if}->{'line#'} = POSIX::INT_MAX		# paranoia
	 unless (exists $HOSTENT{$if}->{'line#'});
   }

   foreach my $if (
      sort { $HOSTENT{$a}->{'line#'} <=> $HOSTENT{$b}->{'line#'} } keys %HOSTENT
   ) {

      my $dev = $HOSTENT{$if}->{'device'};
      if (exists $MODALIAS{$dev}) {
	 foreach my $kmod (@{ $MODALIAS{$dev} }) {
	    push (@{ $HOSTENT{$if}->{'kmods'} }, $kmod)
	       unless (grep(/^\Q$kmod\E$/, @{ $HOSTENT{$if}->{'kmods'} }));
	 }
      }

      if (exists $HOSTENT{$if}->{'slaves'}) {
	 foreach my $slave (@{ $HOSTENT{$if}->{'slaves'} }) {
	    if (exists $MODALIAS{$slave}) {
	       foreach my $kmod (@{ $MODALIAS{$slave} }) {
		  push (@{ $HOSTENT{$if}->{'kmods'} }, $kmod)
		     unless (grep(/^\Q$kmod\E$/, @{ $HOSTENT{$if}->{'kmods'} }));
	       }
	    }
	 }
      }
   }
}

sub update_delay ($) {
   my $delay = $_[0];

   $delay *= $BACKOFF_pow;

   # constrain delay to be within our bounds
   $delay = $BACKOFF_max if ($delay > $BACKOFF_max);
   $delay = $BACKOFF_min if ($delay < $BACKOFF_min);

   # add some randomness to the delay
   $delay *= 1 - $BACKOFF_rnd + (rand(1) * $BACKOFF_rnd * 2);

   $delay = $BACKOFF_min if ($delay < 0);	# safety net ...
   return $delay;
}

sub nap ($$) {
   my ($error,$time) = @_; 

   if (! exists $RC{$error} ) {
      print STDOUT "\n" if $tired;
      print STDOUT "$prog: $error\n";
      print STDOUT "$prog: sleeping ${time}s/click: ";
      $RC{$error}++;
   } else {
      print STDOUT '.';
   }

   select(undef, undef, undef, $time);	
   return 1;
}

sub tcping ($$) {
   my ($if, $dst) = @_;
   my $timeout = 5;		# response timeout (sec)

   my $src = $HOSTENT{$if}->{'ip'};

   # do not cache "unbound" ping attempts
   unless ($HOSTENT{$if}->{'pingcache'} && defined($src)) {
      my $p = Net::Ping->new('tcp', $timeout);
      return $p->ping($dst);	# success=1, failure=0, error='undef'
   }

   # cache hit
   return $HOSTENT{$if}->{'pingreply'}{$dst}
      if (exists ($HOSTENT{$if}->{'pingreply'}{$dst}));

   # cache miss; update on success
   my $p = Net::Ping->new('tcp', $timeout);
   $p->bind($src);
   if ($p->ping($dst)) {
      $HOSTENT{$if}->{'pingreply'}{$dst} = 2;
      return 1;			# success!
   }
   
   return 0;			# failure!

}

sub CacheNetgroups ($) {
   my $href = $_[0];

   my %TMP = ();

   open(CFG,'/etc/netgroup') || return 0;
   while (defined(my $ngrent = <CFG>)) {
      next if ($ngrent =~ /^#/);		# strip out comments
      next if ($ngrent =~ /(\(|\))/);		# strip lines containing ( or )
      chomp $ngrent;
      my ($key, $value) = split(/\s+/, $ngrent, 2);
      $TMP{$key} = $value if (defined $value);
   }
   close CFG;

   foreach my $key (sort keys %TMP) {
      @{ $href->{$key}} = &ExpandNetgroup(\%TMP, $TMP{$key});
   }
}

sub IntersectNetgroups ($$) {
   my ($aref1, $aref2) = @_;
   my @Intersect = ();
   my %UNION = ();
   my %SEEN;

   %SEEN = ();
   foreach my $member (@{ $aref1 }) {
      next if ($SEEN{$member}++);		# weed out A1 duplicates
      $UNION{$member}++;
   }

   %SEEN = ();
   foreach my $member (@{ $aref2 }) {
      next if ($SEEN{$member}++);		# weed out A2 duplicates
      $UNION{$member}++;
   }

   foreach my $member (keys %UNION) {
      push (@Intersect, $member)
	 if ($UNION{$member} > 1);		# member is in BOTH Arrays
   }

   return @Intersect;
}

sub ExpandNetgroup ($$) {
   my ($href, $values) = @_;

   return map { exists $href->{$_}
      ? &ExpandNetgroup($href, $href->{$_})	# netgroup indirection
      : $_ 
   } split /\s+/, $values;
}

sub GetNodes ($$) {
   my ($href,$aref) = @_;

   my @Nodes = ();

   foreach my $nodes (@{ $aref }) {
      $nodes =~ s/\s+//go;				# kill whitespace

      while ($nodes =~ /([^,\[]+)\[([\d,-]+)\]([^,]?)/) {
	 my $match  = $&;				# translate
	 my $prefix = $1;				#   p[1-10,13]s
	 my $suffix = $3;				# to
	(my $string = $2) =~ s/(\d+)/$prefix$1$suffix/g;#   p1s-p10s,p13s
	 $nodes =~ s/\Q$match\E/$string/;		# for prefix 'p' and
      }							# suffix 's'

N:    foreach my $name (split(',',$nodes)) {
	 my @Dash = split('-', $name);
	 if ($name =~ /^\@([^\@]+)$/) {			# a lone netgroup
	    push(@Nodes,@{ $href->{$1} })
	       if (defined($href->{$1}));
	    next N;
	 } elsif ($name =~ /\@/) {			# intersection of netgroups
	    my @Isect = ();
	    my $Universal_Set = 1;
	    foreach my $ng (split('@', $name)) {
	       if (defined($href->{$ng})) {
		  @Isect = ($Universal_Set
		     ? @{ $href->{$ng} }
		     : IntersectNetgroups(\@Isect, \@{ $href->{$ng} })
		  );
		  $Universal_Set = 0;
	       } else {
		  next N;
	       }
	    }
	    push(@Nodes,@Isect) if scalar(@Isect);
	    next N;
	 } elsif ($name =~ /^\^(.*)$/) {		# a file containing
	    unless (open(FILE, $1)) {			# hosts in the first
	       push(@Nodes,$name);			# column, optionally
	       next N;					# delimited by a
	    }						# space or colon
	    my @NR = ();
	    while (defined(my $host = <FILE>)) {
	       next if ($host =~ /^(#|\^)/);
	       next if ($host =~ /^\s*$/);
	       $host =~ s/[\s:].*//g;
	       push (@NR,$host);
	    }
	    close FILE;
	    push(@Nodes, &GetNodes($href,\@NR)) if (scalar(@NR));
	    next N;
	 } elsif (! (scalar(@Dash) % 2)) {		# a valid range
	    my $chunkL = my $chunkR = "";		# contains an even
	    while (scalar(@Dash)) {			# number of "things"
	       $chunkL .= shift(@Dash) . '-';		# split by '-'
	       $chunkR = pop(@Dash) . "-$chunkR";
	    }
	    chop($chunkL); chop($chunkR);
	    my $prefixL = $prefixR = undef;
	    my $numberL = $numberR = undef;
	    my $suffixL = $suffixR = undef;
	    if ($chunkL =~ /^(\D*)(\d+)((\D+[-\w]*)*)$/) {
	       $prefixL = $1;
	       $numberL = $2;
	       $suffixL = $3;
	    } else {
	       push(@Nodes,$name);
	       next N;
	    }
	    if ($chunkR =~ /^(\D*)(\d+)((\D+[-\w]*)*)$/) {
	       $prefixR = $1;
	       $numberR = $2;
	       $suffixR = $3;
	    } else {
	       push(@Nodes,$name);
	       next N;
	    }
	    if ($prefixL ne $prefixR) {			# cluster mismatch
	       push(@Nodes,$name);
	       next N;
	    } elsif ($suffixL ne $suffixR) {		# cluster mismatch
	       push(@Nodes,$name);
	       next N;
	    } else {
	       if ($numberL <= $numberR) {
		  my $fmt = ($numberL =~ /^0/
		     ? "$prefixL%0".length($numberL)."d$suffixL"	# a leading zero
		     : "$prefixL%d$suffixL"
		  );
		  for (my $i=$numberL; $i <= $numberR; $i++) {
		     push(@Nodes,sprintf("$fmt",$i));
		  }
	       } else {
		  my $fmt = ($numberR =~ /^0/
		     ? "$prefixR%0".length($numberR)."d$suffixR"	# a leading zero
		     : "$prefixR%d$suffixR"
		  );
		  for (my $i=$numberL; $i >= $numberR; $i--) {
		     push(@Nodes,sprintf("$fmt",$i));
		  }
	       }
	    }
	 } else {					# a single host
	    push(@Nodes,$name) unless ($name =~ /^$/);
	 }
      }
   }

   # weed out duplicates (see perlfaq4(1))
   my %SEEN = ();
   my @Unique = grep { ! $SEEN{$_}++ } @Nodes;
   return @Unique;
}

sub restart () {
   &stop;
   &start;
}

sub start () {

   local $SIG{'__DIE__'} = \&__DIE__signal_handler;
   local $SIG{'__WARN__'} = \&__WARN__signal_handler;
   local $SIG{'INT'} = $SIG{'TERM'} = $SIG{'QUIT'} =
      sub { die "caught SIG$_[0]!\n" };

   # cache successfully-loaded kmods
   my %MODPROBED = ('off' => 1);
   if (open (MODULES, '/proc/modules')) {
      while (defined(my $entry = <MODULES>)) {
	 ($module, undef) = split(/\s+/, $entry, 2);
	 $MODPROBED{$module}++ if (defined($module));
      }
      close MODULES;
   }

   &get_config;

   # hostname (forcible)
   if (defined $HOSTNAME) {
      if ($debug) {
	 print STDOUT "debug: exec: /bin/hostname $HOSTNAME\n";
      } else {
	 if ($FQDN ne $HOSTNAME || $opt_force) {
	    print STDOUT "/bin/hostname $HOSTNAME\n" if ($verbose);
	    system {'/bin/hostname'} '/bin/hostname', $HOSTNAME;
	    my $rc = $?>>8;
	    die "'/bin/hostname' terminated non-zero ($rc)!\n" if ($rc);
	 }
      }
   }

   foreach my $if (
      sort { $HOSTENT{$a}->{'line#'} <=> $HOSTENT{$b}->{'line#'} } keys %HOSTENT
   ) {

      # bonding kmod (non-forcible)
      if (exists $HOSTENT{$if}->{'slaves'}) {

	 unless (exists $MODPROBED{'bonding'}) {
	    if ($HOSTENT{$if}->{'debug'}) {
	       print STDOUT "debug: exec: /sbin/modprobe bonding\n";
	       $MODPROBED{'bonding'}++;
	    } else {
	       print STDOUT "/sbin/modprobe bonding\n" if ($HOSTENT{$if}->{'verbose'});
	       system {'/sbin/modprobe'} '/sbin/modprobe', 'bonding';
	       my $rc = $?>>8;
	       die "'/sbin/modprobe bonding' terminated non-zero ($rc)!\n" if ($rc);
	       alarm(10);
	       $rc = eval {
		  local($SIG{'__DIE__'})	= 'DEFAULT';
		  local($SIG{'__WARN__'})	= 'DEFAULT';
		  local $SIG{'ALRM'}	= sub {die "Command timed out!\n"};
		  while (1) {
		     last if (-r '/sys/class/net/bonding_masters');
		     select(undef, undef, undef, 0.5);
		  }
		  return 0;
	       };
	       alarm(0);
	       die "'/sbin/modprobe bonding' failed to produce a bond master!\n"
		  unless (defined($rc));
	       $MODPROBED{'bonding'}++;
	    }
	 }
      }

      # device kmods (non-forcible)
      foreach my $kmod (@{ $HOSTENT{$if}->{'kmods'} }) {
	 unless (exists $MODPROBED{$kmod}) {
	    if ($HOSTENT{$if}->{'debug'}) {
	       print STDOUT "debug: exec: /sbin/modprobe $kmod\n";
	       $MODPROBED{$kmod}++;
	    } else {
	       print STDOUT "/sbin/modprobe $kmod\n" if ($HOSTENT{$if}->{'verbose'});
	       system {'/sbin/modprobe'} '/sbin/modprobe', $kmod;
	       my $rc = $?>>8;
	       $MODPROBED{$kmod}++ unless ($rc);
	    }
	 }
      }

      # IF address (non-forcible)
      if (defined($HOSTENT{$if}->{'ip'}) && defined($HOSTENT{$if}->{'prefix'})) {
	 my $iplist = ($HOSTENT{$if}->{'debug'}
	    ? ''
	    : `/sbin/ip -o -4 addr ls $HOSTENT{$if}->{'device'} 2>/dev/null` || ''
	 );
	 unless ($iplist =~ /\b$HOSTENT{$if}->{'ip'}\/$HOSTENT{$if}->{'prefix'}\b/) {
	    my @IPadd = (
	       '/sbin/ip', 'addr', 'add',
	       "$HOSTENT{$if}->{'ip'}/$HOSTENT{$if}->{'prefix'}",
	       'brd', '+', 'dev', $HOSTENT{$if}->{'device'},
	    );
	    push (@IPadd, 'label', "$HOSTENT{$if}->{'device'}:$HOSTENT{$if}->{'alias'}")
	       if (exists $HOSTENT{$if}->{'alias'});

	    if ($HOSTENT{$if}->{'debug'}) {
	       print STDOUT 'debug: exec: ' . join(' ', @IPadd) . "\n";
	    } else {
	       print STDOUT join(' ', @IPadd) . "\n" if ($HOSTENT{$if}->{'verbose'});
	       system {$IPadd[0]} @IPadd;
	       my $rc = $?>>8;
	       die "'/sbin/ip addr add' terminated non-zero ($rc)!\n" if ($rc);
	    }
	 }
      }

      # IB connected mode (forcible)
      if (exists $HOSTENT{$if}->{'connected'}) {
	 if ($HOSTENT{$if}->{'debug'}) {
	    print STDOUT
	       "debug: exec: echo connected > /sys/class/net/$HOSTENT{$if}->{'device'}/mode\n";
	 } else {
	    my $mode = `/bin/cat /sys/class/net/$HOSTENT{$if}->{'device'}/mode 2>/dev/null` || '';
	    chomp $mode;
	    if ($mode ne 'connected' || $opt_force) {
	       print STDOUT "echo connected > /sys/class/net/$HOSTENT{$if}->{'device'}/mode\n"
		  if ($HOSTENT{$if}->{'verbose'});
	       open (MODE, ">/sys/class/net/$HOSTENT{$if}->{'device'}/mode" ) ||
		  die "$prog: /sys/class/net/$HOSTENT{$if}->{'device'}/mode: $!\n";
	       print MODE "connected\n";
	       close MODE
	    }
	 }
      }

      # IF link & MTU (forcible)
      my $iplink = ($HOSTENT{$if}->{'debug'} || $opt_force
	 ? ''
	 : `/sbin/ip -o -4 link show $if 2>/dev/null` || ''
      );

      my $LNKre = (exists $HOSTENT{$if}->{'mtu'}
	 ? "mtu\\s+$HOSTENT{$if}->{'mtu'}.*state\\s+UP"
	 : 'state\s+UP'
      );

      unless ($iplink =~ /$LNKre/) {
	 my @IPset = ('/sbin/ip', 'link', 'set', $if, 'up');
	 push(@IPset, 'mtu', $HOSTENT{$if}->{'mtu'})
	    if (exists $HOSTENT{$if}->{'mtu'});

	 if ($HOSTENT{$if}->{'debug'}) {
	    print STDOUT 'debug: exec: ' . join(' ', @IPset) . "\n";
	 } else {
	    print STDOUT join(' ', @IPset) . "\n" if ($HOSTENT{$if}->{'verbose'});
	    system {$IPset[0]} @IPset;
	    my $rc = $?>>8;
	    die "'/sbin/ip link set' terminated non-zero ($rc)!\n" if ($rc);
	 }
      }

      # IF enslave (non-forcible)
      if (exists $HOSTENT{$if}->{'slaves'}) {

	 foreach my $slave (@{ $HOSTENT{$if}->{'slaves'} }) {
	    my $iplist = ($HOSTENT{$if}->{'debug'}
	       ? ''
	       : `/sbin/ip -o addr ls $slave 2>/dev/null` || ''
	    );
	    unless ($iplist =~ /\bmaster\s+$if\b/i) {	# not yet enslaved to IF
	       my @IFenslave = ('/sbin/ifenslave', $if, $slave);
	       if ($HOSTENT{$if}->{'debug'}) {
		  print STDOUT 'debug: exec: ' . join(' ', @IFenslave) . "\n";
	       } else {
		  print STDOUT join(' ', @IFenslave) . "\n" if ($HOSTENT{$if}->{'verbose'});
		  system {$IFenslave[0]} @IFenslave;
		  my $rc = $?>>8;
		  die "'/sbin/ifenslave $if $slave' terminated non-zero ($rc)!\n" if ($rc);
		  select(undef, undef, undef, 0.5);
	       }
	    }
	 }

	 # slave device carrier check
	 unless ($HOSTENT{$if}->{'debug'}) {
	    my $delay = 0;
	    my $start = time();
SLINK:	    foreach my $slave (@{ $HOSTENT{$if}->{'slaves'} }) {
	       unless ( -e "/sys/class/net/$slave/carrier" ) {
		  warn "$slave: no slave carrier? skipping!\n";
		  next SLINK;
	       }
	       open (LNK, "/sys/class/net/$slave/carrier" ) ||
		  die "$prog: /sys/class/net/$slave/carrier: $!\n";
	       my $link = <LNK>;
	       close LNK;
	       if (defined($link) && ($link == 1)) {	# proceed if carrier = 1
		  $delay = 0;				# reset the delay
		  $start = time();			# restart the clock
	       } else {
		  if ((time() - $start) < $BACKOFF_tot) {
		     $delay = &update_delay($delay);
		     warn "unable to detect link on $slave, retrying in ${delay} sec ...\n";
		     select(undef, undef, undef, $delay);
		     redo SLINK;
		  } else {
		     warn "unable to detect link on $slave, skipping!\n";
		     $delay = 0;			# reset the delay
		     $start = time();			# restart the clock
		  }
	       }
	    }
	 }

      }

      # IF Carrier check (potentially blocking)
      unless ($HOSTENT{$if}->{'debug'}) {
	 %RC = (); $tired = 0; $blocked = 0;
	 while (1) {
	    last if ( -e "/sys/class/net/$HOSTENT{$if}->{'device'}/carrier" );
	    unless ($HOSTENT{$if}->{'blocking'}) {	# non-blocking
	       last if ($blocked >= $BLOCKING_max);
	       $blocked++;
	    }
	    $tired = &nap("$!", 5);
	 }

	 %RC = (); $tired = 0; $blocked = 0;
	 while (1) {
	    open (LNK, "/sys/class/net/$HOSTENT{$if}->{'device'}/carrier" ) ||
	       die "$prog: /sys/class/net/$HOSTENT{$if}->{'device'}/carrier: $!\n";
	    my $link = <LNK>;
	    close LNK;
	    last if (defined($link) && ($link == 1));	# proceed if carrier = 1
	    unless ($HOSTENT{$if}->{'blocking'}) {	# non-blocking
	       last if ($blocked >= $BLOCKING_max);
	       $blocked++;
	    }
	    $tired = &nap("$HOSTENT{$if}->{'device'}: no link - check cable?", 10);
	 }
	 if ($tired && $HOSTENT{$if}->{'blocking'}) {
	    print STDOUT "\n$prog: $HOSTENT{$if}->{'device'}: link [  OK  ]\n";
	 } elsif (!$HOSTENT{$if}->{'blocking'} && ($blocked >= $BLOCKING_max)) {
	    print STDOUT "\n$prog: $HOSTENT{$if}->{'device'}: link [FAILED]\n";
	 }

      }

      # Routes
      if (exists $HOSTENT{$if}->{'gw'}) {

	 my $reroute = ($HOSTENT{$if}->{'debug'} || $opt_force ? 1 : 0);
	 unless ($HOSTENT{$if}->{'debug'}) {
GW:	    foreach my $idx (0..$#{ $HOSTENT{$if}->{'gw'} }) {

	       my $gw_ref = ${ $HOSTENT{$if}->{'gw'} }[$idx];
	       my $nw_ref = ${ $HOSTENT{$if}->{'network'} }[$idx];

	       foreach my $nw_cidr (@{ $nw_ref }) {
		  $nw_cidr =~ s/^default$/0.0.0.0\/0/i;
		  my $iproute = `/sbin/ip -o -4 route list $nw_cidr 2>/dev/null` || '';
		  foreach my $gw (@{ $gw_ref }) {
		     unless ($iproute =~ /\Q$gw\E/) {
			$reroute++;
			last GW;
		     }
		  }
	       }
	    }
	 }

	 if ($reroute) {
	    foreach my $idx (0..$#{ $HOSTENT{$if}->{'gw'} }) {

	       my $gw_ref = ${ $HOSTENT{$if}->{'gw'} }[$idx];
	       my $nw_ref = ${ $HOSTENT{$if}->{'network'} }[$idx];

	       if (scalar @{ $gw_ref } > 1) {	# ECMP (potentially blocking)

		  $blocked = 0;
ROUTES:		  foreach my $nw_cidr (@{ $nw_ref }) {

		     my @Route = (
			'/sbin/ip', 'route',
			'replace', $nw_cidr,
			'scope', 'global',
		     );

		     %RC = ();
		     my $delay = 0;
		     my $routers = 0;
		     my $start = time();
PING:		     foreach my $nexthop (@{ $gw_ref }) {
			my $str = "$prog: route $nw_cidr via $nexthop dev $if:";

			if ($HOSTENT{$if}->{'debug'} ||
			      (!$HOSTENT{$if}->{'blocking'} &&
				 ($blocked >= $BLOCKING_max))) {

			   push (@Route,
			      'nexthop', 'via', "$nexthop",
			      'dev', $if,
			      'weight', '1',
			   );
			   $routers++;

			   print STDOUT "$str [FAILED]\n"
			      unless ($HOSTENT{$if}->{'debug'});
			   $RC{$str}++;

			   $delay = 0;		# reset the delay
			   $start = time();	# restart the clock
			   next PING;
			}

			if (my $rc = &tcping($if, $nexthop)) {

			   push (@Route,
			      'nexthop', 'via', "$nexthop",
			      'dev', $if,
			      'weight', '1',
			   );
			   $routers++;

			   if (exists $RC{$str}) {
			      print STDOUT $rc > 1
			      ? "$str [PASSED] (cached)\n"
			      : "$str [PASSED]\n";
			   } else {
			      print STDOUT $rc > 1
			      ? "$str [  OK  ] (cached)\n"
			      : "$str [  OK  ]\n"
			   }
			   $RC{$str}++;

			   $delay = 0;		# reset the delay
			   $start = time();	# restart the clock
			   next PING;

			} else {		# ping failed, retry

			   if ($HOSTENT{$if}->{'pingcache'} &&
			      exists $HOSTENT{$if}->{'pingreply'}{$nexthop} &&
			      !$HOSTENT{$if}->{'pingreply'}{$nexthop}) {

			      print STDOUT "$str [FAILED] (cached)\n";
			      $RC{$str}++;

			      $delay = 0;	# reset the delay
			      $start = time();	# restart the clock
			      next PING;

			   } else {

			      print STDOUT "$str\n" unless (exists $RC{$str});
			      $RC{$str}++;
			      if ((time() - $start) < $BACKOFF_tot) {
				 $delay = &update_delay($delay);
				 warn "unable to ping $nexthop, retrying in ${delay} sec ...\n";
				 select(undef, undef, undef, $delay);
				 redo PING;
			      } else {
				 warn "unable to ping $nexthop, skipping!\n";

				 # cache this (negative) ping response
				 # only if sourced from a well-defined ip
				 $HOSTENT{$if}->{'pingreply'}{$nexthop} = 0
				    if ($HOSTENT{$if}->{'pingcache'} &&
				       defined($HOSTENT{$if}->{'ip'}));

				 $delay = 0;		# reset the delay
				 $start = time();	# restart the clock
				 next PING;
			      }

			   }

			}

		     }

		     unless ($routers) {
			$blocked++;
			delete $HOSTENT{$if}->{'pingreply'} if ($HOSTENT{$if}->{'pingcache'});
			warn "no suitable ECMP route found to network '$nw_cidr' through $if, retrying ...\n";
			redo ROUTES;
		     }

		     if ($HOSTENT{$if}->{'debug'}) {
			print STDOUT 'debug: exec: ' . join(' ', @Route) . "\n";
		     } else {
			print STDOUT join(' ', @Route) . "\n" if ($HOSTENT{$if}->{'verbose'});
			system {$Route[0]} @Route;
			my $rc = $?>>8;
			if ($rc) {
			   if (!$HOSTENT{$if}->{'blocking'} && ($blocked >= $BLOCKING_max)) {
			      warn "'/sbin/ip route' terminated non-zero ($rc)!\n";
			   } else {
			      die "'/sbin/ip route' terminated non-zero ($rc)!\n";
			   }
			}
		     }
		  }
	       } else {					# non-ECMP
		  foreach my $nw_cidr (@{ $nw_ref }) {
		     my @Route = (
			'/sbin/ip', 'route',
			'replace', $nw_cidr,
			'via', ${ $gw_ref }[0],
			'dev', $if
		     );

		     if ($HOSTENT{$if}->{'debug'}) {
			print STDOUT 'debug: exec: ' . join(' ', @Route) . "\n";
		     } else {
			print STDOUT join(' ', @Route) . "\n" if ($HOSTENT{$if}->{'verbose'});
			system {$Route[0]} @Route;
			my $rc = $?>>8;
			die "'/sbin/ip route' terminated non-zero ($rc)!\n" if ($rc);
		     }
		  }
	       }
	    }
	 }
      }
   }
}

sub status () {
   
   my $rc = 0;
   my @Status = ();

   &get_config;

   if (defined $HOSTNAME) {
      if ($FQDN eq $HOSTNAME) {
	 push (@Status, "   hostname $HOSTNAME: [  OK  ]\n");
      } else {
	 push (@Status, "   hostname $HOSTNAME: [FAILED]\n");
	 $rc = 1;
      }
   }

   foreach my $if (
      sort { $HOSTENT{$a}->{'line#'} <=> $HOSTENT{$b}->{'line#'} } keys %HOSTENT
   ) {

      # IB connected mode
      if (exists $HOSTENT{$if}->{'connected'}) {
	 my $mode = `/bin/cat /sys/class/net/$HOSTENT{$if}->{'device'}/mode 2>/dev/null` || '';
	 chomp $mode;
	 if ($mode eq 'connected') {
	    push (@Status, "   $HOSTENT{$if}->{'device'} connected mode: [  OK  ]\n");
	 } else {
	    push (@Status, "   $HOSTENT{$if}->{'device'} connected mode: [FAILED]\n");
	    $rc = 1;
	 }
      }

      # IF address
      if (defined($HOSTENT{$if}->{'ip'}) && defined($HOSTENT{$if}->{'prefix'})) {
	 my $iplist = `/sbin/ip -o -4 addr ls $HOSTENT{$if}->{'device'} 2>/dev/null` || '';
	 chomp $iplist; $iplist =~ s/^\d+:\s+//; $iplist =~ s/\s+/ /g;
	 if ($iplist =~ /\b$HOSTENT{$if}->{'ip'}\/$HOSTENT{$if}->{'prefix'}\b/) {
	    push (@Status, "   $iplist: [  OK  ]\n");
	 } else {
	    push (@Status, "   $iplist: [FAILED]\n");
	    $rc = 1;
	 }
      }

      # IF link & MTU
      my $iplink = `/sbin/ip -o -4 link show $if 2>/dev/null` || '';
      chomp $iplink; $iplink =~ s/^\d+:\s+//; $iplink =~ s/\s+/ /g;
      if (exists $HOSTENT{$if}->{'mtu'}) {
	 if ($iplink =~ /(^.*mtu\s+$HOSTENT{$if}->{'mtu'}.*state\s+UP)/) {
	    push (@Status, "   $1: [  OK  ]\n");
	 } else {
	    push (@Status, "   $iplink: [FAILED]\n");
	    $rc = 1;
	 }
      } else {
	 if ($iplink =~ /(^.*state\s+UP)/) {
	    push (@Status, "   $1: [  OK  ]\n");
	 } else {
	    push (@Status, "   $iplink: [FAILED]\n");
	    $rc = 1;
	 }
      }

      # IF enslave
      if (exists $HOSTENT{$if}->{'slaves'}) {
	 foreach my $slave (@{ $HOSTENT{$if}->{'slaves'} }) {
	    my $iplist = `/sbin/ip -o addr ls $slave 2>/dev/null` || '';
	    chomp $iplist; $iplist =~ s/^\d+:\s+//; $iplist =~ s/\s+/ /g;
	    if ($iplist =~ /(^.*master\s+$if\s+state\s+UP)/i) {
	       push (@Status, "      $1: [  OK  ]\n");
	    } else {
	       push (@Status, "      $iplist: [FAILED]\n");
	       $rc = 1;
	    }
	 }
      }

      # Routes
      if (exists $HOSTENT{$if}->{'gw'}) {
	 foreach my $idx (0..$#{ $HOSTENT{$if}->{'gw'} }) {

	    my $gw_ref = ${ $HOSTENT{$if}->{'gw'} }[$idx];
	    my $nw_ref = ${ $HOSTENT{$if}->{'network'} }[$idx];

NW:	    foreach my $nw_cidr (@{ $nw_ref }) {
	       $nw_cidr =~ s/^default$/0.0.0.0\/0/i;
	       my $iproute = `/sbin/ip -o -4 route list $nw_cidr 2>/dev/null` || '';
	       chomp $iproute; $iproute =~ s/\\//g; $iproute =~ s/\s+/ /g; $iproute =~ s/\s+$//;
	       foreach my $gw (@{ $gw_ref }) {
		  unless ($iproute =~ /\Q$gw\E/) {
		     push(@Status, "   route $iproute: [FAILED]\n");
		     $rc = 1;
		     next NW;
		  }
	       }
	       push(@Status, "   route $iproute: [  OK  ]\n");
	    }
	 }
      }

   }
   
   if ($rc) {
      print STDOUT "$prog: [FAILED]\n";
   } else {
      print STDOUT "$prog: [  OK  ]\n";
   }
   print STDOUT @Status if (scalar(@Status));

}

sub stop () {
   return 0;		# nothing here yet
}

sub generate () {

   pod2usage("$prog: no node(s) specified!\n")
      unless (scalar @opt_nodes);
   pod2usage("$prog: no interface specified!\n")
      unless (defined $opt_interface);
   pod2usage("$prog: no IP/Prefix address specified!\n")
      unless (defined $opt_cidr);
   pod2usage("$prog: no GW specified for given NW/Prefix!\n")
      if (defined($opt_network) && ! defined($opt_gateway));

   our %NETGROUP = ();
   if (grep(/\@/, @opt_nodes)) {
      &CacheNetgroups(\%NETGROUP);				# load netgroup namespace
   }

   our @NodeList = &GetNodes(\%NETGROUP,\@opt_nodes);

   exit 0 unless (@NodeList);

   our ($ip_addr, $ip_prefix) = split('/', $opt_cidr);		# w.x.y.z/p

   if ((defined $ip_addr) && ($ip_addr =~ /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/)) {
      die "$prog: illegal IP address: $ip_addr\n"
	 unless (($1 >= 0) && ($1 <= 256));
      die "$prog: illegal IP address: $ip_addr\n"
	 unless (($2 >= 0) && ($2 <= 256));
      die "$prog: illegal IP address: $ip_addr\n"
	 unless (($3 >= 0) && ($3 <= 256));
      die "$prog: illegal IP address: $ip_addr\n"
	 unless (($4 >= 0) && ($4 <= 256));
   } else {
      die "$prog: illegal IP address in $opt_cidr!\n";
   }
   $ip_addr = inet_aton($ip_addr);				# packed IP

   unless ((defined $ip_prefix) && ($ip_prefix =~ /^\d+$/) && ($ip_prefix >= 0) && ($ip_prefix <= 32)) {
      die "$prog: illegal IP prefix in $opt_cidr!\n";
   }
   our $ip_netmask = pack('N',~((1<<(32-$ip_prefix))- 1));	# packed NETMASK

   our $ip_network = $ip_addr & $ip_netmask;			# packed NETWORK
   die "$prog: $opt_cidr is the NETWORK address of its CIDR block!\n"
      if ( inet_ntoa($ip_addr) eq inet_ntoa($ip_network) );

   our $ip_broadcast = $ip_addr | ~$ip_netmask;			# packed BROADCAST
   die "$prog: $opt_cidr is the BROADCAST address of its CIDR block!\n"
      if ( inet_ntoa($ip_addr) eq inet_ntoa($ip_broadcast) );

#             Node Host Interface    IP/prefix
   my $rule = "%s\0%s\0$opt_interface\0%s";

   if ($opt_gateway) {
      $opt_network = 'default'
	 unless (defined($opt_network));
      $opt_mtu = '*' unless (defined($opt_mtu));
      $rule .= "\0$opt_mtu\0$opt_gateway\0$opt_network";
   } else {
      $rule .= "\0$opt_mtu"
	 if (defined($opt_mtu));
   }

   my $count = 0;
   my @Output = ();
   my $node_sz = $hostname_sz = $ip_sz = 0;
   foreach my $node (@NodeList) {
      (my $hostname = $opt_hostname) =~ s/\%node\%/$node/ig;

      my $ip_next = inet_ntoa(pack("N",(unpack("N",$ip_addr)) + $count));
      die "$prog: $ip_next/$ip_prefix overruns its CIDR block; decrease the prefix!\n"
	 if ( $ip_next eq inet_ntoa($ip_broadcast) );

      $node_sz = length($node)
	 if (length($node) > $node_sz);			# max strlen($node)
      $hostname_sz = length($hostname)
	 if (length($hostname) > $hostname_sz);		# max strlen($hostname)
      $ip_sz = length("$ip_next/$ip_prefix")
	 if (length("$ip_next/$ip_prefix") > $ip_sz);	# max strlen($ip/$prefix)

      push (@Output, sprintf "$rule\n", $node, $hostname, "$ip_next/$ip_prefix");

      $count++;
   }

   $fmt =  "format STDOUT = \n"
	.  '^' . '<' x $node_sz . ' '			# Node
	.  '^' . '<' x $hostname_sz . ' '		# Host
	.  '^' . '<' x length($opt_interface) . ' '	# IF
	.  '^' . '<' x $ip_sz . ' ';			# IP/Prefix
   $fmt	.= '^' . '<' x length($opt_mtu) . ' '		# MTU
      if (defined($opt_mtu));
   $fmt .= '^' . '<' x length($opt_gateway) . ' '	# GW
        .  '^' . '<' x length($opt_network) . ' '	# NW/Prefix
      if (defined($opt_gateway));
   $fmt .= "\n";
   $fmt .= '$Node,$Host,$IF,$IP,$MTU,$GW,$NW' . "\n.\n";

   print "$fmt" if ((defined($opt_debug) && $opt_debug == 1));

   eval $fmt;
   die "$prog: $@!\n" if $@;

   local ($Node, $Host, $IF, $IP, $MTU, $GW, $NW);
   foreach my $output (@Output) {
      ($Node, $Host, $IF, $IP, $MTU, $GW, $NW) = split(/\0/, $output);
      write STDOUT;
   }

}

&$action;

if (scalar @Warnings) {

   use Sys::Syslog;

   my $priority = ($debug ? LOG_INFO : LOG_ERR);
   openlog("$prog\[$$\]", 'ndelay', LOG_DAEMON);
   foreach my $warning (@Warnings) {
      syslog($priority, $warning);
   }
   closelog;
}

exit 0;

# Documentation

=head1 NAME

B<ethcfg> - configure external ethernet interfaces and hostnames

=head1 SYNOPSIS

B<ethcfg> [B<-h>] [B<--man>]

B<ethcfg> [B<-c> I<file>] [B<--[no]blocking>] [B<--[no]debug>] [B<--force>]
[B<--[no]ping-cache>] [B<--[no]verbose>] <start|stop|restart|status>

B<ethcfg> generate B<--nodes> I<Node>[I<,Node>] S<B<--if> I<IF>[I<=dev>[I<,dev>]]>>
S<B<--ip> I<IP/Prefix>> S<[B<--host> I<Host>]> S<[B<--mtu> I<MTU>]>
S<[B<--gw> I<GW>[I<,GW>]> S<[B<--nw> I<NW/Prefix>[I<,NW/Prefix>]]]>

=head1 DESCRIPTION

As a service, B<ethcfg> parses its configuration F<file> seeking entries
which match a unique identifier of the node on which it is run.  For each
that are found, B<ethcfg> takes action to fulfill the entry's ruleset,
which may be one or more of the following: set a hostname, assign an IP
address/netmask to an interface, define a bonded interface, set an
interface's MTU, define a gateway or ECMP route to specified network(s).
See the section below entitled B<CONFIGURATION FILE SYNTAX> for the syntax
rules of this file.  On Cray XT/XE systems, the unique identifier is taken
from F</proc/cray_xt/cname>; on Perceus/Warewulf clusters the identifier is
gleaned from the kernel's F</proc/cmdline>.  Barring these, the node's
B<short> hostname(1) is used to identify it uniquely.

Alternatively, B<ethcfg> can be used to generate B<Interface Rulesets>
suitable to populate its configuration F<file> (see B<CONFIGURATION FILE
SYNTAX> below for the definition of this form).  B<ethcfg> will iterate
over the given I<Node>list, producing an B<Interface Ruleset> for each with
the following properties: the rule will prescribe an I<IP/Prefix> address
on the I<IF> specified for the I<Node>.  The I<IP/Prefix> address will then
be incremented as B<ethcfg> works through the I<Node>list in the order
specified on the command line.

=head1 HELP OPTIONS

=over 4

=item B<-h,--help>

Show command usage and exit.

=item B<--man>

Print the B<ethcfg> manpage and exit.

=back

=head1 SERVICE OPTIONS

=over 4

=item B<--[no]blocking>

Certain conditions are considered critically met by B<ethcfg> in order to
satisfy a given B<Interface Ruleset> (see B<CONFIGURATION FILE SYNTAX>
below for the definition of this form).  At present, these conditions are:

=over 4

o Existence of the interface's F</sys/class/net/E<lt>IFE<gt>/carrier>

o Link detected on the interface specified (carrier = 1)

o ECMP route reachability of at least one gateway in any set provided

=back

If any of these are not met, B<ethcfg>'s default behavior is to delay and
retry the condition until it is satisfied (potentially never) before
proceeding. [Un]setting this option causes B<ethcfg> to [not] block in this
fashion.  Command-line specification overrides any contextual BLOCKING
assignment(s) that may be set in the configuration file.  Default: blocking.

=item B<-c,--config> I<file>

Parse an alternate configuration I<file> (default: F</etc/sysconfig/ethcfg>).

=item B<-d,-n,--[no]debug,--[no]dry-run>

Take no action, just print to STDOUT any variable assignment and/or command
that would be executed throughout B<ethcfg>'s execution cycle.
Command-line specification overrides any contextual DEBUG assignment(s)
that may be set in the configuration file.  Default: no debug.

=item B<--force>

Force a reconfiguration even if no change is detected.  Currently this is
limited to resetting: hostname, connected mode (IB devices only), interface
link, interface MTU, and interface routes; ECMP route reachability is also
re-evaluated. B<ethcfg> will I<not> unload any kernel modules, reset an
interface's IP/prefix or re-enslave bond devices when this option is
selected.

=item B<-p,--[no]ping-cache,--[no]cache-ping>

Do [not] cache ping responses when validating gateways for inclusion in an
ECMP route (see the B<GW> field in the B<Interface Ruleset Form> section
below).  Command-line specification overrides any contextual PINGCACHE
assignment(s) that may be set in the configuration file.  Default: cache
ping responses.

=item B<-v,--[no]verbose>

Print, on STDOUT, actions taken to fulfill each entry's ruleset.
Command-line specification overrides any contextual VERBOSE assignment(s)
that may be set in the configuration file.  Default: no verbose.

=back

=head1 GENERATE OPTIONS

=over 4

=item B<--gw,--gateway> I<GW>[I<,GW>]

Generate an B<Interface Ruleset> containing a route to a network (see the
B<--nw> option below) through this IPv4 I<GW> address.

=item B<--hostname> I<Host>

Generate an B<Interface Ruleset> containing this I<Host> entry.  If the
string "I<%node%>" is part of I<Host>, names from the nodelist are
substituted in its stead (see the B<EXAMPLES> section below).  If this
option is omitted, I<Host> defaults to the asterisk character "I<*>".

=item B<--if,--interface> I<IF>[I<=dev>[I<,dev>]]

Generate an B<Interface Ruleset> containing this I<IF> entry.

=item B<--ipaddr> I<IP/Prefix>

Generate an B<Interface Ruleset> based off of this I<IP/Prefix> entry;
this I<IP> address is incremented for every I<Node> in the nodelist.  It is
considered a fatal error to produce a rule which assigns an address to the
NETWORK or BROADCAST address of I<IP/Prefix>'s CIDR block.

=item B<--mtu> I<MTU>

Generate an B<Interface Ruleset> specifying this I<MTU> for the given
B<IF> above.

=item B<--node> I<Node>[I<,Node>]

Generate an B<Interface Ruleset> for each specified I<Node>.  Valid names
are: hosts, netgroups, ranges, or a path to files containing these entities
(newline separated).  Each I<Node> specification may be inter-mixed however
always comma separated.  Netgroup names are invoked by using the "@"
symbol, which acts as an intersection operator.  A single netgroup can be
designated with a leading or trailing "@" (e.g. "@compute"), which can be
thought of as the (implied) Universal Set intersected with the netgroup
specified.  Multiple "@"-separated names result in a nodelist of hosts
that the given netgroups have in common (e.g. "compute@CU1").  A host range
is specified by a hyphen "-" between host names of the form "B<pDs>" for
prefix B<p>, digit(s) B<D>, and optional suffix B<s> (e.g.  "rr01a-rr16a").
The LHS prefix of the statement must match the RHS prefix; likewise for any
given suffix.  If the LHS digits are less than the RHS digits, the
resulting nodelist will be ascending in order, otherwise the list will
descend numerically.  You may alternatively specify a host range by
"factoring out" the prefix and suffix and merely enclose the digits in
square brackets (e.g. "rr[01-16]a") in which case B<ethcfg> will translate
what you mean before the nodelist is processed.  Note that in either case,
B<ethcfg> will preserve any zero-padding that the I<smallest number> of the
given range posesses (e.g.  the shown example will produce rr01a, rr02a,
...  rr16a).  File paths are given with a leading "^" (e.g.
"^/tmp/nodelists").  Multiple instances of B<--node> may be issued.

=item B<--nw,--network> I<NW/Prefix>[I<,NW/Prefix>]

Generate an B<Interface Ruleset> specifying this I<NW/Prefix> as the
destination network of any specified I<GW> route above.  If this option is
omitted and a I<GW> is defined, I<NW/Prefix> is assigned the string
"I<default>".  It is illegal to specify a I<NW/Prefix> without also
providing a I<GW> to that network on the command line.

=back

=head1 CONFIGURATION FILE SYNTAX

Entries are listed one-per-line in the configuration file and may take one
of three forms: (1) a comment and/or whitespace, (2) a variable assignment,
or (3) an interface ruleset.

=head2 Comment Form

Comments are identified by the hash symbol, "#", located in the first
column of the configuration file, and may be followed by any text up to an
ending newline character.  Comments and whitespace are ignored during
config file parsing.

=head2 Variable Assignment Form

This type of entry permits the assignment of a value to an identifier which may
be used I<thereafter> in the configuration file to represent its value.  The
identifier must follow the form of a valid bash or perl scalar, namely a string
beginning with a letter or underscore followed by any combination of letters,
underscores, or digits.  The identifier string must begin in first column of
the configuration file, followed by optional white space, followed by "=",
followed by optional whitespace, and finally followed by the value itself.  The
assigned value may contain whitespace and may be enclosed by single/double
quotes if so desired.  The identifier is dereferenced by preceeding it with "$"
in the traditional fashion of many scripting languages (see the B<SAMPLE
CONFIGURATION FILE> below).  There are four case-insensitive reserved keywords,
B<BLOCKING>, B<DEBUG>, B<PINGCACHE> and B<VERBOSE>, which may be used within the
configuration file to contextually enable/disable their respective type of
behavior.  To set, assign a value of I<1>, I<on>, I<true>, or I<yes>; to
unset, assign a value of I<0>, I<off>, I<false>, or I<no>.

=head2 Interface Ruleset Form

This entry type can contain up to seven fields, whitespace separated, of
general form:

Node Host IF[=dev[,dev]] IP/Prefix MTU GW[,GW] NW/Prefix[,NW/Prefix]

=over 4

=item Node

A unique identifier of the node on which B<ethcfg> is run.  On Cray XT/XE
systems, this identifier is taken from F</proc/cray_xt/cname>; on
Perceus/Warewulf clusters this identifier is gleaned from the kernel's
F</proc/cmdline>.  Barring these, the node's B<short> hostname(1) is used
to identify it uniquely.

=item Host

Set the hostname(1) of this Node to B<Host> (optional).  Multiple B<Host>
assignments to a given Node is forbidden.

=item IF[=dev[,dev]]

Use interface B<IF> for the following network settings (optional).  If a
comma-separated list of B<dev>ices are specified, ifenslave(8) them to
B<IF> to form a bond.  B<ethcfg> CAN configure alias interfaces (e.g.
eth0:1), however you cannot form a bonded interface as an alias, nor is it
permitted to use alias devices in a bond definition.  B<ethcfg> will
modprobe(8) any kernel-module aliases associated with B<IF> or B<dev> via
F</etc/modprobe.conf> or files in the F</etc/modprobe.d> directory.

=item IP/Prefix

Add this B<IP>v4 address with B<Prefix>-length netmask to specified
B<IF> (optional).

=item MTU

Change the Maximum Transfer Unit to B<MTU> of the specified B<IF>
(optional).  If the interface appears to be an Infiniband device and B<MTU>
is larger than 2044, then I<connected mode> is also set.  It is considered
an error to specify B<MTU>s for interfaces that share the same base device
(e.g. eth0 and eth0:1).

=item GW[,GW]

Change or add a route to a network through this IPv4 B<GW> address
(optional).  If multiple B<GW> addresses are given, set them up as an Equal
Cost Multi-Path route.  In this case, validate (ping, with exponential
backoff) each B<GW> before including it in the ECMP route.

=item NW/Prefix[,NW/Prefix]

Use IPv4 B<NW/Prefix> as the destination network of the specified B<GW>
route above (optional, but if not specified B<GW> is considered a
I<default> route).  If multiple B<NW/Prefix> networks are given, install a
route through B<GW> to each of them.  It is not permitted to specify more
than one default route for a given B<Node>.

=back

Note that many fields of the B<Interface Ruleset Form> are optional.  To
omit action taken upon a given field's definition, you may use any single
non-whitespace character to do so (e.g. I<*>, I<->, etc).  See the B<SAMPLE
CONFIGURATION FILE> below.

=head1 SAMPLE CONFIGURATION FILE

   # Set a hostname
   node0 node0.my.domain


   # Assign an IP address and set default GW
   #Node  Host  IF    IP/Prefix   MTU  GW         NW/Prefix
   node1   *    eth0  1.2.3.4/24   *   1.2.3.254  default


   # Configure a device and an alias
   #Node  Host               IF      IP/Prefix       MTU   GW
   node2  node2.localdomain  eth1    5.6.7.8/24      9000  5.6.7.254
   node2       ~             eth1:0  55.66.77.88/24


   # Configure a bonded interface; contextually show verbose output
   #Node  Host  IF               IP/Prefix       MTU  GW
   VERBOSE = 1
   node3   -    bond0=eth2,eth3  11.22.33.44/16   -   11.22.255.254
   VERBOSE = 0


   IntraNet='128.165.0.0/16,141.111.0.0/16'
   ECMP_gw = "10.128.0.252,10.128.0.253,10.128.0.254"

   # Configure an interface with an ECMP route to the IntraNet
   #Node  Host            IF   IP/Prefix      MTU    GW        NW/Prefix
   node4  node4.lanl.gov  ib0  10.128.0.4/24  65520  $ECMP_gw  $IntraNet


   LANE1    = '192.168.0.0/24'
   LANE2    = '192.168.0.1/24'
   ECMP_gw1 = '172.16.0.251,172.16.0.252'
   ECMP_gw2 = '172.16.0.253,172.16.0.254'

   # Define a multi-lane configuration; contextually disable the ping
   # response cache when evaluating ECMP route(s).
   #Node  Host  IF   IP/Prefix      MTU    GW                  NW/Prefix
   PINGCACHE = no
   node5   ^    ib0  172.16.0.5/24  65520
   node5   ^    ib0       ^          ^     $ECMP_gw1           $LANE1
   node5   ^    ib0       ^          ^     $ECMP_gw2           $LANE2
   node5   ^    ib0       ^          ^     $ECMP_gw1,$ECMP_gw2 default
   PINGCACHE = yes


   # Debug an IP address and route assignment.  WARNING: this will NOT
   # modify any configuration of eth0 but simply print debug statements
   # to show what would be done.  You can override this behavior without
   # modifying the configuration file by specifying "--no-debug" on the
   # command line.
   #Node  Host  IF    IP/Prefix        MTU  GW              NW/Prefix
   DEBUG = on
   node6   *    eth0  111.222.33.4/24   *   111.222.33.254  default
   DEBUG = off

=head1 EXAMPLES

   % ethcfg generate --nodes node[1-6] --hostname %node%.my.domain \
     --if eth0 --ip 44.33.222.1/29 --mtu 1500 --gw '$ECMP_gw'
   node1  node1.my.domain  eth0  44.33.222.1/29  1500  $ECMP_gw  default
   node2  node2.my.domain  eth0  44.33.222.2/29  1500  $ECMP_gw  default
   node3  node3.my.domain  eth0  44.33.222.3/29  1500  $ECMP_gw  default
   node4  node4.my.domain  eth0  44.33.222.4/29  1500  $ECMP_gw  default
   node5  node5.my.domain  eth0  44.33.222.5/29  1500  $ECMP_gw  default
   node6  node6.my.domain  eth0  44.33.222.6/29  1500  $ECMP_gw  default

=head1 FILES

F</proc/cmdline>, F</proc/cray_xt/cname>, F</etc/sysconfig/ethcfg>,
F</etc/modprobe.conf>, F</etc/modprobe.d>

=head1 CAVEATS

There is no stop function (yet).

=head1 SEE ALSO

ifenslave(8), ip(8), modprobe(8)

=head1 AUTHOR

Daryl W. Grunau <dwg@lanl.gov>

=head1 COPYRIGHT AND LICENSE

Copyright 2013 by Daryl W. Grunau

Unless otherwise indicated, this information has been authored by an employee
or employees of the Los Alamos National Security, LLC (LANS), operator of the
Los Alamos National Laboratory under Contract No.  DE-AC52-06NA25396 with the
U.S. Department of Energy.  The U.S. Government has rights to use, reproduce,
and distribute this information. The public may copy and use this information
without charge, provided that this Notice and any statement of authorship are
reproduced on all copies. Neither the Government nor LANS makes any warranty,
express or implied, or assumes any liability or responsibility for the use of
this information.

This program has been approved for release from LANS by LA-CC Number 10-066,
being part of the HPC Operational Suite.

=cut

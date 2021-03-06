#!/usr/bin/perl

=begin copyright
	Generate script for input to nsupdate

	Copyright (C) 2015  Robert Nelson

	This program is free software: you can redistribute it and/or modify
	it under the terms of the GNU General Public License as published by
	the Free Software Foundation, either version 3 of the License, or
	(at your option) any later version.

	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with this program.  If not, see <http://www.gnu.org/licenses/>.

=end copyright

=cut

use 5.010;
use strict;
use warnings;

use Getopt::Long qw(:config gnu_getopt auto_help auto_version);
use Pod::Usage;
use NetAddr::IP qw(:lower);

our $VERION = '0.9.0';
my @ipv4;
my @ipv6;
my %revdomains;
my @input;
my @script;

my $man;
my $verbose = 0;
my $ttl = '3600';
my $server;
my $host;
my $domain;
my $ipinfo;
my $net;
my $output;
my $doadd = 1;
my $dopurge = 1;
my $doforward = 1;
my $doreverse = 1;
my $doipv4 = 1;
my $doipv6 = 1;
my @cnames;

my %opts = (
	'add|a!' => \$doadd,
	'cname|c=s' => \@cnames,
	'domain|d=s' => \$domain,
	'forward|f!' => \$doforward,
	'host|h=s' => \$host,
	'ipinfo|i=s' => \$ipinfo,
	'ipv4|4!' => \$doipv4,
	'ipv6|6!' => \$doipv6,
	'man|m' => \$man,
	'net|n=s' => \$net,
	'output|o=s' => \$output,
	'purge|p!' => \$dopurge,
	'reverse|r!' => \$doreverse,
	'server|s=s' => \$server,
	'ttl|t=i' => \$ttl,
	'verbose|v' => \$verbose,
);
GetOptions(%opts);

pod2usage(-exitval => 0, -verbose => 2) if $man;
if (!$host) {
	$host = `hostname -s`;
	chomp $host;
}		
if (!$domain) {
	$domain = `hostname -d`;
	chomp $domain;
}
if (@cnames) {
	@cnames = split(/,/,join(',', @cnames));
}

if ($ipinfo) {
	open(IFH, '<', $ipinfo) or die("Can't open ipinfo: $ipinfo");
	@input = <IFH>;
	close(IFH);
} else {
	if (!$net) {
		$net = 'eth0';
	}
	@input = `ip addr show $net`;
}

sub addrev($$$) {
	my ($addr, $version, $subnet) = @_;
	my $ipaddr = NetAddr::IP->new($addr);
	my @revarray;
	my $rev;
	my $revdom;

	if ($version == 4) {
		@revarray = split(/\./, $ipaddr->addr());
		@revarray = reverse @revarray;
		$rev = join('.', @revarray).'.in-addr.arpa';
		$revdom = join('.', @revarray[(4-int($subnet/8))..$#revarray]).'.in-addr.arpa';
	} elsif ($version == 6) {
		my $digits = $ipaddr->full();
		$digits =~ s/://g;
		@revarray = split(//, $digits);
		@revarray = reverse @revarray;
		$rev = join('.', @revarray).'.ip6.arpa';
		$revdom = join('.', @revarray[(32-int($subnet/4))..$#revarray]).'.ip6.arpa';
	}

	if (!exists($revdomains{$revdom})) {
		$revdomains{$revdom} = [];
	}
	
	push @{$revdomains{$revdom}}, $rev;
}
my $addr;
my $subnet;

foreach (@input) {
	if (m/^\s+inet\s+(\d{1,3}(\.\d{1,3}){3})\/(\d+).*scope global.*$/) {
		if ($doipv4) {
			$addr = $1;
			$subnet = $3;
			push @ipv4, $addr;
			addrev($addr, 4, $subnet);
		}
	} elsif (m/\s+inet6\s+([[:xdigit:]:]+)\/(\d+).*scope global.*$/) {
		if ($doipv6) {
			$addr = $1;
			$subnet = $2;
			if ($subnet > 64) {
				$subnet = 64;
			}
			push @ipv6, $addr;
			addrev($addr, 6, $subnet);
		}
	}
}
if ($server) {
	push @script, "server $server.";
}
push @script, "zone $domain.";
push @script, "ttl $ttl";
if ($doforward) {
	if ($dopurge) {
		push @script, "update delete $host.$domain. A" if ($doipv4);
		push @script, "update delete $host.$domain. AAAA" if ($doipv6);
	}

	if ($doadd) {
		foreach $addr (@ipv4) {
			push @script, "update add $host.$domain. A $addr";
		}
		foreach $addr (@ipv6) {
			push @script, "update add $host.$domain. AAAA $addr";
		}
		foreach my $alias (@cnames) {
			push @script, "update add $alias.$domain. CNAME $host.$domain.";
		}
	}

	push @script, "send";
	push @script, "answer" if $verbose;
}

if ($doreverse) {
	foreach my $key (keys(%revdomains)) {
		push @script, "zone $key.";
		foreach $addr (@{$revdomains{$key}}) {
			push @script, "update delete $addr PTR" if ($dopurge);
			push @script, "update add $addr PTR $host.$domain." if ($doadd);
		}
		push @script, "send";
		push @script, "answer" if $verbose;
	}
}

my $outscript = join("\n", @script)."\n";

if ($output) {
	open(OFH, '>', $output) or die("Can't open output: $output");
	print OFH $outscript;
	close(OFH);
} else {
	print $outscript;
}

__END__

=head1 NAME

gennsupd - Generate nsupdate script

=head1 SYNOPSIS

gennsupd [options]

Options:

	-?	--help       	brief help message
	-4	--(no)ipv4	(don't) generate IPv4 statements
	-6	--(no)ipv6	(don't) generate IPv6 statements
	-a	--(no)add	(don't) generate add statements
	-c	--cname=s	alias name
	-d	--domain=s	domain name (default hostname -d)
	-f	--(no)forward	(don't) generate forward DNS entries	
	-h	--host=s	host name (default hostname -s)
	-i	--ipinfo=s	file containing output from 'ip addr show' (testing)
	-m	--man           full documentation
	-n	--net=s		network interface (default eth0) (not used if --ipinfo specified)
	-o	--output=s	write script to named file (default stdout)
	-p	--(no)purge	(don't) generate delete statements
	-r	--(no)reverse	(don't) generate reverse DNS entries
	-s	--server=s	DNS server to update
	-t	--ttl=n		time to live in seconds (default 3600)
	-v	--verbose	print verbose diagnostics

In most cases no options are required.

=head1 OPTIONS

=over 8

=item B<--help>

Print a brief help message and exits.


=item B<--man>

Prints the manual page and exits.


=item B<--(no)add>

Generates add statements, since this is the default it is only useful when prefixed with no (eg --noadd).


=item B<--cname=s>

Specify an alias host name.  The option can be repeated or multiple names separated by commas may be specified.


=item B<--domain=s>

Specify the domain name in which the host resides.  If not specified then the result from executing hostname 
with the -d option is used.


=item B<--(no)forward>

Generate forward DNS entries, since this is the default it is only useful when prefixed with no (eg --noforward).


=item B<--host=s>

Specify the name of the host used in the DNS entries.  If not specified then the result from executing hostname 
with the -s option is used.


=item B<--ipinfo=s>

This is primarily used for testing. The argument is a file containing output from 'ip addr show'.


=item B<--(no)ipv4>

Generate IPv4 statements, since this is the default it is only useful when prefixed with no (eg --noipv4).


=item B<--(no)ipv6>

Generate IPv6 statements, since this is the default it is only useful when prefixed with no (eg --noipv6).


=item B<--net=s>

The network interface given as an argument to ip addr show.  It defaults to eth0. It is not used if the 
--ipinfo option is specified).


=item B<--output=s>

Write the output script to git given file.  The default is to use stdout.


=item B<--(no)purge>

Generates delete statements, since this is the default it is only useful when prefixed with no (eg --nopurge).


=item B<--(no)reverse>

Generate reverse DNS entries, since this is the default it is only useful when prefixed with no (eg --noreverse).


=item B<--server=s>

The DNS server to be updated. Normally this doesn't need to be specified, nsupdate uses the primary server for
the domain.  But some versions are buggy and try to send the updates to the default name server in resolv.conf 
resulting in a FORMERR.


=item B<--ttl=n>

The TimeToLive for added DNS entries in seconds. The default is 3600 or one hour.

=item B<--verbose>

Display additional information. Currently it causes the server responses to be printed.

=back

=head1 DESCRIPTION

B<This program> generates a script for nsupdate that removes existing DNS entries 
and adds new ones for the specified host in the given domain.  It also removes and
adds the reverse DNS entries.  Both IPv4 and IPv6 are supported.

Options are available to override the automatically determined data and control the
operations performed.

=cut

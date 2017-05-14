#!/usr/bin/perl

use strict;
use warnings;
use utf8;

 #!/usr/bin/perl
 # client

use IO::Socket::Multicast;

#use constant GROUP => '239.7.7.77';
#use constant PORT  => '35353';

my $mc_addr = '239.7.7.77';
my $mc_port = '35353';

my $sock = IO::Socket::Multicast->new(
           Proto     => 'udp',
           LocalPort => $mc_port,
           ReuseAddr => '1',
           ReusePort => defined(&ReusePort) ? 1 : 0,
  ) or die "ERROR: Cant create socket: $@!";

$sock->mcast_add($mc_addr) or die "ERROR: Couldn't set group: $@!";
  
#my $sock = IO::Socket::Multicast->new(Proto=>'udp',LocalPort=>PORT);
#$sock->mcast_add(GROUP) || die "Couldn't set group: $!\n";

 while (1) {
   my $data;
   next unless $sock->recv($data,4096);
   print $data."\n";
 }
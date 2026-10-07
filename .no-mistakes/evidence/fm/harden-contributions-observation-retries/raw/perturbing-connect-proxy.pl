#!/usr/bin/env perl
# Perturbing CONNECT proxy for live fm-contributions validation.
#
# Real `gh` + real api.github.com; only the network path is perturbed (added
# latency, or a dropped/502'd CONNECT) so the product's own slow-read and
# transient-failure handling can be driven against the real forge.
#
# Usage: proxy.pl <port> <logfile> [<conn>:<action>[:seconds] ...]
#   <conn>   1-based CONNECT ordinal, counted in arrival order
#   <action> delay|fail
#   seconds  delay seconds (default 0)
# Any CONNECT without a rule is tunneled immediately.
use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use POSIX qw(strftime);

my $port = shift @ARGV or die "usage: proxy.pl <port> <logfile> [conn:action[:secs] ...]\n";
my $log  = shift @ARGV or die "usage: proxy.pl <port> <logfile> [conn:action[:secs] ...]\n";
my %rule;
for my $r (@ARGV) {
  my ($n, $action, $secs) = split /:/, $r, 3;
  $rule{$n} = [$action, $secs];
}

open(my $LOG, '>>', $log) or die "open $log: $!";
$LOG->autoflush(1);
sub ts { return strftime('%H:%M:%S', localtime) }

my $server = IO::Socket::INET->new(
  LocalAddr => '127.0.0.1', LocalPort => $port, Listen => 128,
  ReuseAddr => 1, Proto => 'tcp') or die "listen on $port: $!";
print $LOG ts() . " proxy listening on 127.0.0.1:$port\n";

$SIG{CHLD} = 'IGNORE';
my $count = 0;
while (my $client = $server->accept) {
  $count++;
  my $n = $count;
  if (my $pid = fork) {
    close $client;
    next;
  }
  close $server;
  my $line = <$client>;
  $line = '' unless defined $line;
  $line =~ s/\r?\n$//;
  my ($method, $target) = split / /, $line;
  while (my $h = <$client>) { last if $h =~ /^\r?\n$/; }
  my $r = $rule{$n};
  my $action = $r ? $r->[0] : 'pass';
  my $secs = ($r && defined $r->[1]) ? $r->[1] : 0;

  if ($action eq 'fail') {
    print $LOG ts() . " #$n $target FAIL (CONNECT 502)\n";
    print $client "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    close $client;
    exit 0;
  }
  if ($action eq 'delay') {
    print $LOG ts() . " #$n $target DELAY ${secs}s begin\n";
    sleep $secs;
    print $LOG ts() . " #$n $target DELAY ${secs}s end\n";
  }
  my ($host, $hport) = split /:/, $target, 2;
  $hport = 443 unless defined $hport;
  my $upstream = IO::Socket::INET->new(
    PeerAddr => $host, PeerPort => $hport, Proto => 'tcp', Timeout => 30);
  if (!$upstream) {
    print $LOG ts() . " #$n $target UPSTREAM-CONNECT-FAILED\n";
    print $client "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    close $client;
    exit 0;
  }
  print $client "HTTP/1.1 200 Connection established\r\n\r\n";
  print $LOG ts() . " #$n $target TUNNEL\n";
  my $sel = IO::Select->new($client, $upstream);
  while (my @ready = $sel->can_read(600)) {
    for my $fh (@ready) {
      my $nread = sysread($fh, my $buf, 65536);
      if (!defined $nread || $nread == 0) {
        close $client;
        close $upstream;
        print $LOG ts() . " #$n $target CLOSE\n";
        exit 0;
      }
      my $other = ($fh == $client) ? $upstream : $client;
      my $off = 0;
      while ($off < length $buf) {
        my $w = syswrite($other, $buf, length($buf) - $off, $off);
        last unless defined $w && $w > 0;
        $off += $w;
      }
      if ($off < length $buf) {
        close $client;
        close $upstream;
        print $LOG ts() . " #$n $target WRITE-FAIL\n";
        exit 0;
      }
    }
  }
  close $client;
  close $upstream;
  print $LOG ts() . " #$n $target EOF\n";
  exit 0;
}

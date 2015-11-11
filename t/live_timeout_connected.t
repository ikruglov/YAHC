#!/usr/bin/env perl

use strict;
use warnings;

use YAHC qw/yahc_conn_errors/;
use Net::Ping;
use Test::More;
use Data::Dumper;
use Time::HiRes qw/time/;

unless ($ENV{TEST_LIVE}) {
    plan skip_all => "Enable live testing by setting env: TEST_LIVE=1";
}

# find a ip and confirm it is not reachable.
my $pinger = Net::Ping->new("tcp", 2);
$pinger->port_number(80);

my $ip;
my $iter = 10;
do {
    $ip = join ".", 172, (int(rand()*15+16)), int(rand()*250+1),  int(rand()*255+1);
} while($iter-- > 0 && $pinger->ping($ip));

if ($iter == 0) {
    plan skip_all => "Cannot randomly generate an unreachable IP."
}

pass "ip generated = $ip";

local $SIG{ALRM} = sub { BAIL_OUT('ALARM') };
alarm(10); # 10 sec of timeout

my ($yahc, $yahc_storage) = YAHC->new();

my $timeout = 0.5;
my $start = time;
my $conn = $yahc->request({
    host            => $ip,
    connect_timeout => $timeout,
});

$yahc->run(YAHC::State::CONNECTED);

my $elapsed = time - $start;
ok($elapsed <= $timeout * 2, "elapsed is roughly same as timeout");

my @found_error = grep {
   $_->[0] == YAHC::Error::CONNECT_TIMEOUT()
} @{ yahc_conn_errors($conn) };

ok(@found_error > 0, sprintf("connection timed out in %.3f sec (should timeout in %.3f sec)", $elapsed, $timeout));

done_testing;

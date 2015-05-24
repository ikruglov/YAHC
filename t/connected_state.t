#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Data::Dumper;
use IO::Socket::INET;
use YAHC;
use EV;

my $host = 'localhost',
my $port = '8888';
my $message = 'TEST';
my $pid = fork;
defined $pid or die "failed to fork";
if ($pid == 0) {
    my $sock = IO::Socket::INET->new(
        Proto       => 'tcp',
        LocalHost   => '0.0.0.0',
        LocalPort   => $port,
        ReuseAddr   => 1,
        Blocking    => 1,
        Listen      => 1,
        Timeout     => 3,
    ) or die "failed to create socket in child: $!";

    local $SIG{ALRM} = sub { exit 0 };
    alarm(10); # 10 sec of timeout

    my $client = $sock->accept or die "failed to accept connection in child: $!";
    $client && $client->send($message);
    exit 0;
}

my ($yahc, $yahc_storage) = YAHC->new;
my $conn = $yahc->request({
    host => $host,
    port => $port,
    keep_timeline => 1,
    _test => 1,
});

$yahc->_set_init_state($conn->{id});
$yahc->run(YAHC::State::CONNECTED(), $conn->{id});

ok($conn->{state} == YAHC::State::CONNECTED(), "check state")
    or diag("got:\n" . YAHC::_strstate($conn->{state}) . "\nexpected:\nSTATE_CONNECTED\ntimeline: " . Dumper($conn->{timeline}));

my $fh = $yahc->{watchers}{$conn->{id}}{_fh};
ok(defined $fh, "socket is defined");

if (defined $fh) {
    my $buf = '';
    while (1) {
        my $rlen = sysread($fh, $buf, length($message));
        next if !defined($rlen) && ($! == POSIX::EAGAIN || $! == POSIX::EWOULDBLOCK || $! == POSIX::EINTR);
        last;
    }

    ok($buf eq $message, "received expected message")
        or diag("got:\n$buf\nexpected:\n$message");
}

done_testing;

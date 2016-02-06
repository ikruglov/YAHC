#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp ();
use File::Temp qw/ :seekable /;
use Data::Dumper;
use YAHC;
use EV;

my $ppid = $$;
my $pid = fork;
defined $pid or die "failed to fork: $!";
if ($pid == 0) {
    sleep 5;
    kill 'KILL', $ppid;
    exit;
}

pipe(my $rh, my $wh) or die "can't create pipe: $!";

my ($yahc, $yahc_storage) = YAHC->new({
    account_for_signals => 1
});

my $conn = $yahc->request({
    host => 'DUMMY',
    _test => 1,
});

$yahc->{watchers}{$conn->{id}} = {
    _fh => $rh,
    io  => $yahc->loop->io($rh, EV::READ, sub {})
};

$yahc->_set_read_state($conn->{id});

my $sigalrm = 0;
$SIG{ALRM} = sub {
    $sigalrm = 1;
    $yahc->break;
};

alarm(2);

$yahc->run;
ok($sigalrm == 1, 'SIGALRM handler has been called');

END { kill 'KILL', $pid if $pid }

done_testing;

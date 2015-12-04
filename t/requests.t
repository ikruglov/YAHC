#!/usr/bin/env perl

use strict;
use warnings;

use YAHC qw/yahc_conn_last_error yahc_conn_errors yahc_conn_state yahc_reinit_conn/;
use FindBin;
use Test::More;
use Data::Dumper;

unless ($ENV{TEST_LIVE}) {
    plan skip_all => "Enable live testing by setting env: TEST_LIVE=1";
}

my $host = 'localhost',
my $port = '5001';
my $message = 'TEST';

pipe(my $rh, my $wh) or die "failed to pipe: $!";

my $pid = fork;
defined $pid or die "failed to fork: $!";

if ($pid == 0) {
    require Plack::Runner;
    my $runner = Plack::Runner->new;
    $runner->parse_options("--host", $host, "--port", $port);

    local $SIG{ALRM} = sub { exit 0 };
    alarm(20); # 20 sec of timeout
    close($wh); # signal parent process
    close($rh);

    exit $runner->run(sub {
        return [200, [], []]
    });
}

# wait for child process
close($wh);
sysread($rh, my $b = '', 1);
close($rh);

sleep 5; # hope this will be enough to start Plack::Runner

my ($yahc, $yahc_storage) = YAHC->new;
subtest "callbacks" => sub {
    my $init_callback;
    my $wait_synack_callback;
    my $connected_callback;
    my $writing_callback;
    my $reading_callback;
    my $callback;

    my $c = $yahc->request({
        host => $host,
        port => $port,
        retries => 5,
        request_timeout => 1,
        init_callback        => sub { $init_callback = 1 },
        wait_synack_callback => sub { $wait_synack_callback = 1 },
        connected_callback   => sub { $connected_callback = 1 },
        writing_callback     => sub { $writing_callback = 1 },
        reading_callback     => sub { $reading_callback = 1 },
        callback             => sub { $callback = 1 },
    });

    $yahc->run;

    ok !yahc_conn_last_error($c), "no errors";
    if (yahc_conn_last_error($c)) {
        diag Dumper(yahc_conn_errors($c));
    }

    ok $init_callback,          "init_callback is called";
    ok $wait_synack_callback,   "wait_synack_callback is called";
    ok $connected_callback,     "connected_callback is called";
    ok $writing_callback,       "writing_callback is called";
    ok $reading_callback,       "reading_callback is called";
    ok $callback,               "callback is called";
};

subtest "retry" => sub {
    my $c = $yahc->request({
        host => [ $host . "_non_existent", $host ],
        port => $port,
        retries => 1,
        request_timeout => 1,
    });

    $yahc->run;

    cmp_ok($c->{response}{status}, '==', 200, "We got a 200 OK response");
    cmp_ok(yahc_conn_state($c), '==', YAHC::State::COMPLETED(), "We got COMPLETED state");
};

subtest "reinitiaize connection" => sub {
    my $first_attempt = 1;
    my $c = $yahc->request({
        host => $host . "_non_existent",
        port => $port,
        request_timeout => 1,
        callback => sub {
            my ($conn, $err) = @_;
            yahc_reinit_conn($conn, { host => $host }) if $err && $first_attempt;
            $first_attempt = 0;
        },
    });

    $yahc->run;

    ok !$first_attempt;
    cmp_ok($c->{response}{status}, '==', 200, "We got a 200 OK response");
    cmp_ok(yahc_conn_state($c), '==', YAHC::State::COMPLETED(), "We got COMPLETED state");
};

END { kill 'KILL', $pid if $pid }

done_testing;

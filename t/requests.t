#!/usr/bin/env perl

use strict;
use warnings;

use YAHC qw/
    yahc_conn_state
    yahc_reinit_conn
    yahc_conn_errors
    yahc_conn_attempt
    yahc_conn_last_error
/;

use FindBin;
use Test::More;
use Data::Dumper;
use Time::HiRes qw/time sleep/;

my $chars = 'qwertyuiop[]asdfghjkl;\'zxcvbnm,./QWERTYUIOP{}":LKJHGFDSAZXCVBNM<>?1234567890-=+_)(*&^%$#@!\\ ' . "\n\t\r";

sub generate_sequence {
    my $len = shift;
    my $lc = length($chars);
    my $out = '';

    while ($len-- > 0) {
        $out .= substr($chars, rand($lc), 1);
    }

    return $out;
}

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
    $runner->parse_options("--host", $host, "--port", $port, "--no-default-middleware");

    local $SIG{ALRM} = sub { exit 0 };
    alarm(60); # 60 sec of timeout
    close($wh); # signal parent process
    close($rh);

    exit $runner->run(sub {
        my $body = '';
        read($_[0]->{'psgi.input'}, $body, $_[0]->{CONTENT_LENGTH} || 0);
        return [200, ['Content-Type' => 'raw'], [$body]];
    });
}

# wait for child process
close($wh);
sysread($rh, my $b = '', 1);
close($rh);

sleep 5; # hope this will be enough to start Plack::Runner

my ($yahc, $yahc_storage) = YAHC->new;

for my $len (0, 1, 2, 8, 23, 345, 1024, 65535, 131072, 9812, 19874, 1473451, 10000000) {
    subtest "content_length_$len" => sub {
        my $body = generate_sequence($len);
        my $c = $yahc->request({ host => $host, port => $port, body => $body });
        $yahc->run;

        cmp_ok($c->{response}{body}, 'eq', $body, "We got expected body");
        cmp_ok($c->{response}{head}{'Content-Length'}, '==', $len, "We got expected Content-Length");
        cmp_ok($c->{response}{head}{'Content-Type'}, 'eq', 'raw', "We got expected Content-Type");
    };
}

subtest "callbacks" => sub {
    my $init_callback;
    my $connecting_callback;
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
        connecting_callback => sub { $connecting_callback = 1 },
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
    ok $connecting_callback,    "connecting_callback is called";
    ok $connected_callback,     "connected_callback is called";
    ok $writing_callback,       "writing_callback is called";
    ok $reading_callback,       "reading_callback is called";
    ok $callback,               "callback is called";
};

subtest "connect_timeout" => sub {
    my $c = $yahc->request({
        host => $host,
        port => $port,
        connect_timeout => 0.1,
        connecting_callback => sub { sleep 0.2 },
    });

    $yahc->run;

    my $has_timeout = grep { $_->[0] & YAHC::Error::CONNECT_TIMEOUT() } @{ yahc_conn_errors($c) || []};
    is($has_timeout, 1, "We got YAHC::Error::CONNECT_TIMEOUT()");
    cmp_ok($c->{response}{status}, '!=', 200, "We didn't get a 200 OK response");
};

subtest "drain_timeout" => sub {
    my $c = $yahc->request({
        host => $host,
        port => $port,
        drain_timeout => 0.1,
        writing_callback => sub { sleep 0.2 },
    });

    $yahc->run;

    my $has_timeout = grep { $_->[0] & YAHC::Error::DRAIN_TIMEOUT() } @{ yahc_conn_errors($c) || []};
    is($has_timeout, 1, "We got YAHC::Error::DRAIN_TIMEOUT()");
    cmp_ok($c->{response}{status}, '!=', 200, "We didn't get a 200 OK response");
};

subtest "request_timeout" => sub {
    my $c = $yahc->request({
        host => $host,
        port => $port,
        request_timeout => 0.1,
        reading_callback => sub { sleep 0.2 },
    });

    $yahc->run;

    my $has_timeout = grep { $_->[0] & YAHC::Error::REQUEST_TIMEOUT() } @{ yahc_conn_errors($c) || [] };
    is($has_timeout, 1, "We got YAHC::Error::REQUEST_TIMEOUT()");
    cmp_ok($c->{response}{status}, '!=', 200, "We didn't get a 200 OK response");
};

subtest "lifetime_timeout" => sub {
    my $c = $yahc->request({
        host => $host,
        port => $port,
        lifetime_timeout => 0.1,
        writing_callback => sub { sleep 0.2 },
    });

    $yahc->run;

    my $has_timeout = grep { $_->[0] & YAHC::Error::LIFETIME_TIMEOUT() } @{ yahc_conn_errors($c) || [] };
    is($has_timeout, 1, "We got YAHC::Error::LIFETIME_TIMEOUT()");
    cmp_ok($c->{response}{status}, '!=', 200, "We didn't get a 200 OK response");
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

subtest "retry with backoff delay" => sub {
    my $c = $yahc->request({
        host => [ $host . "_non_existent", $host . "_non_existent_1", $host ],
        port => $port,
        retries => 2,
        backoff_delay => 2,
        request_timeout => 1,
    });

    my $start = time;
    $yahc->run;
    my $elapsed = time - $start;

    cmp_ok($c->{response}{status}, '==', 200, "We got a 200 OK response");
    cmp_ok(yahc_conn_state($c), '==', YAHC::State::COMPLETED(), "We got COMPLETED state");
    cmp_ok($elapsed, '>=', 4, "elapsed is greater than backoff_delay * retries")
};

subtest "retry with backoff delay due to timeout" => sub {
    my $start = time;

    my $c = $yahc->request({
        host => [ $host, $host . '_non_existent', $host ],
        port => $port,
        retries => 2,
        backoff_delay => 4,
        connect_timeout => 0.5,
        connecting_callback => sub {
            sleep 1 if yahc_conn_attempt($_[0]) <= 1; # fail 1st and and 2nd attempts
        },
    });

    $yahc->run;
    my $elapsed = time - $start;

    cmp_ok($c->{response}{status}, '==', 200, "We got a 200 OK response");
    cmp_ok(yahc_conn_state($c), '==', YAHC::State::COMPLETED(), "We got COMPLETED state");
    cmp_ok($elapsed, '>=', 4, "elapsed is greater than backoff_delay");

    my @errors = @{ yahc_conn_errors($c) || [] };
    ok(@errors == 2, "We got two errors");

    if (@errors == 2) {
        ok($errors[0][0] & YAHC::Error::CONNECT_TIMEOUT(), "First error is CONNECT_TIMEOUT");
        ok($errors[1][0] & YAHC::Error::CONNECT_ERROR(), "Second error is CONNECT_ERROR");
    }
};

subtest "retry with backoff delay and lifetime timeout" => sub {
    my $c = $yahc->request({
        host => [ $host . "_non_existent", $host . "_non_existent_1", $host ],
        port => $port,
        retries => 2,
        backoff_delay => 1,
        request_timeout => 1,
        lifetime_timeout => 4,
    });

    my $start = time;
    $yahc->run;
    my $elapsed = time - $start;

    cmp_ok(int($elapsed), '<=', 4, "elapsed is smaller than lifetime");
    cmp_ok($c->{response}{status}, '==', 200, "We didn't get 200 OK response");
    cmp_ok(yahc_conn_state($c), '==', YAHC::State::COMPLETED(), "We got COMPLETED state");
};

subtest "retry with backoff delay and lifetime timeout triggering lifetime timeout" => sub {
    my $c = $yahc->request({
        host => [ $host . "_non_existent", $host . "_non_existent_1", $host ],
        port => $port,
        retries => 2,
        backoff_delay => 2,
        request_timeout => 1,
        lifetime_timeout => 4,
    });

    my $start = time;
    $yahc->run;
    my $elapsed = time - $start;

    my ($err) = yahc_conn_last_error($c);
    cmp_ok($err & YAHC::Error::LIFETIME_TIMEOUT(), '==', YAHC::Error::LIFETIME_TIMEOUT(), "We got lifetime timeout");
    cmp_ok(int($elapsed), '<=', 4, "elapsed is smaller than lifetime");
    cmp_ok($c->{response}{status}, '!=', 200, "We didn't get 200 OK response");
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

#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::Exception;
use YAHC qw/yahc_conn_last_error yahc_conn_errors/;

unless ($ENV{TEST_LIVE}) {
    plan skip_all => "Enable live testing by setting env: TEST_LIVE=1";
}

if($ENV{http_proxy}) {
    plan skip_all => "http_proxy is set. We cannot test when proxy is required to visit google.com";
}

my %args = (
    host => "google.com",
    port => "80",
    method => "GET",
);

subtest "with 10 microseconds timeout limit, expect an exception." => sub {
    lives_ok {
        my ($yahc, $yahc_storage) = YAHC->new();
        my $c= $yahc->request({ %args, connect_timeout => 0.00001 });
        $yahc->run;

        ok yahc_conn_last_error($c);
        my @found_error = grep {
           $_->[0] == YAHC::Error::CONNECT_TIMEOUT()
        } @{ yahc_conn_errors($c) || [] };
        ok @found_error > 0;
    };
};

subtest "with 10s timeout limit, do not expect an exception." => sub {
    lives_ok {
        my ($yahc, $yahc_storage) = YAHC->new();
        my $c = $yahc->request({ %args, connect_timeout => 10 });
        $yahc->run;
        ok !yahc_conn_last_error($c);
        diag substr($c->{response}{body}, 0, 80);
    } 'google.com send back something within 10s';
};

subtest "without timeout, do not expect an exception." => sub {
    lives_ok {
        my ($yahc, $yahc_storage) = YAHC->new();
        my $c = $yahc->request({ %args });
        $yahc->run;
        ok !yahc_conn_last_error($c);
    } 'google.com send back something without timeout';
};

subtest "cache" => sub {
    lives_ok {
        my ($yahc, $yahc_storage) = YAHC->new();
        my $c = $yahc->request({ %args });
        $yahc->run;
        ok !yahc_conn_last_error($c), 'We expect no errors';
        cmp_ok scalar(keys %{ $yahc->socket_cache || {} }), '==', 0, "No caching unless set";
    } "We could make the request";

    lives_ok {
        my ($yahc, $yahc_storage) = YAHC->new({ socket_cache => {} });
        my $c = $yahc->request({ %args });
        $yahc->run;
        ok !yahc_conn_last_error($c), 'We expect no errors';
        cmp_ok scalar(keys %{ $yahc->socket_cache || {} }), '==', 1, "We have an entry in socket cache";
    } "We could make the request";

    lives_ok {
        my ($yahc, $yahc_storage) = YAHC->new({ socket_cache => {} });

        my $num_of_connections = 0;
        my $c1 = $yahc->request({
            %args,
            reuse_socket => 1,
            connected_callback => sub { $num_of_connections++ },
        });

        $yahc->run;
        ok !yahc_conn_last_error($c1), 'We expect no errors';

        my $c2 = $yahc->request({
            %args,
            reuse_socket => 1,
            connected_callback => sub { $num_of_connections++ },
        });

        $yahc->run;
        ok !yahc_conn_last_error($c2), 'We expect no errors';

        cmp_ok scalar(keys %{ $yahc->socket_cache || {} }), '==', 1, "We have only one entry in cache due to reuse of socket";
        cmp_ok $num_of_connections, '==', 1, "Also connection_callback should be called only once";
    } "We could make the request";
};

done_testing();

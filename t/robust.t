#!/usr/bin/env perl

use strict;
use warnings;

use POSIX;
use FindBin;
use HTTP::Tiny;
use Test::More;
use Data::Dumper;
use JSON qw/decode_json/;
use Time::HiRes qw/time sleep/;
use TestUtils;

unless ($ENV{TEST_ROBUST}) {
    plan skip_all => "Enable robust testing by setting env: TEST_ROBUST=1";
}

my $host = 'localhost',
my $port = '5003';
TestUtils::start_plack_server($host, $port);

subtest "robustness to signals" => sub {
    pipe(my $rh, my $wh) or die "failed to pipe: $!";

    my $ht = HTTP::Tiny->new();
    ok($ht->get("http://$host:$port/reset")->{success}, "reset server counters")
      or return;

    note("$$ generating request bodies");
    my $nreports = 50;
    my @bodies = map { TestUtils::_generate_sequence(int(rand(1024 * 1024)))} (1..$nreports);
    note("$$ done");

    my $pid = TestUtils::_fork(sub {
        my $sigcnt = 0;
        local $SIG{HUP}  = 'IGNORE';
        local $SIG{USR1} = sub { $sigcnt++ };
        local $SIG{USR2} = sub { $sigcnt++ };

        require YAHC;
        my ($yahc, $yahc_storage) = YAHC->new({ account_for_signals => 1 });

        syswrite($wh, '1', 1);
        close($wh); # signal parent process
        close($rh);

        note("$$ client process start sending requests");
        for (my $i = 0; $i < scalar @bodies; $i++) {
            my $conn = $yahc->request({
                host         => $host,
                port         => $port,
                body         => $bodies[$i],
                path         => '/record',
                query_string => "sigcnt=$sigcnt",
            });

            $yahc->run;
        }

        note("$$ client process is done");
    });

    note("$$ waiting for client to be ready");
    sysread($rh, my $b = '', 1);
    close($wh);
    close($rh);

    my $exit_code = 1024;
    my @signals = ('HUP', 'USR1', 'USR2', 'USR1', 'USR2' );
    note("$$ start spaming client with signals " . join(',', @signals));

    my $t0 = time;
    my $do_spam = 1;

    while (1) {
        if (waitpid($pid, WNOHANG) != 0) {
            $exit_code = ($? >> 8);
            last;
        }

        if ($t0 + 10 < time) {
            note("stop spaming");
            $do_spam = 0;
        }

        if ($do_spam) {
            for (my $t0 = time; $t0 + 0.1 >= time;) {
                my $sig = $signals[int(rand(scalar @signals))];
                # note("send $sig to $pid");
                kill $sig, $pid;
            }
        } else {
            sleep 0.1;
        }
    }

    cmp_ok($exit_code, '==', 0, "client process exited with success")
        or return;

    note("$$ analizing report");
    my $resp = $ht->get("http://$host:$port/report");
    ok($resp->{success}, "got report")
        or return;

    my @report = @{ decode_json($resp->{content} || '{}') };
    cmp_ok(scalar @report, '==', $nreports, "got $nreports reports");

    my $total_sigcnt = 0;
    my @report_body_lengths;
    my @body_length = map { length $_ } @bodies;

    foreach my $r (@report) {
        my $len = $r->{body_length} || 0;
        push @report_body_lengths, $len;
        my (undef, $sigcnt) = split(/=/, $r->{query_string} || '');
        note("client received $sigcnt signals during request of $len bytes");
        $total_sigcnt += $sigcnt;
    }

    cmp_ok($total_sigcnt, '>', 0, "client process received signals");
    is_deeply(\@report_body_lengths, \@body_length, "bodies' length match");
};

END {
    kill 'KILL', $_ foreach TestUtils::_pids;
}

done_testing;

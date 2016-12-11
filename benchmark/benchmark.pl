#!/usr/bin/env perl

use strict;
use warnings;
use Find::Lib 'lib', '../lib/';

use YAHC;
use Time::HiRes;
use Benchmark qw(cmpthese :hireswallclock);
use Getopt::Long qw(GetOptions);
use Data::Dumper;

my $help = 0;
my $host = '127.0.0.1';
my $port = 5000;
my $file = '/lib/YAHC.pm';
my $parallel = 10;
my $timeout = 10;
my $requests = 5000;
my $early_dispatch = 0;
my $persistent = 0;
my $libraries = [qw/YAHC WWW::Curl::UserAgent WWW::Curl::Multi Mojo Mojo2 LWP::Parallel::UserAgent AnyEvent::HTTP/];

GetOptions(
    'parallel=i'      => \$parallel,
    'requests=i'      => \$requests,
    'host=s'          => \$host,
    'port=i'          => \$port,
    'file=s'          => \$file,
    'library=s@'      => \$libraries,
    'early_dispatch=i'=> \$early_dispatch,
    'persistent'      => \$persistent,
    'help'            => \$help,
) or die "bad option";

if ($help) {
    print "Supported libraries: " . join(', ', @{ $libraries }) . "\n";
    exit 0;
}

my $duration = int($requests / $parallel);
my $url = "http://$host:$port/$file";
my $full_path = "../$file";
die "file doesn't exists $file" unless -f $full_path;
my @stats = stat($full_path);
my $expected_content_length = $stats[7];

my %these;
my %to_execute = map { $_ => 1 } @{ $libraries };
my %requests_completed = map { $_ => 0 } @{ $libraries };

delete $ENV{$_} for qw/http_proxy https_proxy HTTP_PROXY HTTPS_PROXY/;

if ($to_execute{YAHC}) {
    require YAHC;

    my $head;
    my $socket_cache_cb;
    if ($persistent) {
        my %socket_cache;
        $head = [ 'Keep-Alive' => 300 ];
        $socket_cache_cb = sub {
            my ($op, $conn, $sock) = @_;
            if ($op == YAHC::SocketCache::GET()) {
                my $socket_cache_id = YAHC::yahc_conn_socket_cache_id($conn) or return;
                return shift @{ $socket_cache{$socket_cache_id} //= [] };
            } elsif ($op == YAHC::SocketCache::STORE()) {
                my $socket_cache_id = YAHC::yahc_conn_socket_cache_id($conn) or return;
                push @{ $socket_cache{$socket_cache_id} //= [] }, $sock;
                return;
            }
        };
    }

    $these{YAHC} = sub {
        my ($yahc, $yahc_storage) = YAHC->new({ socket_cache => $socket_cache_cb });

        foreach my $id (1..$parallel) {
            $yahc->request({
                host     => $host,
                port     => $port,
                path     => $file,
                head     => $head,
                request_timeout => $timeout,
                connect_timeout => $timeout,
                callback => sub {
                    my ($conn, $error, $strerror) = @_;
                    if ($conn->{response}{status} == 200) {
                        warn "wrong result" unless length($conn->{response}{body}) == $expected_content_length;
                        $requests_completed{YAHC}++;
                    } else {
                        warn $strerror;
                    }
                }
            });

            $yahc->run_tick if $early_dispatch && ($id % $early_dispatch == 0);
        }

        $yahc->run;
    }
}

if ($to_execute{'AnyEvent::HTTP'}) {
    require AnyEvent;
    require AnyEvent::HTTP;
    AnyEvent::HTTP->import();

    my $url = "http://$host:${port}${file}";
    $these{'AnyEvent::HTTP'} = sub {
        my $cv = AnyEvent->condvar;

        foreach my $id (1..$parallel) {
            $cv->begin;
            http_get($url, timeout => $timeout, persistent => $persistent, proxy => undef, sub {
                my ($body, $headers) = @_;
                $cv->end;

                if ($headers->{Status} == 200 ) {
                    warn "wront result" unless length($body) == $expected_content_length;
                    $requests_completed{'AnyEvent::HTTP'}++;
                } else {
                    warn $headers->{Reason};
                }
            });
        }

        $cv->recv;
    }
}

if ($to_execute{'WWW::Curl::UserAgent'}) {
    require WWW::Curl::UserAgent;
    warn 'WWW::Curl::UserAgent does not support early dispatch' if $early_dispatch;
    warn 'WWW::Curl::UserAgent persistent is not implemented' if $persistent;
    $these{'WWW::Curl::UserAgent'} = sub {
        my $ua = WWW::Curl::UserAgent->new(
            timeout         => $timeout * 1000,
            connect_timeout => $timeout * 1000,
            parallel_requests => $parallel,
        );

        $ua->add_request(
            request    => HTTP::Request->new(GET => $url),
            on_success => sub {
                my ( $request, $response ) = @_;
                if ($response->is_success) {
                    warn "wrong result" unless length($response->content) == $expected_content_length;
                    $requests_completed{'WWW::Curl::UserAgent'}++;
                } else {
                    warn $response->status_line;
                }
            },
            on_failure => sub {
                my ( $request, $error_msg, $error_desc ) = @_;
                warn "$error_msg: $error_desc";
            },
        ) for (1..$parallel);
        $ua->perform;
    };
}

if ($to_execute{'WWW::Curl::Multi'}) {
    use WWW::Curl::Easy;
    use WWW::Curl::Multi;
    warn 'WWW::Curl::Multi persistent is not implemented' if $persistent;
    $these{'WWW::Curl::Multi'} = sub {
        my $running = 0;
        my %easy;

        open my $null, '>', '/dev/null';
        my $curlm = WWW::Curl::Multi->new;

        my $perform = sub {
            my $transfers = $curlm->perform();
            if ($transfers != $running) {
                while (my ($id, $return_value) = $curlm->info_read) {
                    next unless $id;
                    $running--;

                    my $e = delete $easy{$id};
                    if ($return_value == 0 && $e->getinfo(CURLINFO_HTTP_CODE) == 200) {
                        warn "wrong result" unless $e->getinfo(CURLINFO_CONTENT_LENGTH_DOWNLOAD) == $expected_content_length;
                        $requests_completed{'WWW::Curl::Multi'}++;
                    } else {
                        warn "error in WWW::Curl::Multi";
                    }
                }
            }
        };

        foreach my $id (1..$parallel) {
            my $e = WWW::Curl::Easy->new;
            $e->setopt(CURLOPT_TIMEOUT, $timeout);
            $e->setopt(CURLOPT_CONNECTTIMEOUT, $timeout);
            #$e->setopt(CURLOPT_HEADER, 1);
            $e->setopt(CURLOPT_URL, $url);
            $e->setopt(CURLOPT_PRIVATE, $id);
            $e->setopt(CURLOPT_WRITEDATA, $null);

            $curlm->add_handle($e);
            $easy{$id} = $e;
            $running++;

            $perform->() if $early_dispatch && ($id % $early_dispatch == 0);
        }

        $perform->() while $running;
    }
}

if ($to_execute{Mojo}) {
    require Mojo::IOLoop;
    require Mojo::UserAgent;
    warn 'Mojo persistent is not implemented' if $persistent;
    $these{Mojo} = sub {
        my $ua = Mojo::UserAgent->new(
            connect_timeout => $timeout,
            request_timeout => $timeout,
        );

        my $count = $parallel;
        for my $id (1..$parallel) {
            $ua->get($url => sub {
                my ($ua, $tx) = @_;
                Mojo::IOLoop->stop if --$count == 0;
                if (my $res = $tx->success()) {
                    warn "wrong result" unless length($res->body) == $expected_content_length;
                    $requests_completed{Mojo}++;
                } else {
                    warn $tx->error()->{message};
                }
            });

            Mojo::IOLoop->one_tick if $early_dispatch && ($id % $early_dispatch == 0);
        }

        Mojo::IOLoop->start;
    };
}

if ($to_execute{Mojo2}) {
    warn 'Mojo2 does not support early dispatch' if $early_dispatch;
    warn 'Mojo2 persistent is not implemented' if $persistent;
    require Mojo::UserAgent;
    $these{Mojo2} = sub {
        my $ua = Mojo::UserAgent->new(
            connect_timeout => $timeout,
            request_timeout => $timeout,
        );

        Mojo::IOLoop->delay(sub {
            my $delay = shift;
            for (1..$parallel) {
                my $end = $delay->begin;
                $ua->get($url => sub {
                    my ($ua, $tx) = @_;

                    if (my $res = $tx->success()) {
                        warn "wrong result" unless length($res->body) == $expected_content_length;
                        $requests_completed{Mojo2}++;
                    } else {
                        warn $tx->error()->{message};
                    }

                    $end->();
                });
            }
        })->wait;
    };
}

if ($to_execute{'LWP::Parallel::UserAgent'}) {
    warn 'LWP::Parallel::UserAgent persistent is not implemented' if $persistent;
    require HTTP::Request;
    require LWP::Parallel::UserAgent;
    warn 'LWP::Parallel::UserAgent does not support early dispatch' if $early_dispatch;
    $these{'LWP::Parallel::UserAgent'} = sub {
        my $ua = LWP::Parallel::UserAgent->new();
        $ua->nonblock(1);
        $ua->max_hosts($parallel);

        for (1..$parallel) {
            $ua->register(HTTP::Request->new('GET', $url))
              and warn "LWP::Parallel::UserAgent: fail to send request";
        }

        my $entries = $ua->wait();
        foreach (keys %$entries) {
            my $response = $entries->{$_}->response;
            if ($response->is_success) {
                warn "wrong result" unless length($response->content) == $expected_content_length;
                $requests_completed{'LWP::Parallel::UserAgent'}++;
            } else {
                warn $response->status_line;
            }
        }
    };
}

cmpthese($duration, \%these);

warn "RESULTS UNRELIABLE!!! $_ did $requests_completed{$_} out of $requests requests\n"
    foreach grep { $requests_completed{$_} != $requests }
            keys %requests_completed;

#!/usr/bin/env perl

use strict;
use warnings;

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
my $libraries = [qw/YAHC WWW::Curl::UserAgent WWW::Curl::Multi Mojo LWP::Parallel::UserAgent/];

GetOptions(
    'parallel=i'      => \$parallel,
    'requests=i'      => \$requests,
    'host=s'          => \$host,
    'port=i'          => \$port,
    'file=s'          => \$file,
    'library=s@'      => \$libraries,
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
my %requests_completed;
my %to_execute = map { $_ => 1 } @{ $libraries };

if ($to_execute{YAHC}) {
    require YAHC;
    $these{YAHC} = sub {
        my ($yahc, $yahc_storage) = YAHC->new();

        $yahc->request({
            host     => $host,
            port     => $port,
            path     => $file,
            request_timeout => $timeout,
            connect_timeout => $timeout,
            callback => sub {
                my ($conn, $error, $strerror) = @_;
                if (!$error && $conn->{response}{status_code} == 200) {
                    warn "wrong result" unless length($conn->{response}{body}) == $expected_content_length;
                    $requests_completed{YAHC}++;
                } else {
                    warn $strerror;
                }
            }
        }) for (1..$parallel);
        $yahc->run;
    }
}

if ($to_execute{'WWW::Curl::UserAgent'}) {
    require WWW::Curl::UserAgent;
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
    $these{'WWW::Curl::Multi'} = sub {
        my $running = 0;
        my $id = 1;
        my %easy;

        open my $null, '>', '/dev/null';
        my $curlm = WWW::Curl::Multi->new;

        for (1..$parallel) {
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
            $id++;
        }

        while ($running) {
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
        }
    }
}

if ($to_execute{Mojo}) {
    require Mojo::UserAgent;
    $these{Mojo} = sub {
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
                        $requests_completed{Mojo}++;
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
    require HTTP::Request;
    require LWP::Parallel::UserAgent;
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

warn "$_ did $requests_completed{$_} out of $requests requests\n"
    foreach grep { $requests_completed{$_} != $requests }
            keys %requests_completed;

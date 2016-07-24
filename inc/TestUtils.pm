package TestUtils;

use POSIX;
use Test::More;
use HTTP::Tiny;
use Data::Dumper;
use JSON qw/encode_json/;
use Time::HiRes qw/time sleep/;

my $chars = 'qwertyuiop[]asdfghjkl;\'zxcvbnm,./QWERTYUIOP{}":LKJHGFDSAZXCVBNM<>?1234567890-=+_)(*&^%$#@!\\ ' . "\n\t\r";

sub _generate_sequence {
    my $len = shift;
    my $lc = length($chars);
    my $out = '';

    while ($len-- > 0) {
        $out .= substr($chars, rand($lc), 1);
    }

    return $out;
}

my @PIDS;
sub _pids {
    return @PIDS;
}

sub _fork {
    my ($cb, $lifetime) = @_;
    $lifetime ||= 60;

    my $pid = fork;
    defined $pid or die "failed to fork: $!";

    if ($pid != 0) {
        # return in parent
        push @PIDS, $pid;
        return $pid;
    }

    local $SIG{ALRM} = sub { POSIX::_exit(1) };
    alarm($lifetime); # 60 sec of timeout

    eval {
        $cb->();
        1;
    } or do {
        warn "$@\n";
        POSIX::_exit(1); # avoid running END block
    };

    POSIX::_exit(0); # avoid running END block
}

sub _start_plack_server {
    my ($host, $port) = @_;
    my $ht = HTTP::Tiny->new();

    _fork(sub {
        note("starting plack server at $host:$port");

        require Plack::Runner;
        my $runner = Plack::Runner->new;
        # $runner->parse_options("--host", $host, "--port", $port);
        $runner->parse_options("--host", $host, "--port", $port, "--no-default-middleware");

        my @stats;
        $runner->run(sub {
            my $req = shift;
            my $path = $req->{PATH_INFO};
            if ($path eq '/') {
                return [200, [], []];
            } elsif ($path eq '/ping' ) {
                return [200, [], ['pong']];
            } elsif ($path eq '/reset') {
                @stats = ();
                return [200, [], []];
            } elsif ($path eq '/report') {
                return [200, [], [ encode_json(\@stats) ]];
            } elsif ($path eq '/record') {
                my $body = '';
                read($req->{'psgi.input'}, $body, $req->{CONTENT_LENGTH} || 0);

                push @stats, {
                    query_string => $req->{QUERY_STRING},
                    body_length  => length($body),
                    time         => time,
                };

                return [200, [ 'Content-Type' => $req->{CONTENT_TYPE} ], [$body]];
            } else {
                die "invalid request $path\n";
            }
        })
    });

    note("waiting for plack to be up");

    foreach (1..50) {
        last if $ht->get("http://$host:$port/ping")->{success};
        sleep(0.1);
    }

    $ht->get("http://$host:$port/ping")->{success}
        or die "plack is not up";

    note("plack is up");
}

1;

package YAHC::Request;

use 5.14.2;
use strict;
use warnings;

use DEBUG;
use Time::HiRes;
use Socket qw/$CRLF inet_ntoa/;

sub YAHC::Error::NO_ERROR                () { 0 }
sub YAHC::Error::REQUEST_TIMEOUT         () { 1 << 0 }
sub YAHC::Error::CONNECT_TIMEOUT         () { 1 << 1 }
sub YAHC::Error::READ_TIMEOUT            () { 1 << 2 }
sub YAHC::Error::WRITE_TIMEOUT           () { 1 << 3 }
sub YAHC::Error::CONNECT_ERROR           () { 1 << 4 }
sub YAHC::Error::READ_ERROR              () { 1 << 5 }
sub YAHC::Error::WRITE_ERROR             () { 1 << 6 }
sub YAHC::Error::REQUEST_ERROR           () { 1 << 7 }
sub YAHC::Error::RESPONSE_ERROR          () { 1 << 8 }
sub YAHC::Error::CALLBACK_ERROR          () { 1 << 9 }
sub YAHC::Error::INTERNAL_ERROR          () { 1 << 31 }

sub YAHC::State::INITIALIZED             () { 1 << 0 }
sub YAHC::State::RESOLVE_DNS             () { 1 << 1 }
sub YAHC::State::WAIT_SYNACK             () { 1 << 2 }
sub YAHC::State::CONNECTED               () { 1 << 3 }
sub YAHC::State::WRITING                 () { 1 << 4 }
sub YAHC::State::READING                 () { 1 << 5 }
sub YAHC::State::USER_ACTION             () { 1 << 15 }
sub YAHC::State::COMPLETED               () { 1 << 30 } # terminal state

sub new {
    my ($class, $conn_id, $request, $pool_args) = @_;
    die "YAHC: expect to get connection id" unless $conn_id;
    die "YAHC: expect request to be a hashref" unless defined $request && ref($request) eq 'HASH';

    $request->{_target} = _wrap_target_selection($request->{host}) if $request->{host};
    do { $request->{$_} //= $pool_args->{$_} if $pool_args->{$_} } foreach (qw/host port _target/);
    die "YAHC: host must be defined" unless $request->{host};

    my $self = bless {
        id       => $conn_id,
        request  => $request,
        response => { status_code => 0 },
        attempt  => 0,
        retries  => $request->{connection_retries} // 0,
        selected_target => [],
    }, $class;

    $self->state(YAHC::State::INITIALIZED()); # will register state in timeline
    return $self;
}

sub reinit {
    my ($self, $args) = @_;

    if (defined $args) {
        die "YAHC: expect args to be a hashref" unless ref($args) eq 'HASH';
        my $request = $self->{request};
        do { $request->{$_} = $args->{$_} if $args->{$_} } foreach (keys %$args);
        $request->{_target} = _wrap_target_selection($args->{host}) if $args->{host};
    }

    $self->{attempt} = 0;
    $self->reset;
}

sub reset {
    my $self = shift;
    $self->{selected_target} = [];
    $self->{response} = { status_code => 0 };
    $self->state(YAHC::State::INITIALIZED()); # will register state in timeline
}

sub id        { $_[0]->{id};       }
sub errors    { $_[0]->{errors}    }
sub timeline  { $_[0]->{timeline}  }
sub request   { $_[0]->{request}   }
sub response  { $_[0]->{response}  }

sub state {
    my $self = shift;
    return $self->{state} unless @_;
    return if defined $self->{state} && $self->{state} == $_[0];
    $self->register_in_timeline("new state " . _strstate($_[0]));
    return $self->{state} = $_[0];
}

sub register_in_timeline {
    my ($self, $format, @arguments) = @_;
    my $event = sprintf("$format", @arguments);
    $event =~ s/\s+$//g;
    DEBUG > 1 and TELL "YAHC connection '%s': %s", $self->{id}, $event;
    push @{ $self->{timeline} //= [] }, [ $event, Time::HiRes::time ];
}

sub register_error {
    my ($self, $error, $format, @arguments) = @_;
    my $strerror = sprintf("$format", @arguments);
    $strerror =~ s/\s+$//g;
    $self->register_in_timeline("error=$error ($strerror)");
    push @{ $self->{errors} //= [] }, [ $error, $strerror, Time::HiRes::time ];
}

sub last_error {
    my $self = shift;
    return unless $self->{errors};
    return unless scalar @{ $self->{errors} };
    my $last_error = $self->{errors}->[-1];
    return wantarray ? @$last_error : $last_error->[0];
}

sub assert_state {
    my ($self, $expected_state) = @_;
    return $self->{state} == $expected_state;
    die sprintf("YAHC connection '%s' is in unexpected state %s, expected %s",
                $self->{id}, _strstate($self->{state}), _strstate($expected_state));
}

sub assert_connected {
    my ($self) = @_;
    return if $self->{state} >= YAHC::State::CONNECTED() && $self->{state} < YAHC::State::COMPLETED();
    die sprintf("YAHC connection '%s' expected to be in connected state, but it's in %s",
                $self->{id}, _strstate($self->{state}));
}

sub get_next_target {
    my ($self) = @_;
    # TODO STATE_RESOLVE_DNS
    my ($host, $ip, $port) = $self->{request}{_target}->();
    ($host, $port) = ($1, $2) if $host =~ m/^(.+):([0-9]+)$/;
    $ip = $host if $host =~ m/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/;
    $ip = inet_ntoa(gethostbyname($host) or die "Failed to resolve $host: $!") unless $ip;
    $port //= $self->{request}{port} // 80;
    
    return @{ $self->{selected_target} = [ $host, $ip, $port ] };
}

# copy-paste from Hijk
sub build_http_message {
    my ($self) = @_;
    my $request = $self->{request};
    my $path_and_qs = ($request->{path} // "/") . (defined $request->{query_string} ? ("?" . $request->{query_string}) : "");

    return join(
        $CRLF,
        ($request->{method} // "GET") . " $path_and_qs " . ($request->{protocol} // "HTTP/1.1"),
        "Host: " . $self->{selected_target}[0],
        $request->{body} ? ("Content-Length: " . length($request->{body})) : (),
        $request->{head} ? (
            map {
                $request->{head}[2*$_] . ": " . $request->{head}[2*$_+1]
            } 0..$#{$request->{head}}/2
        ) : (),
        "",
        $request->{body} ? $request->{body} : ()
    ) . $CRLF;
}

sub parse_http_headers {
    my %headers;
    my $proto       = substr($_[1], 0, 8);
    my $status_code = substr($_[1], 9, 3);
    substr($_[1], 0, index($_[1], $CRLF) + 2, ''); # 2 = length($CRLF)

    for (split /${CRLF}/o, $_[1]) {
        my ($key, $value) = split(/: /, $_, 2);
        $headers{$key} = $value;
    }

    $_[0]->{response} = {
        proto       => $proto,
        status_code => $status_code,
        headers     => \%headers,
    };

    return if    !defined $headers{'Content-Length'}
              || exists $headers{'Transfer-Encoding'}
              || exists $headers{'Trailer'};

    return \%headers;
}

sub parse_body {
    $_[0]->{response}{body} = $_[1];
}

sub _wrap_target_selection {
    my $host = shift;
    my $ref = ref($host);
    return sub { $host } if $ref eq '';
    return $host         if $ref eq 'CODE';
    my $idx = 0;
    return sub { $host->[$idx++ % @$host]; } if $ref eq 'ARRAY';
    die "YAHC: unsupported host format";
}

sub _strstate {
    state $states = {
        YAHC::State::INITIALIZED()  => 'STATE_INIT',
        YAHC::State::RESOLVE_DNS()  => 'STATE_RESOLVE_DNS',
        YAHC::State::WAIT_SYNACK()  => 'STATE_WAIT_SYNACK',
        YAHC::State::CONNECTED()    => 'STATE_CONNECTED',
        YAHC::State::WRITING()      => 'STATE_WRITING',
        YAHC::State::READING()      => 'STATE_READING',
        YAHC::State::USER_ACTION()  => 'STATE_USER_ACTION',
        YAHC::State::COMPLETED()    => 'STATE_COMPLETED',
    };

    return $states->{$_[0]} // "<unknown state $_[0]>";
}

1;

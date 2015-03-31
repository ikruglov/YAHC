package YAHC;

use strict;
use warnings;

use EV;
use Time::HiRes;
use Exporter 'import';
use Scalar::Util qw/weaken/;
use Fcntl qw/F_GETFL F_SETFL O_NONBLOCK/;
use POSIX qw/EINPROGRESS EINTR EAGAIN EWOULDBLOCK strftime/;
use Socket qw/PF_INET SOCK_STREAM $CRLF SOL_SOCKET SO_ERROR SO_RCVTIMEO SO_SNDTIMEO inet_aton pack_sockaddr_in/;

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

use constant {
    HTTP_PORT                  => 80,
    TCP_READ_CHUNK             => 65536,
    RUN_UNTIL_ALL_CONNECTED    => 'run until all connected',
    RUN_UNTIL_ALL_SENT_REQUEST => 'run until all sent request',
};

our @EXPORT_OK = qw/
    yahc_reinit_conn
    yahc_conn_last_error
    yahc_conn_id
    yahc_conn_state
    yahc_conn_errors
    yahc_conn_timeline
    yahc_conn_request
    yahc_conn_response
/;

our %EXPORT_TAGS = (all => \@EXPORT_OK);

################################################################################
# User facing functons
################################################################################

sub new {
    my ($class, $args) = @_;

    die 'YAHC: ->new() expect args to be a hashref' if defined $args and ref($args) ne 'HASH';
    die 'YAHC: please do `my ($yahc, $yahc_storage) = YAHC::new()` and keep both these objects in the same scope' unless wantarray;

    # wrapping target selection here allows all client share same list
    # and more importantly to share index within the list
    $args->{_target} = YAHC::Request::_wrap_target_selection($args->{host}) if $args->{host};

    # this's a radical way of avoiding circular references.
    # let's see how it plays out in practise.
    my %storage = (
        watchers    => {},
        callbacks   => {},
        connections => {},
    );

    my $self = bless {
        loop                => new EV::Loop,
        pid                 => $$, # store pid to detect forks
        storage             => \%storage,
        watchers            => $storage{watchers},
        callbacks           => $storage{callbacks},
        connections         => $storage{connections},
        last_connection_id  => $$ * 1000,

        debug               => delete $args->{debug},
        timeline            => delete $args->{timeline},
        pool_args           => $args,
    }, $class;

    weaken($self->{storage});
    weaken($self->{watchers});
    weaken($self->{callbacks});
    weaken($self->{connections});
    return $self, \%storage;
}

sub request {
    my ($self, @args) = @_;
    my ($conn_id, $request);
    die 'YAHC: new_request() expects arguments' unless @args;
    die 'YAHC: storage object is destroyed' unless $self->{storage};

    if (@args == 1) {
        $conn_id = 'connection_' . $self->{last_connection_id}++;
        $request = $args[0];
    } else {
        ($conn_id, $request) = @args;
    }

    die "YAHC: Connection with name '$conn_id' already exists"
        if exists $self->{connections}{$conn_id};

    my $cb = delete $request->{callback};
    my $debug = delete $request->{debug};

    my $conn = {
        id          => $conn_id,
        request     => $request,
        response    => { status_code => 0 },
        attempt     => 0,
        retries     => $request->{connection_retries} || 0,
        state       => YAHC::State::INITIALIZED(),
        debug       => $debug || $self->{debug},
        selected_target => [],
    };

    my $pool_args = $self->{pool_args};
    $request->{_target} = _wrap_target_selection($request->{host}) if $request->{host};
    do { $request->{$_} ||= $pool_args->{$_} if $pool_args->{$_} } foreach (qw/host port/);
    die 'YAHC: host must be defined' unless $request->{host};

    $self->{watchers}{$conn_id} = {};
    $self->{callbacks}{$conn_id} = $cb;
    $self->{connections}{$conn_id} = $conn;

    $self->_set_request_timer($conn_id) if $conn->{request}{request_timeout};
    $self->_set_init_state($conn_id);
    return $conn;
}

sub run      { $_[0]->_run(0, $_[1])       }
sub run_once { $_[0]->_run(EV::RUN_ONCE)   }
sub run_tick { $_[0]->_run(EV::RUN_NOWAIT) }

################################################################################
# Routines to manipulate connections (also user facing)
################################################################################

sub yahc_reinit_conn {
    my ($conn, $args) = @_;
    $conn->{attempt} = 0;
    $conn->{state} = YAHC::State::INITIALIZED();
    return unless defined $args && ref($args) eq 'HASH';

    my $request = $conn->{request};
    do { $request->{$_} = $args->{$_} if $args->{$_} } foreach (keys %$args);
    $request->{_target} = _wrap_target_selection($args->{host}) if $args->{host};
}

sub yahc_conn_last_error {
    my $conn = shift;
    return unless $conn->{errors} && @{ $conn->{errors} };
    return wantarray ? @{ $conn->{errors}[-1] } : $conn->{errors}[-1];
}

sub yahc_conn_id            { $_[0]->{id}       }
sub yahc_conn_state         { $_[0]->{state}    }
sub yahc_conn_errors        { $_[0]->{errors}   }
sub yahc_conn_timeline      { $_[0]->{timeline} }
sub yahc_conn_request       { $_[0]->{request}  }
sub yahc_conn_response      { $_[0]->{response} }

################################################################################
# Internals
################################################################################

sub _run {
    my ($self, $how, $stop_condition) = @_;
    die 'YAHC: storage object is destroyed' unless $self->{storage};

    if ($self->{pid} != $$) {
        _log_message('Reinitializing event loop after forking') if $self->{debug};
        $self->{pid} = $$;
        $self->{loop}->loop_fork;
    }

    if (defined $stop_condition) {
        if ($stop_condition eq RUN_UNTIL_ALL_CONNECTED) {
            $self->{stop_condition} = {
                condition => RUN_UNTIL_ALL_CONNECTED,
                expected_state => YAHC::State::CONNECTED(),
                connections => { map { $_->id => 1 } grep { $_->state < YAHC::State::CONNECTED() } values %{ $self->{connections } } },
            };
        } elsif ($stop_condition eq RUN_UNTIL_ALL_SENT_REQUEST) {
            $self->{stop_condition} = {
                condition => RUN_UNTIL_ALL_SENT_REQUEST,
                expected_state => YAHC::State::READING(),
                connections => { map { $_->id => 1 } grep { $_->state < YAHC::State::WRITING() } values %{ $self->{connections } } },
            };
        } else {
            die "unknown stop_condition";
        }

    } else {
        delete $self->{stop_condition};
    }

    my $loop = $self->{loop};
    $loop->now_update;
    return $loop->run($how || 0) unless $self->{debug}; # shortcut

    my $iterations = $loop->iteration;
    _log_message('pid %d entering event loop%s', $$, $stop_condition ? " and $stop_condition" : '');
    $loop->run($how || 0);
    _log_message('pid %d exited from event loop after %d iterations', $$, $loop->iteration - $iterations);
}

sub _break {
    my ($self, $reason) = @_;
    _log_message('pid %d breaking event loop because %s', $$, ($reason || 'no reason')) if $self->{debug};
    $self->{loop}->break(EV::BREAK_ONE)
}

sub _check_stop_condition {
    my ($self, $conn) = @_;
    my $stop_condition = $self->{stop_condition};
    return if !$stop_condition || $conn->{state} < $stop_condition->{expected_state};

    delete $stop_condition->{connections}{$conn->id};
    my $awaiting_connections = scalar keys %{ $stop_condition->{connections} };

    if ($awaiting_connections == 0) {
        $self->_break(sprintf("stop condition '%s' is met", $stop_condition->{condition}));
    } else {
        _log_message("Still have %d connections awaiting stop condition '%s'",
                     $awaiting_connections, $stop_condition->{condition});
    }
}

################################################################################
# IO routines
################################################################################

sub _set_init_state {
    my ($self, $conn_id) = @_;

    my $conn = $self->{connections}{$conn_id};
    my $watchers = $self->{watchers}{$conn_id};
    die "YAHC: unknown connection id $conn_id" unless $conn && $watchers;

    $conn->{response} = { status_code => 0 };
    $conn->{state} = YAHC::State::INITIALIZED();
    _register_in_timeline($conn, "connection %s new state %s",
                          $conn_id, _strstate($conn->{state})) if $conn->{debug};

    my $continue = 1;
    while ($continue) {
        if (my $w = delete $watchers->{io}) {
            $w->stop;
            shutdown($w->fh, 2);
        }

        my $attempt = $conn->{attempt}++;
        if ($attempt > $conn->{retries}) {
            $self->_set_user_action_state($conn_id, YAHC::Error::CONNECT_ERROR(), "connection_retries limit reached");
            return;
        }

        eval {
            my ($host, $ip, $port) = _get_next_target($conn);
            _register_in_timeline($conn, "Target $host:$port ($ip:$port) chosen for attempt #$attempt") if $conn->{debug};

            my $sock = _build_socket_and_connect($ip, $port, $conn->{request});
            $self->_set_wait_synack_state($conn_id, $sock, $ip, $host, $port);
            $self->_set_connection_timer($conn_id) if $conn->{request}{connect_timeout};
            $continue = 0;
            1;
        } or do {
            my $error = $@ || 'zombie error';
            _register_error($conn, YAHC::Error::CONNECT_ERROR(), "Connection attempt #$attempt for $conn_id has failed: $error");
            #$self->_set_set_init_state_timer($conn_id); # trigger background timer which will do reconnection attempt # TODO
            #$continue = 0;
        };
    }
}

sub _set_wait_synack_state {
    my ($self, $conn_id, $sock, $ip, $host, $port) = @_;

    my $conn = $self->{connections}{$conn_id};
    my $watchers = $self->{watchers}{$conn_id};
    die "YAHC: unknown connection id $conn_id" unless $conn && $watchers;
    _assert_state($conn, YAHC::State::INITIALIZED()) if $conn->{debug};

    $conn->{state} = YAHC::State::WAIT_SYNACK();
    _register_in_timeline($conn, "connection %s new state %s",
                          $conn_id, _strstate($conn->{state})) if $conn->{debug};

    $self->_check_stop_condition($conn) if $self->{stop_condition};

    my $wait_synack_cb = $self->_get_safe_wrapper($conn_id, sub {
        my $sockopt = getsockopt($sock, SOL_SOCKET, SO_ERROR);
        if (!$sockopt) {
            _register_error($conn, YAHC::Error::CONNECT_ERROR(), "Failed to do getsockopt(): $!");
            $self->_set_init_state($conn_id);
            return;
        }

        if (my $err = unpack("L", $sockopt)) {
            my $strerror = POSIX::strerror($err) || '<unknown POSIX error>';
            _register_error($conn, YAHC::Error::CONNECT_ERROR(), "Failed to connect to $host:$port ($ip:$port): $strerror");
            $self->_set_init_state($conn_id);
            return;
        }

        $conn->{state} = YAHC::State::CONNECTED();
        _register_in_timeline($conn, "connection %s new state %s",
                              $conn_id, _strstate($conn->{state})) if $conn->{debug};

        $self->_set_write_state($conn_id);
    });

    $watchers->{io} = $self->{loop}->io($sock, EV::WRITE, $wait_synack_cb);
}

sub _set_write_state {
    my ($self, $conn_id) = @_;

    my $conn = $self->{connections}{$conn_id};
    my $watcher = $self->{watchers}{$conn_id}{io};
    die "YAHC: unknown connection id $conn_id" unless $conn && $watcher;
    _assert_connected($conn) if $conn->{debug};

    $conn->{state} = YAHC::State::WRITING();
    _register_in_timeline($conn, "connection %s new state %s",
                          $conn_id, _strstate($conn->{state})) if $conn->{debug};

    $self->_check_stop_condition($conn) if $self->{stop_condition};

    my $fd = fileno($watcher->fh);
    my $buf = _build_http_message($conn);
    my $length = length($buf);

    _register_in_timeline($conn, "sending request of $length bytes") if $conn->{debug};

    my $write_cb = $self->_get_safe_wrapper($conn_id, sub {
        my $wlen = POSIX::write($fd, $buf, $length);

        if (!$wlen) {
            return if $! == EWOULDBLOCK || $! == EAGAIN || $! == EINTR;

            my $error = !defined $wlen
                      ? "Failed to send TCP data: $!"
                      : "Bizzare!!! syswrite returned 0"; # wlen == 0

            _register_error($conn, YAHC::Error::WRITE_ERROR(), $error);
            $self->_set_init_state($conn_id);
        } else {
            substr($buf, 0, $wlen, '');
            $length -= $wlen;
            $self->_set_read_state($conn_id) if $length == 0;
        }
    });

    $watcher->cb($write_cb);
    $watcher->events(EV::WRITE);
}

sub _set_read_state {
    my ($self, $conn_id) = @_;

    my $conn = $self->{connections}{$conn_id};
    my $watcher = $self->{watchers}{$conn_id}{io};
    die "YAHC: unknown connection id $conn_id" unless $conn && $watcher;
    _assert_connected($conn) if $conn->{debug};

    $conn->{state} = YAHC::State::READING();
    _register_in_timeline($conn, "connection %s new state %s",
                          $conn_id, _strstate($conn->{state})) if $conn->{debug};

    $self->_check_stop_condition($conn) if $self->{stop_condition};

    my $buf = '';
    my $neck_pos = 0;
    my $decapitated = 0;
    my $content_length = 0;
    my $fd = fileno($watcher->fh);

    my $read_cb = $self->_get_safe_wrapper($conn_id, sub {
        my $rlen = POSIX::read($fd, my $b = '', TCP_READ_CHUNK);

        if (!$rlen) {
            return if $! == EWOULDBLOCK || $! == EAGAIN || $! == EINTR;
            if (not defined $rlen) {
                _register_error($conn, YAHC::Error::READ_ERROR(), "Failed to receive TCP data: $!");
            } elsif ($content_length > 0) { # i.e. rlen == 0 and $content_length > 0
                register_error($conn, YAHC::Error::READ_ERROR(), "Premature EOF, expect %d bytes more", $content_length - length($buf));
            } else { # i.e. rlen == 0
                register_error($conn, YAHC::Error::READ_ERROR(), "Premature EOF");
            }

            $self->_set_init_state($conn_id);
        } else {
            $buf .= $b;
            if (!$decapitated && ($neck_pos = index($buf, "${CRLF}${CRLF}")) > 0) {
                my $headers = _parse_http_headers($conn, substr($buf, 0, $neck_pos, ''));
                if (not defined $headers) {
                    $self->_set_user_action_state($conn_id, YAHC::Error::RESPONSE_ERROR(), "unsuported HTTP reponse");
                    return;
                }

                $decapitated = 1;
                $content_length = $headers->{'Content-Length'};
                substr($buf, 0, 4, ''); # 4 = length("$CRLF$CRLF")
                _register_in_timeline($conn, "headers parsed: content-length='%d' content-type='%s'",
                                      $content_length, $headers->{'Content-Type'} || '<no-content-type>') if $conn->{debug};
            }

            if ($decapitated && length($buf) >= $content_length) {
                $buf = substr($buf, 0, $content_length) if length($buf) > $content_length;
                $conn->{response}{body} = $buf;
                $self->_set_user_action_state($conn_id);
            }
        }
    });

    $watcher->cb($read_cb);
    $watcher->events(EV::READ);
}

sub _set_user_action_state {
    my ($self, $conn_id, $error, $strerror) = @_;
    $error ||= YAHC::Error::NO_ERROR();
    $strerror ||= '<no strerror>';

    # this state may be used in critical places,
    # so it should *NEVER* throw exception
    my $conn = $self->{connections}{$conn_id}
      or warn "YAHC: try to _set_user_action_state() for unknown connection $conn_id",
        return;

    $conn->{state} = YAHC::State::USER_ACTION();
    _register_in_timeline($conn, "connection %s new state %s",
                          $conn_id, _strstate($conn->{state})) if $conn->{debug};
    _register_error($conn, $error, $strerror) if $error;

    my $cb = $self->{callbacks}{$conn_id};
    return $self->_set_completed_state($conn_id) unless $cb; # shortcut

    eval {
        _register_in_timeline($conn, "call callback%s", $error ? " error=$error, strerror='$strerror'" : '') if $conn->{debug};
        $cb->($conn, $error, $strerror);
        1;
    } or do {
        my $error = $@ || 'zombie error';
        _register_error($conn, YAHC::Error::CALLBACK_ERROR(), $error);
        warn "YAHC: exception in callback: $error";
    };

    if ($error == YAHC::Error::INTERNAL_ERROR()) {
        _register_in_timeline($conn, "unrecoverable error appeared, forcing completion") if $conn->{debug};
        $self->_set_completed_state($conn_id);
        return;
    }

    my $state = $conn->{state};
    _register_in_timeline($conn, "after invoking callback state is %s", _strstate($state)) if $conn->{debug};

    if ($state == YAHC::State::INITIALIZED()) {
        $self->_set_init_state($conn_id); # TODO eval
    } elsif ($state == YAHC::State::USER_ACTION() || $state == YAHC::State::COMPLETED()) {
        $self->_set_completed_state($conn_id);
    } else {
        _register_error($conn, YAHC::Error::CALLBACK_ERROR(), "callback set unsupported state");
        $self->_set_completed_state($conn_id);
    }
}

sub _set_completed_state {
    my ($self, $conn_id) = @_;

    # this's a terminal state,
    # so setting this state should *NEVER* fail
    delete $self->{callbacks}{$conn_id};
    my $watchers = delete $self->{watchers}{$conn_id};
    my $conn = $self->{connections}{$conn_id}
      or warn "YAHC: try to _set_completed_state() for unknown connection $conn_id",
        return;

    $conn->{state} = YAHC::State::COMPLETED();
    _register_in_timeline($conn, "connection %s new state %s",
                          $conn_id, _strstate($conn->{state})) if $conn->{debug};

    if (my $w = delete $watchers->{io}) {
        $w->stop;
        shutdown($w->fh, 2)
    }

    $_->stop foreach (values %{ $watchers || {} });

    eval { $self->_check_stop_condition($conn) } if $self->{stop_condition};
}

sub _build_socket_and_connect {
    my ($ip, $port, $timeouts) = @_;

    my $sock;
    socket($sock, PF_INET, SOCK_STREAM, 0) or die "YAHC: Failed to construct TCP socket: $!";

    my $flags = fcntl($sock, F_GETFL, 0) or die "YAHC: Failed to get fcntl F_GETFL flag: $!";
    fcntl($sock, F_SETFL, $flags | O_NONBLOCK) or die "YAHC: Failed to set fcntl O_NONBLOCK flag: $!";

    if (my $read_timeout = $timeouts->{read_timeout}) {
        my $read_struct  = pack('l!l!', $read_timeout, 0);
        # setsockopt(SOL_SOCKET, SO_RCVTIMEO, $read_struct)
          # or die "YAHC: Failed to set setsockopt(SO_RCVTIMEO): $!";
    }

    if (my $write_timeout = $timeouts->{write_timeout}) {
        my $write_struct = pack('l!l!', $write_timeout, 0);
        # setsockopt( SOL_SOCKET, SO_SNDTIMEO, $write_struct )
          # or die "YAHC: Failed to set setsockopt(SO_SNDTIMEO): $!";
    }

    my $ip_addr = inet_aton($ip);
    my $addr = pack_sockaddr_in($port, $ip_addr);
    if (!connect($sock, $addr) && $! != EINPROGRESS) {
        die "YAHC: Failed to connect to $ip: $!";
    }

    return $sock;
}

sub _get_next_target {
    my $conn = shift;
    my ($host, $ip, $port) = $conn->{request}{_target}->();

    # TODO STATE_RESOLVE_DNS
    ($host, $port) = ($1, $2) if $host =~ m/^(.+):([0-9]+)$/o;
    $ip = $host if $host =~ m/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/o;
    $ip = inet_ntoa(gethostbyname($host) or die "Failed to resolve $host: $!") unless $ip;
    $port ||= $conn->{request}{port} || HTTP_PORT;

    return @{ $conn->{selected_target} = [ $host, $ip, $port ] };
}

################################################################################
# Timers
################################################################################

sub _set_request_timer {
    my ($self, $conn_id) = @_;

    my $conn = $self->{connections}{$conn_id};
    my $watchers = $self->{watchers}{$conn_id};
    die "YAHC: unknown connection id $conn_id" unless $conn && $watchers;

    if (my $timer = delete $watchers->{connection_timer}) {
        $timer->stop;
    }

    my $timeout = $conn->{request}{request_timeout};
    return unless defined $timeout;

    my $request_timer_cb = $self->_get_safe_wrapper($conn_id, sub {
        if ($conn->{state} < YAHC::State::USER_ACTION()) {
            my $error = sprintf("Request timeout of %.3fs has reached", $timeout);
            $self->_set_user_action_state($conn_id, YAHC::Error::REQUEST_TIMEOUT(), $error);
        } else {
            _register_in_timeline($conn, "delete request timer") if $conn->{debug};
        }
    });

    _register_in_timeline($conn, "setting request timeout to %.3fs", $timeout) if $conn->{debug};
    $watchers->{request_timer} = $self->{loop}->timer($timeout, 0, $request_timer_cb);
    $watchers->{request_timer}->priority(2); # set max priority
}

sub _set_connection_timer {
    my ($self, $conn_id) = @_;

    my $conn = $self->{connections}{$conn_id};
    my $watchers = $self->{watchers}{$conn_id};
    die "YAHC: unknown connection id $conn_id" unless $conn && $watchers;

    if (my $timer = delete $watchers->{connection_timer}) {
        $timer->stop;
    }

    my $timeout = $conn->{request}{connect_timeout};
    return unless $timeout;

    my $connection_timer_cb = $self->_get_safe_wrapper($conn_id, sub {
        if ($conn->{state} < YAHC::State::CONNECTED()) {
            _register_in_timeline($conn, "connection timeout of %.3fs has reached", $timeout) if $conn->{debug};
            $self->_set_init_state($conn_id);
        } else {
            _register_in_timeline($conn, "delete connection timer") if $conn->{debug};
        }
    });

    _register_in_timeline($conn, "setting connection timeout to %.3fs", $timeout) if $conn->{debug};
    $watchers->{connection_timer} = $self->{loop}->timer($timeout, 0, $connection_timer_cb);
    $watchers->{connection_timer}->priority(-2); # set lowest priority
}

################################################################################
# HTTP functions
################################################################################

# copy-paste from Hijk
sub _build_http_message {
    my $conn = shift;
    my $request = $conn->{request};
    my $path_and_qs = ($request->{path} || "/") . (defined $request->{query_string} ? ("?" . $request->{query_string}) : "");

    return join(
        $CRLF,
        ($request->{method} || "GET") . " $path_and_qs " . ($request->{protocol} || "HTTP/1.1"),
        "Host: " . $conn->{selected_target}[0],
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

sub _parse_http_headers {
    my $conn = shift;
    my $proto       = substr($_[0], 0, 8);
    my $status_code = substr($_[0], 9, 3);
    substr($_[0], 0, index($_[0], $CRLF) + 2, ''); # 2 = length($CRLF)

    my %headers;
    for (split /${CRLF}/o, $_[0]) {
        my ($key, $value) = split(/: /, $_, 2);
        $headers{$key} = $value;
    }

    $conn->{response} = {
        proto       => $proto,
        status_code => $status_code,
        headers     => \%headers,
    };

    return \%headers;
}

################################################################################
# Helpers
################################################################################

sub _wrap_target_selection {
    my $host = shift;
    my $ref = ref($host);

    return sub { $host } if $ref eq '';
    return $host         if $ref eq 'CODE';

    my $idx = 0;
    return sub { $host->[$idx++ % @$host]; } if $ref eq 'ARRAY';
    die "YAHC: unsupported host format";
}

sub _get_safe_wrapper {
    my ($self, $conn_id, $sub) = @_;
    return sub { eval {
        $sub->(@_);
        1;
    } or do {
        my $error = $@ || 'zombie error';
        $self->_set_user_action_state($conn_id, YAHC::Error::INTERNAL_ERROR(), "Exception callback: $error");
    }};
}

sub _register_in_timeline {
    my ($conn, $format, @arguments) = @_;
    my $event = sprintf("$format", @arguments);
    $event =~ s/\s+$//g;
    _log_message("YAHC connection '%s': %s", $conn->{id}, $event) if $conn->{debug};
    push @{ $conn->{timeline} ||= [] }, [ $event, Time::HiRes::time ];
}

sub _register_error {
    my ($conn, $error, $format, @arguments) = @_;
    my $strerror = sprintf("$format", @arguments);
    $strerror =~ s/\s+$//g;
    _register_in_timeline($conn, "error=$error ($strerror)") if $conn->{debug};
    push @{ $conn->{errors} ||= [] }, [ $error, $strerror, Time::HiRes::time ];
}

sub _assert_state {
    my ($conn, $expected_state) = @_;
    return $conn->{state} == $expected_state;
    die sprintf("YAHC connection '%s' is in unexpected state %s, expected %s",
                $conn->{id}, _strstate($conn->{state}), _strstate($expected_state));
}

sub _assert_connected {
    my $conn = shift;
    return if $conn->{state} >= YAHC::State::CONNECTED() && $conn->{state} < YAHC::State::COMPLETED();
    die sprintf("YAHC connection '%s' expected to be in connected state, but it's in %s",
                $conn->{id}, _strstate($conn->{state}));
}

sub _strstate {
    my $state = shift;
    return 'STATE_INIT'         if $state eq YAHC::State::INITIALIZED();
    return 'STATE_RESOLVE_DNS'  if $state eq YAHC::State::RESOLVE_DNS();
    return 'STATE_WAIT_SYNACK'  if $state eq YAHC::State::WAIT_SYNACK();
    return 'STATE_CONNECTED'    if $state eq YAHC::State::CONNECTED();
    return 'STATE_WRITING'      if $state eq YAHC::State::WRITING();
    return 'STATE_READING'      if $state eq YAHC::State::READING();
    return 'STATE_USER_ACTION'  if $state eq YAHC::State::USER_ACTION();
    return 'STATE_COMPLETED'    if $state eq YAHC::State::COMPLETED();
    return "<unknown state $state>";
}

sub _log_message {
    my $format = shift;
    printf STDERR "[%s] [$$] $format\n", POSIX::strftime('%F %T', localtime), @_;
}

1;

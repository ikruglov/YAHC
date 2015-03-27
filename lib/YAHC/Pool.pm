package YAHC::Pool;

use 5.14.2;
use strict;
use warnings;

use EV;
use DEBUG;
use Scalar::Util qw/weaken blessed/;
use Fcntl qw/F_GETFL F_SETFL O_NONBLOCK/;
use POSIX qw/EINPROGRESS EINTR EAGAIN EWOULDBLOCK/;
use Socket qw/PF_INET SOCK_STREAM $CRLF SOL_SOCKET SO_ERROR SO_RCVTIMEO SO_SNDTIMEO inet_aton pack_sockaddr_in/;
use YAHC::Request;

use constant {
    HTTP_PORT           => 80,
    TCP_READ_CHUNK      => 65536,
    RUN_UNTIL_ALL_CONNECTED    => 'run until all connected',
    RUN_UNTIL_ALL_SENT_REQUEST => 'run until all sent request',
};

sub new {
    my ($class, $args) = @_;
    die "YAHC: ->new() expect args to be a hashref" if defined $args and ref($args) ne 'HASH';

    # wrapping target selection here allows all client share same list
    # and more importantly to share index within the list
    $args->{_target} = YAHC::Request::_wrap_target_selection($args->{host}) if $args->{host};

    return bless {
        loop               => new EV::Loop,
        pid                => $$, # store pid to detect forks
        watchers           => {}, # store watchers in parent object to avoid cyclic references
        callbacks          => {}, # store callbacks in parent object to avoid cyclic references
        connections        => {},
        last_connection_id => $$ * 1000,
        pool_args          => $args,
    }, $class;
}

sub request {
    my ($self, @args) = @_;
    my ($conn_id, $request);
    die "YAHC: new_request() expects arguments" unless @args;

    if (@args == 1) {
        $conn_id = sprintf('connection_%d', $_[0]->{last_connection_id}++);
        $request = $args[0];
    } else {
        ($conn_id, $request) = @args;
    }

    die "YAHC: Connection with name '$conn_id' already exists"
        if exists $self->{connections}{$conn_id};

    $self->{watchers}{$conn_id} = {};
    $self->{callbacks}{$conn_id} = delete $request->{callback};
    my $conn = $self->{connections}{$conn_id} = YAHC::Request->new($conn_id, $request, $self->{pool_args});

    $self->_set_request_timer($conn_id);
    $self->_reconnect($conn_id);
    return $conn;
}

sub run      { $_[0]->_run(0, $_[1])       }
sub run_once { $_[0]->_run(EV::RUN_ONCE)   }
sub run_tick { $_[0]->_run(EV::RUN_NOWAIT) }

sub _run {
    my ($self, $how, $stop_condition) = @_;
    my $loop = $self->{loop};

    if ($self->{pid} != $$) {
        DEBUG > 1 and TELL "Reinitializing event loop after forking";
        $self->{pid} = $$;
        $loop->loop_fork;
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

    my $iterations = $loop->iteration;
    DEBUG > 1 and TELL "pid $$ entering event loop" . ($stop_condition ? " and $stop_condition" : '');
    $loop->now_update;
    $loop->run($how // 0);
    DEBUG > 1 and TELL "pid $$ exited from event loop after %d iterations", $loop->iteration - $iterations;
}

sub _break {
    my ($self, $reason) = @_;
    DEBUG > 1 and TELL "$$ breaking event loop because %s", ($reason // 'no reason');
    $self->{loop}->break(EV::BREAK_ONE)
}

sub _reconnect {
    my ($self, $conn_id) = @_;

    my $conn = $self->{connections}{$conn_id};
    my $watchers = $self->{watchers}{$conn_id};
    die "YAHC: unknown connection id $conn_id" unless $conn && $watchers;

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
            $conn->reset;
            my ($host, $ip, $port) = $conn->get_next_target();
            $conn->register_in_timeline("Target $host:$port ($ip:$port) chosen for attempt #$attempt");

            my $sock = $self->_build_socket_and_connect($ip, $port, $conn->{request});
            $self->_set_wait_synack_state($conn_id, $sock, $ip, $host, $port);
            $self->_set_connection_timer($conn_id);
            $continue = 0;
            1;
        } or do {
            my $error = $@ || 'zombie error';
            $conn->register_error(YAHC::Error::CONNECT_ERROR(), "Connection attempt #$attempt for $conn_id has failed: $error");
            #$self->_set_reconnect_timer($conn_id); # trigger background timer which will do reconnection attempt # TODO
            #$continue = 0;
        };
    }
}

sub _set_wait_synack_state {
    my ($self, $conn_id, $sock, $ip, $host, $port) = @_;
    my $weak_self = $self; weaken($weak_self);

    my $conn = $self->{connections}{$conn_id};
    my $watchers = $self->{watchers}{$conn_id};
    die "YAHC: unknown connection id $conn_id" unless $conn && $watchers;

    $conn->assert_state(YAHC::State::INITIALIZED());
    $conn->state(YAHC::State::WAIT_SYNACK());

    my $wait_synack_cb = $self->_get_safe_wrapper($conn_id, sub {
        my $sockopt = getsockopt($_[0]->fh, SOL_SOCKET, SO_ERROR);
        if (!$sockopt) {
            $conn->register_error(YAHC::Error::CONNECT_ERROR(), "Failed to do getsockopt(): $!");
            $weak_self->_reconnect($conn_id);
            return;
        }

        if (my $err = unpack("L", $sockopt)) {
            my $strerror = POSIX::strerror($err) // '<unknown POSIX error>';
            $conn->register_error(YAHC::Error::CONNECT_ERROR(), "Failed to connect to $host:$port ($ip:$port): $strerror");
            $weak_self->_reconnect($conn_id);
            return;
        }

        $conn->state(YAHC::State::CONNECTED());
        $weak_self->_set_write_state($conn_id);
        $weak_self->_check_stop_condition($conn);
    });

    $watchers->{io} = $self->{loop}->io($sock, EV::WRITE, $wait_synack_cb);
}

sub _set_write_state {
    my ($self, $conn_id) = @_;
    my $weak_self = $self; weaken($weak_self);

    my $conn = $self->{connections}{$conn_id};
    my $watchers = $self->{watchers}{$conn_id};
    die "YAHC: unknown connection id $conn_id" unless $conn && $watchers;

    $conn->assert_connected();
    $conn->state(YAHC::State::WRITING());

    my $offset = 0;
    my $buf = $conn->build_http_message;
    my $length = length($buf);

    $conn->register_in_timeline("sending request of $length bytes");

    my $write_cb = $self->_get_safe_wrapper($conn_id, sub {
        my $wlen = syswrite($_[0]->fh, $buf, $length - $offset, $offset);

        if (!$wlen) {
            return if $! == EWOULDBLOCK || $! == EAGAIN || $! == EINTR;

            my $error = !defined $wlen
                      ? "Failed to send TCP data: $!"
                      : "Bizzare!!! syswrite returned 0"; # wlen == 0

            $conn->register_error(YAHC::Error::WRITE_ERROR(), $error);
            $weak_self->_reconnect($conn_id);
        } else {
            $offset += $wlen;
            if ($offset == $length) {
                $weak_self->_set_read_state($conn_id);
                $weak_self->_check_stop_condition($conn);
            }
        }
    });

    $watchers->{io}->cb($write_cb);
    $watchers->{io}->events(EV::WRITE);
}

sub _set_read_state {
    my ($self, $conn_id) = @_;
    my $weak_self = $self; weaken($weak_self);

    my $conn = $self->{connections}{$conn_id};
    my $watchers = $self->{watchers}{$conn_id};
    die "YAHC: unknown connection id $conn_id" unless $conn && $watchers;

    $conn->assert_connected();
    $conn->state(YAHC::State::READING());

    my $buf = '';
    my $neck_pos = 0;
    my $decapitated = 0;
    my $content_length = 0;

    my $read_cb = $self->_get_safe_wrapper($conn_id, sub {
        my $rlen = sysread($_[0]->fh, $buf, TCP_READ_CHUNK, length($buf));

        if (!$rlen) {
            return if $! == EWOULDBLOCK || $! == EAGAIN || $! == EINTR;
            if (not defined $rlen) {
                $conn->register_error(YAHC::Error::READ_ERROR(), "Failed to receive TCP data: $!");
            } elsif ($content_length > 0) { # i.e. rlen == 0 and $content_length > 0
                $conn->register_error(YAHC::Error::READ_ERROR(), "Premature EOF, expect %d bytes more", $content_length - length($buf));
            } else { # i.e. rlen == 0
                $conn->register_error(YAHC::Error::READ_ERROR(), "Premature EOF");
            }

            $weak_self->_reconnect($conn_id);
        } else {
            if (!$decapitated && ($neck_pos = index($buf, "${CRLF}${CRLF}")) > 0) {
                my $headers = $conn->parse_http_headers(substr($buf, 0, $neck_pos, ''));
                if (not defined $headers) {
                    $weak_self->_set_user_action_state($conn_id, YAHC::Error::RESPONSE_ERROR(), "unsuported HTTP reponse");
                    return;
                }

                $decapitated = 1;
                $content_length = $headers->{'Content-Length'};
                substr($buf, 0, 4, ''); # 4 = length("$CRLF$CRLF")
                $conn->register_in_timeline("headers parsed: content-length='%d' content-type='%s'",
                                            $content_length, $headers->{'Content-Type'} // '<no-content-type>');
            }

            if ($decapitated && length($buf) >= $content_length) {
                $buf = substr($buf, 0, $content_length) if length($buf) > $content_length;
                my $response = $conn->parse_body($buf);
                $weak_self->_set_user_action_state($conn_id);
            }
        }
    });

    $watchers->{io}->cb($read_cb);
    $watchers->{io}->events(EV::READ);
}

sub _set_user_action_state {
    my ($self, $conn_id, $error, $strerror) = @_;
    $error //= YAHC::Error::NO_ERROR();
    $strerror //= '<no strerror>';

    # this state may be used in critical places,
    # so it should *NEVER* throw exception
    my $conn = $self->{connections}{$conn_id}
      or warn "YAHC: try to _set_user_action_state() for unknown connection $conn_id",
        return;

    $conn->state(YAHC::State::USER_ACTION());
    $conn->register_error($error, $strerror) if $error;

    if (my $cb = $self->{callbacks}{$conn_id}) {
        eval {
            $conn->register_in_timeline("call callback" . ($error ? " error=$error, strerror='$strerror'" : ''));
            $cb->($conn, $error, $strerror);
            1;
        } or do {
            my $error = $@ || 'zombie error';
            $conn->register_error(YAHC::Error::CALLBACK_ERROR(), $error);
            warn "YAHC: exception in callback: $error";
        };
    }

    if ($error == YAHC::Error::INTERNAL_ERROR()) {
        $conn->register_in_timeline("unrecoverable error appeared, forcing completion");
        $self->_set_completed_state($conn_id);
        return;
    }

    my $state = $conn->state;
    $conn->register_in_timeline("after invoking callback state is %s", YAHC::Request::_strstate($state));

    if ($state == YAHC::State::INITIALIZED()) {
        $self->_reconnect($conn_id); # TODO eval
    } elsif ($conn->state == YAHC::State::USER_ACTION() || $state == YAHC::State::COMPLETED()) {
        $self->_set_completed_state($conn_id);
    } else {
        $conn->register_error(YAHC::Error::CALLBACK_ERROR(), "callback set unsupported state");
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

    $conn->state(YAHC::State::COMPLETED());
    foreach my $w (values %{ $watchers // {} }) {
        $w->stop;
        shutdown($w->fh, 2) if blessed($w) && $w->isa('EV::IO');
    }

    eval { $self->_check_stop_condition($conn) } if $self->{stop_condition};
}

sub _build_socket_and_connect {
    my ($self, $ip, $port, $timeouts) = @_;

    my $sock;
    socket($sock, PF_INET, SOCK_STREAM, 0) or die "YAHC: Failed to construct TCP socket: $!";

    my $flags = fcntl($sock, F_GETFL, 0) or die "YAHC: Failed to get fcntl F_GETFL flag: $!";
    fcntl($sock, F_SETFL, $flags | O_NONBLOCK) or die "YAHC: Failed to set fcntl O_NONBLOCK flag: $!";

    if (my $read_timeout = $timeouts->{read_timeout}) {
        my $read_struct  = pack('l!l!', $read_timeout, 0);
        $self->setsockopt(SOL_SOCKET, SO_RCVTIMEO, $read_struct)
          or die "YAHC: Failed to set setsockopt(SO_RCVTIMEO): $!";
    }

    if (my $write_timeout = $timeouts->{write_timeout}) {
        my $write_struct = pack('l!l!', $write_timeout, 0);
        $self->setsockopt( SOL_SOCKET, SO_SNDTIMEO, $write_struct )
          or die "YAHC: Failed to set setsockopt(SO_SNDTIMEO): $!";
    }

    my $ip_addr = inet_aton($ip);
    my $addr = pack_sockaddr_in($port, $ip_addr);
    if (!connect($sock, $addr) && $! != EINPROGRESS) {
        die "YAHC: Failed to connect to $ip: $!";
    }

    return $sock;
}

sub _set_request_timer {
    my ($self, $conn_id) = @_;
    my $weak_self = $self; weaken($weak_self);

    my $conn = $self->{connections}{$conn_id};
    my $watchers = $self->{watchers}{$conn_id};
    die "YAHC: unknown connection id $conn_id" unless $conn && $watchers;

    my $timeout = $conn->{request}{request_timeout};
    return unless defined $timeout;

    my $request_timer_cb = $self->_get_safe_wrapper($conn_id, sub {
        if ($conn->state < YAHC::State::COMPLETED()) {
            my $error = sprintf("Request timeout of %.3fs has reached", $timeout);
            $weak_self->_set_user_action_state($conn_id, YAHC::Error::REQUEST_TIMEOUT(), $error);
        } else {
            $conn->register_in_timeline("delete request timer");
        }
    });

    $conn->register_in_timeline(sprintf("setting request timeout to %.3fs", $timeout));
    $watchers->{request_timer} = $self->{loop}->timer($timeout, 0, $request_timer_cb);
    $watchers->{request_timer}->priority(2); # set max priority
}

sub _set_connection_timer {
    my ($self, $conn_id) = @_;
    my $weak_self = $self; weaken($weak_self);

    my $conn = $self->{connections}{$conn_id};
    my $watchers = $self->{watchers}{$conn_id};
    die "YAHC: unknown connection id $conn_id" unless $conn && $watchers;

    if (my $connection_timer = delete $watchers->{connection_timer}) {
        $connection_timer->stop;
    }

    my $timeout = $conn->{request}{connect_timeout};
    return unless $timeout;

    my $connection_timer_cb = $self->_get_safe_wrapper($conn_id, sub {
        if ($conn->state < YAHC::State::CONNECTED()) {
            $conn->register_in_timeline("connection timeout of %.3fs has reached", $timeout);
            $weak_self->_reconnect($conn_id);
        } else {
            $conn->register_in_timeline("delete connection timer");
        }
    });

    $conn->register_in_timeline("setting connection timeout to %.3fs", $timeout);
    $watchers->{connection_timer} = $self->{loop}->timer($timeout, 0, $connection_timer_cb);
    $watchers->{connection_timer}->priority(-2); # set lowest priority
}

sub _set_reconnect_timer {
    my ($self, $conn_id) = @_;

    my $conn = $self->{connections}{$conn_id};
    my $watchers = $self->{watchers}{$conn_id};
    die "YAHC: unknown connection id $conn_id" unless $conn && $watchers;

    if (my $timer = $watchers->{reconnection_timer}) {
        $timer->again;
        return;
    }

    my $delay = $conn->{request}{reconnect_timeout};
    return unless $delay;

    my $weak_self = $self; weaken($weak_self);
    my $reconnection_timer_cb = $self->_get_safe_wrapper($conn_id, sub {
        $weak_self->_reconnect($conn_id) if $conn->state < YAHC::State::CONNECTED();
    });

    $conn->register_in_timeline(sprintf("setting reconnection delay to %.3fs", $delay));
    $watchers->{reconnection_timer} = $self->{loop}->timer($delay, $delay, $reconnection_timer_cb);
}

sub _check_stop_condition {
    my ($self, $conn) = @_;
    my $stop_condition = $self->{stop_condition};
    return if !$stop_condition || $conn->state < $stop_condition->{expected_state};

    delete $stop_condition->{connections}{$conn->id};
    my $awaiting_connections = scalar keys %{ $stop_condition->{connections} };

    if ($awaiting_connections == 0) {
        $self->_break(sprintf("stop condition '%s' is met", $stop_condition->{condition}));
    } else {
        DEBUG > 1 and TELL "Still have %d connections awaiting stop condition '%s'",
                            $awaiting_connections, $stop_condition->{condition};
    }
}

sub _get_safe_wrapper {
    my ($weak_self, $conn_id, $sub) = @_;
    weaken($weak_self);
    return sub { eval {
        $sub->(@_);
        1;
    } or do {
        my $error = $@ || 'zombie error';
        $weak_self->_set_user_action_state($conn_id, YAHC::Error::INTERNAL_ERROR(), "Exception callback: $error");
    }};
}

1;

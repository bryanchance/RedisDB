package RedisDB;

use warnings;
use strict;
our $VERSION = 0.07;

use IO::Socket::INET;
use Socket qw(MSG_DONTWAIT);
use POSIX qw(:errno_h);
use Carp;

=head1 NAME

RedisDB - Perl extension to access redis database

=head1 SYNOPSIS

    use RedisDB;

    my $redis = RedisDB->new(host => 'localhost', port => 6379);
    $redis->set($key, $value);
    my $value = $redis->get($key);

=head1 DESCRIPTION

B<This is alfa version, use on your own risk, interface is subject to change>

This module provides interface to access redis database. It transparently
handles disconnects and forks. It supports pipelining mode.

=head1 METHODS

=head2 $class->new(%options)

Creates new RedisDB object. The following options are allowed:

=over 4

=item host

domain name of the host running redis server. Default: "localhost"

=item port

port to connect. Default: 6379

=item lazy

by default I<new> establishes connection to the server. If this parameter is
set, then connection will be established when you will send command to the
server.

=back

=cut

sub new {
    my $class = shift;
    my $self = ref $_[0] ? $_[0] : {@_};
    bless $self, $class;
    $self->{port} ||= 6379;
    $self->{host} ||= 'localhost';
    $self->{_replies} = [];
    $self->_connect unless $self->{lazy};
    return $self;
}

=head2 $self->execute($command, @arguments)

send command to the server and return server reply. It throws exception if
server returns error. It may be more convenient to use instead of this method
wrapper named after the redis command. E.g.:

    $redis->execute('set', key => 'value');
    # is the same as
    $redis->set(key => 'value');

See "SUPPORTED REDIS COMMANDS" section for the full list of defined aliases.

Note, that you can't use I<execute> if you have sent some commands in pipelining
mode and haven't yet got all replies.

=cut

sub execute {
    my $self = shift;
    croak "You can't use RedisDB::execute while in pipelining mode."
      if $self->{_commands_in_flight}
          or @{ $self->{_replies} };
    croak "This function is not available in subscription mode." if $self->{_subscription_loop};
    my $cmd = uc shift;
    $self->send_command($cmd, @_);
    return $self->get_reply;
}

# establish connection to the server.

sub _connect {
    my $self = shift;
    $self->{_pid}    = $$;
    $self->{_socket} = IO::Socket::INET->new(
        PeerAddr => $self->{host},
        PeerPort => $self->{port},
        Proto    => 'tcp'
    ) or die "Can't connect to redis server $self->{host}:$self->{port}: $!";
    $self->{_commands_in_flight} = 0;
    $self->{_subscription_loop}  = 0;
    return 1;
}

# parse data from the receive buffer without blocking
sub _recv_data_nb {
    my $self = shift;

    while (1) {
        my $ret = $self->{_socket}->recv( my $buf, 4096, MSG_DONTWAIT );
        unless ( defined $ret ) {

            # socket is connected, no data in recv buffer
            last if $! == EAGAIN or $! == EWOULDBLOCK;
            next if $! == EINTR;

            # die on any other error
            die "Error reading from server: $!";
        }
        elsif ( $buf ne '' ) {

            # received some data
            $self->{_buffer} .= $buf;
        }
        else {

            # server closed connection. Check if some data was lost.
            1 while $self->{_buffer} and $self->_parse_reply;

            # if there's some replies lost
            die "Server closed connection. Some data was lost."
              if $self->{_commands_in_flight} or $self->{_in_multi};

            # clean disconnect, try to reconnect
            $self->{warnings} and warn "Disconnected, trying to reconnect";
            $self->_connect;
            last;
        }
    }

    return;
}

=head2 $self->send_command($command, @arguments)

send command to the server. Returns true if command was successfully sent, or
dies if error occured. Note, that it doesn't return server reply, you should
retrieve reply using I<get_reply> method.

=cut

sub send_command {
    my $self = shift;
    if ( $self->{_subscription_loop} ) {
        croak "only (UN)(P)SUBSCRIBE and QUITE allowed in subscription loop"
          unless $_[0] =~ /^(p?(un)?subscribe|quit)$/i;
    }
    my $request = _build_redis_request(@_);
    $self->_connect unless $self->{_socket} and $self->{_pid} == $$;

    # Here we reading received data and storing it in the _buffer,
    # but the main purpose is to check if connection is still alive
    # and reconnect if not
    $self->_recv_data_nb;

    $self->{debug} and warn "Sending request";
    defined $self->{_socket}->send($request) or die "Can't send request to server: $!";
    $self->{_commands_in_flight}++;
    return 1;
}

=head2 $self->reply_ready

This method may be used in pipelining mode to check if there are
some replies already received from server. Returns number of replies
available for reading.

=cut

sub reply_ready {
    my $self = shift;

    $self->_recv_data_nb;
    return @{ $self->{_replies} } ? 1 : 0;
}

=head2 $self->get_reply

receive reply from the server. Method croaks if server returns error reply.

=cut

sub get_reply {
    my $self = shift;

    unless ( @{ $self->{_replies} } ) {
        die "We are not waiting for reply"
          unless $self->{_commands_in_flight}
              or $self->{_subscription_loop};
        die "You can't read reply in child process" unless $self->{_pid} == $$;
        while ( not $self->_parse_reply ) {
            my $ret = $self->{_socket}->recv( my $buffer, 4096 );
            $self->{debug} and warn "Received: $buffer";
            unless ( defined $ret ) {
                next if $! == EINTR;
                die "Error reading reply from server: $!";
            }
            if ( $buffer ne '' ) {

                # received some data
                $self->{_buffer} .= $buffer;
            }
            else {

                # disconnected
                die "Server unexpectedly closed connection before sending full reply";
            }
        }
    }

    my $res = shift @{ $self->{_replies} };
    croak $res->[1] if $res->[0] eq '-';
    return $res->[1];
}

my @commands = qw(
  append	auth	bgrewriteaof	bgsave	blpop	brpoplpush	config_get
  config_set	config_resetstat	dbsize	debug_object	debug_segfault
  decr	decrby	del	echo	exists	expire	expireat	flushall
  flushdb	get	getbit	getrange	getset	hdel	hexists	hget	hgetall
  hincrby	hkeys	hlen	hmget	hmset	hset	hsetnx	hvals	incr	incrby
  info	keys	lastsave	lindex	linsert	llen	lpop	lpush	lpushx
  lrange	lrem	lset	ltrim	mget	move	mset	msetnx	persist	ping
  publish	quit	randomkey	rename	renamenx	rpop	rpoplpush
  rpush	rpushx	sadd	save	scard	sdiff	sdiffstore	select	set
  setbit	setex	setnx	setrange	shutdown	sinter	sinterstore
  sismember	slaveof	smembers	smove	sort	spop	srandmember
  srem	strlen	sunion	sunionstore	sync	ttl	type	unwatch watch
  zadd	zcard
  zcount	zincrby	zinterstore	zrange	zrangebyscore	zrank	zremrangebyrank
  zremrangebyscore	zrevrange	zrevrangebyscore	zrevrank
  zscore	zunionstore
);

=head1 SUPPORTED REDIS COMMANDS

Usually, instead of using I<execute> method, you can just use methods with names
matching names of the redis commands. The following methods are defined as wrappers around execute:
append,	auth,	bgrewriteaof,	bgsave,	blpop,	brpoplpush,	config_get,
config_set,	config_resetstat,	dbsize,	debug_object,	debug_segfault,
decr,	decrby,	del,	echo,	exists,	expire,	expireat,	flushall,
flushdb,	get,	getbit,	getrange,	getset,	hdel,	hexists,	hget,	hgetall,
hincrby,	hkeys,	hlen,	hmget,	hmset,	hset,	hsetnx,	hvals,	incr,	incrby,
info,	keys,	lastsave,	lindex,	linsert,	llen,	lpop,	lpush,	lpushx,
lrange,	lrem,	lset,	ltrim,	mget,	move,	mset,	msetnx,	persist,	ping,
publish,	quit,	randomkey,	rename,	renamenx,	rpop,	rpoplpush,
rpush,	rpushx,	sadd,	save,	scard,	sdiff,	sdiffstore,	select,	set,
setbit,	setex,	setnx,	setrange,	shutdown,	sinter,	sinterstore,
sismember,	slaveof,	smembers,	smove,	sort,	spop,	srandmember,
srem,	strlen,	sunion,	sunionstore,	sync,	ttl,	type,	unwatch, watch, zadd,	zcard,
zcount,	zincrby,	zinterstore,	zrange,	zrangebyscore,	zrank,	zremrangebyrank,
zremrangebyscore,	zrevrange,	zrevrangebyscore,	zrevrank,
zscore,	zunionstore

See description of all commands in redis documentation at L<http://redis.io/commands>.

=cut

for my $command (@commands) {
    my $uccom = uc $command;
    $uccom =~ s/_/ /g;
    no strict 'refs';
    *{ __PACKAGE__ . "::$command" } = sub {
        my $self = shift;
        return $self->execute( $uccom, @_ );
    };
}

=head1 HANDLING OF SERVER DISCONNECTS

Redis server may close connection if it was idle for some time, also connection
may be closed in case redis-server was restarted. RedisDB restores connection
to the server but only if no data was lost as result of disconnect. E.g. if
client was idle for some time and redis server closed connection, it will be
transparently restored on sending next command. If you send a command and
server closed connection without sending complete reply, connection will not be
restored and module will throw exception. Also module will throw exception if
connection will be closed in the middle of transaction.

=cut

=head1 PIPELINING SUPPORT

You can send commands in pipelining mode. In this case you sending multiple
commands to the server without waiting for replies.  You can use
I<send_command> method to send multiple commands to the server. I<reply_ready>
method may be used to check if some replies are already received. And
I<get_reply> method may be used to fetch received reply. Note, that you can't
use I<execute> method (or wrappers around it, like I<get> or I<set>) while in
pipeline mode, you must receive replies on all pipelined commands first.

=cut

=head1 SUBSCRIPTIONS SUPPORT

RedisDB supports subscriptions to redis channels. In subscription mode you can
subscribe to some channels and receive all messages sent to these channels.
Every time RedisDB receives message for the channel it invokes callback
provided by user. User can specify different callbacks for different channels.
When in subscription mode you can subscribe to additional channels, or
unsubscribe from channels you subscribed to, but you can't use any other redis
commands like set, get, etc. Here's example of running in subscription mode:

    my $message_cb = sub {
        my ($redis, $channel, $pattern, $message) = @_;
        print "$channel: $message\n";
    };
    
    my $control_cb = sub {
        my ($redis, $channel, $pattern, $message) = @_;
        if ($channel eq 'control.quit') {
            $redis->unsubscribe;
            $redis->punsubscribe;
        }
        elsif ($channel eq 'control.subscribe') {
            $redis->subscribe($message);
        }
    };
    
    subscription_loop(
        subscribe => [ 'news',  ],
        psubscribe => [ 'control.*' => $control_cb ],
        default_callback => $message_cb,
    );

subscription_loop will subscribe you to news channel and control.* channels. It
will call specified callbacks every time new message received.  You can
subscribe to additional channels sending their names to control.subscribe
channel. You can unsubscribe from all channels by sending message to
control.quit channel. Every callback receives four arguments: RedisDB object,
channel for which message was received, pattern if you subscribed to this
channel using I<psubscribe> method, and message itself.

You can publish messages into channels using I<publish> method. This method
should be called when you in normal mode, and can't be used while you're in
subscription mode.

Following methods can be used in subscribtion mode:

=cut

=head2 $self->subscription_loop(%parameters)

Enter into subscription mode. Function subscribes you to specified channels,
waits for messages, and invokes callbacks for every received message. Function
returns after you unsubscribed from all channels. It accepts following parameters:

=over 4

=item default_callback

reference to the default callback. This callback is invoked for the message if you
didn't specify other callback for the channel this message comes from.

=item subscribe

array reference. Contains list of channels you want to subscribe. Channel name
may be optionally followed by reference to callback function for this channel.
E.g.:

    [ 'news', 'messages', 'errors' => \&error_cb, 'other' ]

channels "news", "messages", and "other" will use default callback, but for
"errors" channel error_cb function will be used.

=item psubscribe

same as subscribe, but you specify patterns for channels' names.

=back

All parameters are optional, but you must subscribe at least to one channel. Also
if default_callback is not specified, you have to explicitely specify callback
for every channel you're going to subscribe.

=cut

sub subscription_loop {
    my ( $self, %args ) = @_;
    croak "Already in subscription loop" if $self->{_subscribtion_loop};
    croak "You can't start subscription loop while in pipelining mode."
      if $self->{_commands_in_flight}
          or @{ $self->{_replies} };
    $self->{_subscribed}        = {};
    $self->{_psubscribed}       = {};
    $self->{_subscription_cb}   = $args{default_callback};
    $self->{_subscription_loop} = 1;

    if ( $args{subscribe} ) {
        while ( my $channel = shift @{ $args{subscribe} } ) {
            my $cb;
            $cb = shift @{ $args{subscribe} } if ref $args{subscribe}[0] eq 'CODE';
            $self->subscribe( $channel, $cb );
        }
    }
    if ( $args{psubscribe} ) {
        while ( my $channel = shift @{ $args{psubscribe} } ) {
            my $cb;
            $cb = shift @{ $args{psubscribe} } if ref $args{psubscribe}[0] eq 'CODE';
            $self->psubscribe( $channel, $cb );
        }
    }
    croak "You must subscribe at least to one channel"
      unless ( keys %{ $self->{_subscribed} }, keys %{ $self->{_psubscribed} } );

    while ( my $msg = $self->get_reply ) {
        die "Expected multi-bulk reply, but got $msg" unless ref $msg;
        if ( $msg->[0] eq 'message' ) {
            $self->{_subscribed}{ $msg->[1] }( $self, $msg->[1], undef, $msg->[2] );
        }
        elsif ( $msg->[0] eq 'pmessage' ) {
            $self->{_psubscribed}{ $msg->[1] }( $self, $msg->[2], $msg->[1], $msg->[3] );
        }
        elsif ( $msg->[0] eq 'subscribe' or $msg->[0] eq 'psubscribe' ) {

            # ignore
        }
        elsif ( $msg->[0] eq 'unsubscribe' ) {
            delete $self->{_subscribed}{ $msg->[1] };

            # TODO think about it, not exactly correct
            last unless $msg->[2] or %{ $self->{_psubscribed} };
        }
        elsif ( $msg->[0] eq 'punsubscribe' ) {
            delete $self->{_psubscribed}{ $msg->[1] };
            last unless $msg->[2] or %{ $self->{_subscribed} };
        }
        else {
            die "Got unknown reply $msg->[0] in subscription mode";
        }
    }
    $self->_connect;
    return;
}

=head2 $self->subscribe($channel[, $callback])

Subscribe to additional I<$channel>. If I<$callback> is not specified, default
callback will be used.

=cut

sub subscribe {
    my ( $self, $channel, $callback ) = @_;
    croak "Must be in subscription loop to subscribe" unless $self->{_subscription_loop};
    croak "Subscribe to what channel?" unless length $channel;
    $callback ||= $self->{_subscription_cb}
      or croak "Callback for $channel not specified, neither default callback defined";
    $self->{_subscribed}{$channel} = $callback;
    $self->send_command( "SUBSCRIBE", $channel );
    return;
}

=head2 $self->psubscribe($pattern[, $callback])

Subscribe to additional channels matching I<$pattern>. If I<$callback> is not specified, default
callback will be used.

=cut

sub psubscribe {
    my ( $self, $channel, $callback ) = @_;
    croak "Must be in subscription loop to subscribe" unless $self->{_subscription_loop};
    croak "Subscribe to what channel?" unless length $channel;
    $callback ||= $self->{_subscription_cb}
      or croak "Callback for $channel not specified, neither default callback defined";
    $self->{_psubscribed}{$channel} = $callback;
    $self->send_command( "PSUBSCRIBE", $channel );
    return;
}

=head2 $self->unsubscribe([@channels])

Unsubscribe from the listed I<@channels>. If no channels specified, unsubscribe
from all channels.

=cut

sub unsubscribe {
    my $self = shift;
    return $self->send_command( "UNSUBSCRIBE", @_ );
}

=head2 $self->punsubscribe([@patterns])

Unsubscribe from the listed I<@patterns>. If no patterns specified, unsubscribe
from all channels to which you subscribed using I<psubscribe>.

=cut

sub punsubscribe {
    my $self = shift;
    return $self->send_command( "PUNSUBSCRIBE", @_ );
}

=head2 $self->subscribed

Return list of channels to which you have subscribed using I<subscribe>

=cut

sub subscribed {
    return keys %{ shift->{_subscribed} };
}

=head2 $self->psubscribed

Return list of channels to which you have subscribed using I<psubscribe>

=cut

sub psubscribed {
    return keys %{ shift->{_psubscribed} };
}

=head1 TRANSACTIONS SUPPORT

Transactions allow you execute a sequence of commands in a single step. In
order to start transaction you should use method I<multi>.  After you entered
transaction all commands you issue are queued, but not executed till you call
I<exec> method. Tipically these commands return string "QUEUED" as result, but
if there's an error in e.g. number of arguments they may croak. When you
calling exec all queued commands are executed and exec returns list of results
for every command in transaction. If any command failed exec will croak. If
instead of I<exec> you will call I<discard>, all scheduled commands will be
canceled.

You can set some keys as watched. If any whatched key will be changed by
another client before you call exec, transaction will be discarded and exec
will return false value.

=cut

=head2 $self->multi

Enter transaction. After this and till I<exec> or I<discard> will be called,
all commands will be queued but not executed.

=cut

sub multi {
    my $self = shift;

    my $res = $self->execute('MULTI');
    $self->{_in_multi} = 1;
    return $res;
}

=head2 $self->exec

Execute all queued commands and finish transaction. Returns list of results for
every command. May croak if some command failed.  Also unwatches all keys. If
some of the watched keys was changed by other client, transaction will be
canceled and I<exec> will return false.

=cut

sub exec {
    my $self = shift;

    my $res = $self->execute('EXEC');
    $self->{_in_multi} = undef;
    return $res;
}

=head2 $self->discard

Discard all queued commands without executing them and unwatch all keys.

=cut

sub discard {
    my $self = shift;

    my $res = $self->execute('DISCARD');
    $self->{_in_multi} = undef;
    return $res;
}

# build_redis_request($command, @arguments)
#
# Builds unified redis request from given I<$command> and I<@arguments>.
sub _build_redis_request {
    my $nargs = @_;

    use bytes;
    my $req = "*$nargs\015\012";
    while ( $nargs-- ) {
        my $arg = shift;
        $req .= '$' . length($arg) . "\015\012" . $arg . "\015\012";
    }
    return $req;
}

# $self->_parse_reply
#
# checks if buffer contains full reply. Returns 1 if it is,
# and pushes reply into @{$self->{_replies}}
my ( $READ_LINE, $READ_NUMBER, $READ_BULK_LEN, $READ_BULK, $READ_MBLK_LEN, $WAIT_BUCKS ) = 1 .. 6;

sub _parse_reply {
    my $self = shift;
    return unless $self->{_buffer};

    # if we not yet started parsing reply
    unless ( $self->{_parse_state} ) {
        my $type = substr( $self->{_buffer}, 0, 1, '' );
        $self->{_parse_reply} = [$type];
        if ( $type eq '+' or $type eq '-' ) {
            $self->{_parse_state} = $READ_LINE;
        }
        elsif ( $type eq ':' ) {
            $self->{_parse_state} = $READ_NUMBER;
        }
        elsif ( $type eq '$' ) {
            $self->{_parse_state} = $READ_BULK_LEN;
        }
        elsif ( $type eq '*' ) {
            $self->{_parse_state}      = $READ_MBLK_LEN;
            $self->{_parse_mblk_level} = 1;
        }
        else {
            die "Got invalid reply: $type$self->{_buffer}";
        }
    }

    # parse data
    my $repeat    = 1;
    my $completed = 0;
    while ($repeat) {
        $repeat = 0;
        return unless length $self->{_buffer} >= 2;
        if ( $self->{_parse_state} == $READ_LINE ) {
            if ( defined( my $line = $self->_read_line ) ) {
                if ( $self->{_parse_reply}[0] eq '+' or $self->{_parse_reply}[0] eq '-' ) {
                    $self->{_parse_reply}[1] = $line;
                    return $self->_reply_completed;
                }
                else {
                    $repeat    = $self->_mblk_item($line);
                    $completed = !$repeat;
                }
            }
        }
        elsif ( $self->{_parse_state} == $READ_NUMBER ) {
            if ( defined( my $line = $self->_read_line ) ) {
                die "Received invalid integer reply :$line" unless $line =~ /^-?[0-9]+$/;
                if ( $self->{_parse_reply}[0] eq ':' ) {
                    $self->{_parse_reply}[1] = $line;
                    return $self->_reply_completed;
                }
                else {
                    $repeat    = $self->_mblk_item($line);
                    $completed = !$repeat;
                }
            }
        }
        elsif ( $self->{_parse_state} == $READ_BULK_LEN ) {
            if ( defined( my $len = $self->_read_line ) ) {
                if ( $len >= 0 ) {
                    $self->{_parse_state}    = $READ_BULK;
                    $self->{_parse_bulk_len} = $len;
                    $repeat                  = 1;
                }
                elsif ( $len == -1 ) {
                    if ( $self->{_parse_reply}[0] eq '$' ) {
                        $self->{_parse_reply}[1] = undef;
                        return $self->_reply_completed;
                    }
                    else {
                        $repeat    = $self->_mblk_item(undef);
                        $completed = !$repeat;
                    }
                }
            }
        }
        elsif ( $self->{_parse_state} == $READ_BULK ) {
            return unless length $self->{_buffer} >= 2 + $self->{_parse_bulk_len};
            my $bulk = substr( $self->{_buffer}, 0, $self->{_parse_bulk_len}, '' );
            substr $self->{_buffer}, 0, 2, '';
            if ( $self->{_parse_reply}[0] eq '$' ) {
                $self->{_parse_reply}[1] = $bulk;
                return $self->_reply_completed;
            }
            else {
                $repeat    = $self->_mblk_item($bulk);
                $completed = !$repeat;
            }
        }
        elsif ( $self->{_parse_state} == $READ_MBLK_LEN ) {
            if ( defined( my $len = $self->_read_line ) ) {
                if ( $len > 0 ) {
                    $self->{_parse_mblk_len} = $len;
                    $self->{_parse_state}    = $WAIT_BUCKS;
                    $self->{_parse_reply}[1] = [];
                    $repeat                  = 1;
                }
                elsif ( $len == 0 ) {
                    $self->{_parse_reply}[1] = [];
                    return $self->_reply_completed;
                }
                elsif ( $len == -1 ) {
                    $self->{_parse_reply}[1] = undef;
                    return $self->_reply_completed;
                }
                else {
                    die "Invalid multi-bulk reply: *$len\015\012$self->{_buffer}";
                }
            }
        }
        elsif ( $self->{_parse_state} == $WAIT_BUCKS ) {
            my $char = substr( $self->{_buffer}, 0, 1, '' );
            if ( $char eq '$' ) {
                $self->{_parse_state} = $READ_BULK_LEN;
            }
            elsif ( $char eq ':' ) {
                $self->{_parse_state} = $READ_NUMBER;
            }
            elsif ( $char eq '+' ) {
                $self->{_parse_state} = $READ_LINE;
            }
            elsif ( $char eq '*' ) {
                $self->{_parse_state} = $READ_MBLK_LEN;
                $self->{_parse_mblk_level}++;
                $self->{_parse_mblk_store} = [ $self->{_parse_mblk_len}, $self->{_parse_reply} ];
                $self->{_parse_reply} = ['*'];
            }
            else {
                die "Invalid multi-bulk reply. Expected '\$' or ':' but got $char"
                  ;    # $self->{_buffer}";
            }
            $repeat = 1;
        }
    }
    return $completed ? $self->_reply_completed : undef;
}

sub _read_line {
    my $self = shift;
    my $pos = index $self->{_buffer}, "\015\012";
    my $line;
    if ( $pos >= 0 ) {

        # Got end of the line, add all stuff before \r\n
        # to the reply string. Strip \r\n from the buffer
        $line = substr( $self->{_buffer}, 0, $pos, '' );
        substr $self->{_buffer}, 0, 2, '';
    }
    return $line;
}

sub _mblk_item {
    my ( $self, $value ) = @_;

    push @{ $self->{_parse_reply}[1] }, $value;
    my $repeat;
    if ( --$self->{_parse_mblk_len} ) {
        $self->{_parse_state} = $WAIT_BUCKS;
        $repeat = 1;
    }
    elsif ( --$self->{_parse_mblk_level} ) {
        $self->{_parse_mblk_len} = shift @{ $self->{_parse_mblk_store} };
        $self->{_parse_mblk_len}--;
        my $reply = shift @{ $self->{_parse_mblk_store} };
        push @{ $reply->[1] }, $self->{_parse_reply}[1];
        $self->{_parse_reply} = $reply;
        $self->{_parse_state} = $WAIT_BUCKS;
        $repeat               = $self->{_parse_mblk_len} > 0;
    }
    else {
        $repeat = 0;
    }

    return $repeat;
}

sub _reply_completed {
    my $self = shift;
    $self->{_parse_state} = undef;
    push @{ $self->{_replies} }, $self->{_parse_reply};
    $self->{_commands_in_flight}--;
    $self->{_parse_reply} = undef;
    return 1;
}

1;

__END__

=head1 SEE ALSO

L<Redis>, L<Redis::hiredis>, L<AnyEvent::Redis>

=head1 WHY ANOTHER ONE

I was in need of a client for redis database. L<AnyEvent::Redis> didn't suite
me as it requires event loop, and it didn't fit into existing code. Problem
with L<Redis> is that it doesn't (at the time I write this) reconnect to the
server if connection was closed after timeout or as result or server restart,
and it doesn't support pipelining. After analizing what I need to change in
L<Redis> in order to get all I want (see TODO), I decided that it will be
simplier to write new module from scratch. This also solves the problem of
backward compatibility. Pedro Melo, maintainer of L<Redis> have plans to
implement some of these features too.

=head1 TODO

=over 4

=item *

Test all commands

=item *

Handle cases when client is not interested in replies

=back

=head1 BUGS

Please report any bugs or feature requests via GitHub bug tracker at
L<http://github.com/trinitum/RedisDB/issues>.

=head1 AUTHOR

Pavel Shaydo, C<< <zwon at cpan.org> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2011 Pavel Shaydo.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.


=cut

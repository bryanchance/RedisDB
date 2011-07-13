#!/usr/bin/perl 

use 5.010;
use warnings;
use Redis;
use RedisDB;
use Redis::hiredis;
use lib qw(t ../t);
use RedisServer;

use Benchmark qw( cmpthese );

say "Testing against";
say "RedisDB:        ", RedisDB->VERSION;
say "Redis:          ", Redis->VERSION;
say "Redis::hiredis: ", Redis::hiredis->VERSION;

my $srv     = RedisServer->start;
my $redis   = Redis->new( server => "localhost:$srv->{port}" );
my $redisdb = RedisDB->new( host => "localhost", port => $srv->{port} );
my $hiredis = Redis::hiredis->new();
$hiredis->connect('localhost');

sub sender {
    my ( $cli, $num, $data ) = @_;
    for ( 1 .. $num ) {
        $cli->set( "key$_", $data );
        $cli->get("key$_");
    }
}

cmpthese - 5, {
    Redis => sub {
        sender( $redis, 10000, "0123456789abcdef" );
    },
    hiredis => sub {
        sender( $hiredis, 10000, "0123456789abcdef" );
    },
    RedisDB => sub {
        sender( $redisdb, 10000, "0123456789abcdef" );
    },
    "RedisDB Pipelining" => sub {
        for ( 1 .. 10000 ) {
            $redisdb->send_command( 'SET', "RDB$_", "0123456789abcdef" );
            $redisdb->send_command( 'GET', "RDB$_" );
        }
        my %res;
        for ( 1 .. 20000 ) {
            $res{ $redisdb->get_reply }++;
        }
        die "wrong result" unless $res{'0123456789abcdef'} == 10000;
    },
    "hiredis pipelining" => sub {
        for ( 1 .. 10000 ) {
            $hiredis->append_command("SET RDB$_ 0123456789abcdef");
            $hiredis->append_command("GET RDB$_");
        }
        my %res;
        for ( 1 .. 20000 ) {
            $res{ $hiredis->get_reply }++;
        }
        die "wrong result" unless $res{'0123456789abcdef'} == 10000;
        die "wrong result" unless $res{'OK'} == 10000;
      }
};

cmpthese - 5, {
    Redis => sub {
        sender( $redis, 3000, "0123456789abcdef" x 128 );
    },
    hiredis => sub {
        sender( $hiredis, 3000, "0123456789abcdef" x 128 );
    },
    RedisDB => sub {
        sender( $redisdb, 3000, "0123456789abcdef" x 128 );
    },
};

cmpthese - 5, {
    Redis => sub {
        sender( $redis, 1000, "0123456789abcdef" x 1024 );
    },
    hiredis => sub {
        sender( $hiredis, 1000, "0123456789abcdef" x 128 );
    },
    RedisDB => sub {
        sender( $redisdb, 1000, "0123456789abcdef" x 1024 );
    },
};

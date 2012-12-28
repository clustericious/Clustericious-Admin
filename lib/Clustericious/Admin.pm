=head1 NAME

Clustericious::Admin - Simple parallel ssh client.

=head1 DESCRIPTION

This is a simple parallel ssh client, with a verbose
configuration syntax for running ssh commands on various
clusters of machines.

Most of the documentation is in the command line tool L<clad>.

=head1 SEE ALSO

L<clad>

=head1 TODO

Handle escaping of quote/meta characters better.

=cut

package Clustericious::Admin;

use Clustericious::Config;
use Clustericious::Log;
use IPC::Open3 qw/open3/;
use Symbol 'gensym';
use IO::Handle;
use Term::ANSIColor;
use Hash::Merge qw/merge/;
use Mojo::Reactor;
use Data::Dumper;
use Clone qw/clone/;
use POSIX ":sys_wait_h";
use 5.10.0;

use warnings;
use strict;

our $VERSION = '0.21';
our @colors = qw/cyan green/;
our %waiting;   # keyed on host
our %waitqueue; # keyed on pid
our $SSHCMD = "ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o PasswordAuthentication=no";

sub _conf {
    our $conf;
    $conf ||= Clustericious::Config->new("Clad");
    return $conf;
}

sub banners {
    our $banners;
    $banners ||= _conf->banners(default => []);
    for (@$banners) {
        $_->{text} =~ s/\\n/\n/g;
        my @lines = $_->{text} =~ /^(.*)$/mg;
        $_->{lines} = \@lines;
    }
    return $banners;
}

sub _is_builtin {
    return $_[0] =~ /^cd /;
}

sub done_watching {
        my ($w,$host,$ssh,$next) = @_;
        return unless $waiting{$host};
        INFO "Done with $host (pid $waiting{$host}), removing handle";
        delete $waiting{$host};
        $w->remove($ssh);
        if ($$next) {
            DEBUG "Running next command.";
            $$next->();
            undef $$next;
        }
        #$w->stop unless keys %waiting > 0;
        return;
};

sub _queue_command {
    my ($user,$w,$color,$env,$host,@command) = @_;
    DEBUG "Creating ssh to $host";
    my $next;
    $next = pop @command if ref($command[-1]) eq 'CODE';
    DEBUG "next is $next" if $next;

    my($wtr, $ssh, $err);
    $err = gensym;
    my $ssh_cmd;
    my $login = $user ? " -l $user " : "";
    if (ref $host eq 'ARRAY') {
        $ssh_cmd = join ' ', map "$SSHCMD $login $_", @$host;
        $host = $host->[1];
    } else {
        $ssh_cmd = "$SSHCMD $login -T $host";
    }
    my $pid = open3($wtr, $ssh, $err, "trap '' HUP; $ssh_cmd /bin/sh -e") or do {
        WARN "Cannot ssh to $host: $!";
        return;
    };

    for my $cmd (@command) {
        my @cmd = $cmd;
        unless (_is_builtin($cmd)) {
            while (my ($k,$v) = each %$env) {
                unshift @cmd, "$k=$v";
            }
            unshift @cmd, qw/env/;
        }
        print $wtr "@cmd\n";
    }

    DEBUG "New ssh process to $host, pid $pid (@command)";
    $waiting{$host} = $pid;
    if ($next) {
        $waitqueue{$pid} = $next;
    }

    $w->io( $ssh,
        sub {
            my ($readable, $writable) = @_;
            unless (kill 0, $pid) {
                TRACE "$pid is dead (stdin)";
                $w->remove($ssh);
                #$next->() if $next;
                #undef $next;
                return;
            }
            #return done_watching($w,$host,$ssh,\$next) unless kill 0, $pid;
            return if eof($ssh);
            chomp (my $line = <$ssh>);
            print color $color if @colors;
            print "[$host] ";
            print color 'reset' if @colors;
            print "$line\n";
         });

    my $banners = banners();
    $w->io(
        $err,
        sub {
            my ($readable, $writable) = @_;
            state $filters = [];
            unless (kill 0, $pid) {
                TRACE "$pid is dead (err)";
                $w->remove($err);
                return;
            }
            #return done_watching($w,$host,$ssh,\$next) unless kill 0, $pid;
            return if eof($err);
            my $skip;
            chomp (my $line = <$err>);
            for (0..$#$banners) {
                $filters->[$_] //= { line => 0 };
                my $l = \( $filters->[$_]{line} );
                my $filter_line = $banners->[$_]{lines}[$$l];
                if ($line eq $filter_line) {
                    TRACE "matched filter $_ (line $$l) : '$line'";
                    $skip = 1;
                    $$l++;
                    if ($$l >= @{ $banners->[$_]{lines} }) {
                        $filters->[$_] = undef;
                    }
                } else {
                    $filters->[$_] &&= undef;
                    TRACE "line vs filter number $_ : '$line' vs '$filter_line'";
                }
            }
            return if $skip;
            print color $color;
            print "[$host (stderr)] ";
            print color 'reset';
            print "$line\n";
         });
    $w->watch($err,1,0);
    $w->watch($ssh,1,0);
    $w->on(error => sub {
        my ($reactor,$err) = @_;
        ERROR "$host : $err";
        delete $waiting{$host};
        $reactor->stop unless keys %waiting > 0;
    });
    TRACE "queued command @command on $host";
}

sub clusters {
    my %clusters = _conf->clusters;
    return sort keys %clusters;
}

sub aliases {
    my %aliases = _conf->aliases(default => {});
    return sort keys %aliases;
}

sub generate_command_sequence {
    my $arg = shift;

    # returns ( { command => [...], user => ... }, { command => [...], user => ... } );
    if (my $alias = _conf->aliases(default => {})->{$arg}) {
        DEBUG "Found alias $arg";
        my @cmd = (ref $alias ? @$alias : ( $alias ), @_ );
        return ( { command => \@cmd } );
    }
    if (my $macro = _conf->macros(default => {})->{$arg}) {
        DEBUG "Found macro $arg";
        my @cmd;
        for (@$macro) {
            for my $got (generate_command_sequence($_->{command})) {
                $got->{user} = $_->{login};
                push @cmd, $got;
            }
        }
        return @cmd;
    }

    return ( { command => [ $arg, @_ ] } );
}

sub run {
    my $class = shift;
    my $opts = shift;
    my $dry_run = $opts->{n};
    my $user = $opts->{l};
    @colors = () if $opts->{a};
    my $cluster = shift or LOGDIE "Missing cluster";
    my $clusters = _conf->clusters(default => '') or LOGDIE "no clusters defined";
    ref($clusters) =~ /config/i or LOGDIE "clusters should be a yaml hash";
    my $hosts = $clusters->$cluster(default => '') or LOGDIE "no hosts for cluster $cluster";
    my $cluster_env = {};
    my @hosts;
    if (ref $hosts eq 'ARRAY') {
        @hosts = @$hosts;
    } else {
        @hosts = $hosts->hosts;
        if (my $proxy = $hosts->proxy(default => '')) {
            @hosts = map [ $proxy, $_ ], @hosts;
        }
        $cluster_env = $hosts->{env} || {};
    }
    LOGDIE "no hosts found" unless @hosts;
    LOGDIE "No command given" unless $_[0];

    my @command_sequence = generate_command_sequence(@_);

    for (@command_sequence) {
        LOGDIE "No command" unless $_->{command} && $_->{command}[0];
        s/\$CLUSTER/$cluster/ for @{ $_->{command} };
        do { $_->{user} ||= $user } if $user;
        my $msg = $_->{user} ? "as $_->{user} " : "";
        DEBUG "Will run @{ $_->{command} } ${msg}on cluster $cluster";
    }
    my $i = 0;
    my $env = _conf->{env} || {};
    $env = merge( $cluster_env, $env );
    TRACE "Env : ".Dumper($env);
    my $watcher = Mojo::Reactor->detect->new;
    for my $host (@hosts) {
        $i++;
        $i = 0 if $i == @colors;
        my $where = ( ref $host eq 'ARRAY' ? $host->[-1] : $host );

        if ($dry_run) {
            for my $cmd (@command_sequence) {
                my @command = @{ $cmd->{command} };
                INFO "Not running on $where : " . join '; ', @command;
            }
            exit;
        }

        my $last;
        while (my $cmd  = pop @command_sequence) {
            my @command = @{ $cmd->{command} };
            my $next = $last;
            DEBUG "queuing @command ($cmd->{user}) next is ".($next// 'undef');
            $last = sub {
                DEBUG "Running on $where as ".($cmd->{user} || '<default>')." : " . join ';', @command;
                DEBUG "Will run another command afterwards." if $next;
                _queue_command( $cmd->{user}, $watcher, $colors[$i], $env, $host, @command, ( $next ? $next : () ) );
            };
        }
        $last->();

        if ( Log::Log4perl::get_logger()->is_trace ) {
            $watcher->recurring(
                2 => sub {
                    TRACE "Waiting for $host (pid $waiting{$host})" if $waiting{$host};
                    TRACE "Not waiting for any host" unless keys %waiting;
                }
            );
        }
    }
    $watcher->recurring(1 => sub { TRACE "tick" } );
    $watcher->recurring(
        0 => sub {
            while ( ( my $pid = waitpid( -1, WNOHANG ) ) > 0 ) {
                DEBUG "Reaped child pid: $pid";
                my ($host) = grep { $waiting{$_} == $pid } keys %waiting;
                unless ($host) {
                    WARN "Cannot find host for pid $pid";
                    next;
                }
                delete $waiting{$host};
                if (my $cb = delete $waitqueue{$pid}) {
                    $cb->();
                }
                unless (keys %waiting) {
                    DEBUG "we are done";
                    $watcher->stop;
                }
            }
        }
    );
    $watcher->start;
}

1;


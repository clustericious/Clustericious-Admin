=head1 NAME

Clustericious::Admin - Administer clustericious clusters.

=head1 DESCRIPTION

This is a tool for executing commands on all the hosts
within a cluster.

A configuration file specifies hosts in a cluster,
command aliases, and environment settings.

Then typing "clad <cluster> <command>" runs
the command on every host in the named cluster.

Environment variables can be set using the env entry
in the configuration file.

=head1 TODO

Handle escaping of quote/meta characters better.

=head1 SEE ALSO

clad

=cut

package Clustericious::Admin;

use Clustericious::Config;
use Clustericious::Log;
use IPC::Open3 qw/open3/;
use Symbol 'gensym';
use IO::Handle;
use Term::ANSIColor;
use Mojo::Reactor;

use warnings;
use strict;

our $VERSION = '0.19';
our @colors = qw/cyan green/;
our %waiting;
our %filtering;
our $SSHCMD = "ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o PasswordAuthentication=no";
our @filter = ( (split /\n/, <<DONE), "", "", "" );

      ---------------------------------------------------------------

              WARNING!  This is a U.S. Government Computer

        This U.S. Government computer is for authorized users only.

        By accessing this system, you are consenting to complete
        monitoring with no expectation of privacy.  Unauthorized
        access or use may subject you to disciplinary action and 
        criminal prosecution.

      ---------------------------------------------------------------


DONE

sub _conf {
    our $conf;
    $conf ||= Clustericious::Config->new("Clad");
    return $conf;
}

sub _is_builtin {
    return $_[0] =~ /^cd /;
}

sub _queue_command {
    my ($user,$w,$color,$env,$host,@command) = @_;
    TRACE "Creating ssh to $host";

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

    TRACE "New ssh process to $host, pid $pid";
    $waiting{$host} = $pid;

    $w->io( $ssh,
        sub {
            my ($readable, $writable) = @_;
            if (eof($ssh)) {
                TRACE "Done with $host (pid $waiting{$host}), removing handle";
                $w->remove($ssh);
                delete $waiting{$host};
                $w->stop unless keys %waiting > 0;
                return;
            }
            chomp (my $line = <$ssh>);
            print color $color if @colors;
            print "[$host] ";
            print color 'reset' if @colors;
            print "$line\n";
         });

    $w->io(
        $err,
        sub {
            my ($readable, $writable) = @_;
            return if eof($err);
            my $skip;
            chomp (my $line = <$err>);
            if (!defined($filtering{$host})) {
                $filtering{$host} = [ @filter ];
            } elsif ($line eq (' 'x 6).('-' x 63) && !@{ $filtering{$host} }) {
                $filtering{$host} = [ @filter ];
                shift @{ $filtering{$host} };
            }
            if (scalar @{ $filtering{$host} }) {
                my $f = $filtering{$host}->[0];
                if ($f eq $line) {
                    $skip = 1;
                    shift @{ $filtering{$host} };
                } else {
                    DEBUG "line vs filter  : '$line' vs '$f'" if $f;
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

}

sub clusters {
    my %clusters = _conf->clusters;
    return sort keys %clusters;
}

sub aliases {
    my %aliases = _conf->aliases;
    return sort keys %aliases;
}

sub run {
    my $class = shift;
    my $opts = shift;
    my $dry_run = $opts->{n};
    my $user = $opts->{l};
    @colors = () if $opts->{a};
    my $cluster = shift or LOGDIE "Missing cluster";
    my $hosts = _conf->clusters->$cluster(default => '') or LOGDIE "no hosts for cluster $cluster";
    my @hosts;
    if (ref $hosts eq 'ARRAY') {
        @hosts = @$hosts;
    } else {
        my $proxy = $hosts->proxy(default => '');
        @hosts = map [ $proxy, $_ ], $hosts->hosts;
    }
    LOGDIE "no hosts found" unless @hosts;
    my $alias = $_[0] or LOGDIE "No command given";
    my @command = _conf->aliases->$alias(default => "@_" );
    s/\$CLUSTER/$cluster/ for @command;
    DEBUG "Running @command on cluster $cluster";
    my $i = 0;
    my $env = _conf->env(default => {});
    my $watcher = Mojo::Reactor->detect->new;
    for my $host (@hosts) {
        $i++;
        $i = 0 if $i == @colors;
        my $where = ( ref $host eq 'ARRAY' ? $host->[-1] : $host );
        if ($dry_run) {
            INFO "Not running on $where : " . join '; ', @command;
        } else {
            TRACE "Running on $where : " . join ';', @command;
            _queue_command( $user, $watcher, $colors[$i], $env, $host, @command );
        }
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
    $watcher->start unless $dry_run;
}

1;


=head1 NAME

Clustericious::Admin - Administer clustericious clusters.

=head1 DESCRIPTION

This is a tool for executing commands on all the hosts
within a cluster.

A configuration file specifies hosts in a cluster,
command aliases, and environment settings.

Then typing "clad <cluster> <command>" runs
the command on every host in the named cluster.

=head1 SEE ALSO

clad

=cut

package Clustericious::Admin;

use Clustericious::Config;
use Clustericious::Log;
use IPC::PerlSSH;
use IO::Handle;
use Term::ANSIColor;
use Mojo::IOLoop;

use warnings;
use strict;

our $VERSION = '0.02';
our @colors = qw/cyan green/;
my %waiting;

sub _conf {
    our $conf;
    $conf ||= Clustericious::Config->new("Clad");
    return $conf;
}

sub _queue_command {
    my ($w,$color,$env,$host,@command) = @_;

    while (my ($k,$v) = each %$env) {
        unshift @command, "$k=$v";
    }
    no warnings 'once';

    # Suppress STDERR (login banner)
    open( DUPERR, ">&STDERR" )
      or warn("::IPS Warning: Unable to dup STDERR\n");
    close(STDERR);

    # Create a file descriptor
    open my $ssh, '-|', "ssh $host '@command'" or LOGDIE "Can't ssh to $host: $!";

    # Reopen STDERR
    open( STDERR, ">&DUPERR" );
    $w->add( $ssh,
        on_readable => sub {
            my ($watcher, $handle) = @_;
            if (eof($handle)) {
                $watcher->remove($handle);
                delete $waiting{$host};
                if (keys %waiting == 0) {
                    Mojo::IOLoop->timer(1 => sub { Mojo::IOLoop->stop });
                }
                return;
            }
            chomp (my $line = <$handle>);
            print color $color;
            print "[$host] ";
            print color 'reset';
            print "$line\n";
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
    my $dry_run = ($_[0] eq '-n' ? shift : 0);
    my $cluster = shift or LOGDIE "Missing cluster";
    my @hosts = _conf->clusters->$cluster( default => [] )
      or LOGDIE("Cluster '$cluster' not found");
    my $alias = $_[0] or LOGDIE "No command given";
    my @command = _conf->aliases->$alias(default => [@_] );
    s/\$CLUSTER/$cluster/ for @command;
    DEBUG "Running @command on cluster $cluster";
    my $i = 0;
    my $env = _conf->env(default => {});
    my $w = Mojo::IOLoop->singleton->iowatcher;
    for my $host (@hosts) {
        $i++;
        $i = 0 if $i==@colors;
        if ($dry_run) {
            INFO "Not running on $host : @command";
        } else {
            TRACE "Running on $host : @command";
            _queue_command($w,$colors[$i],$env,$host,@command);
        }
    }
    Mojo::IOLoop->start;
}

1;


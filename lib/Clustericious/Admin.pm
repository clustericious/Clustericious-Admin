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
use Parallel::ForkManager;
use IO::Handle;
use Term::ANSIColor;
use warnings;
use strict;

our $VERSION = '0.02';
our @colors = qw/cyan green/;

sub _conf {
    our $conf;
    $conf ||= Clustericious::Config->new("Clad");
    return $conf;
}

sub _run_command {
    my ($color,$env,$host,@command) = @_;
    my $ipc;

    {
        no warnings 'once';
        autoflush STDERR 1;

        # Suppress STDERR (login banner)
        open( DUPERR, ">&STDERR" )
          or warn("::IPS Warning: Unable to dup STDERR\n");
        close(STDERR);

        # Create an IPC::PerlSSH object
        $ipc = IPC::PerlSSH->new(Host  => $host) or do {
            WARN "Could not connect to $host";
            return;
        };
        $ipc->use_library("Run", ("system_inout","system_outerr"));

        # Reopen STDERR
        open( STDERR, ">&DUPERR" );
    }
    while (my ($k,$v) = each %$env) {
        unshift @command, "$k=$v";
    }
    my ($exit, $out, $stderr) = $ipc->call("system_outerr", "@command");
    for (split /\n/, $out) {
        print color $color;
        print "[$host] ";
        print color 'reset';
        print "$_\n";
    }
    TRACE "exit code for $host : $exit";
}

sub clusters {
    my %clusters = _conf->clusters;
    return sort keys %clusters;
}

sub commands {
    my %commands = _conf->commands;
    return sort keys %commands;
}

sub run {
    my $class = shift;
    my ($cluster,$command) = @_;
    LOGDIE "Missing cluster or command" unless $cluster && $command;
    DEBUG "Running $command on cluster $cluster";
    my @hosts = _conf->clusters->$cluster( default => [] )
      or LOGDIE("Cluster '$cluster' not found");
    my @command = _conf->commands->$command(default => [] )
      or LOGDIE("Command '$command' not found.");
    my $pm = Parallel::ForkManager->new(10);
    my $i = 0;
    my $env = _conf->env(default => {});
    for my $host (@hosts) {
        $i++;
        $i = 0 if $i==@colors;
        $pm->start and next;
        TRACE "Running @command on $host";
        _run_command($colors[$i],$env,$host,@command);
        $pm->finish;
    }
    $pm->wait_all_children;
}

1;


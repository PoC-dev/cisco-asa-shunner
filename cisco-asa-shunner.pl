#!/usr/bin/perl -w

# Copyright 2024 Patrik Schindler <poc@pocnet.net>
#
# This file is part of the Cisco ASA Shunner, to be found on https://github.com/PoC-dev/cisco-asa-shunner - see there for further
# details.
#
# This is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or (at your option) any later version.
#
# It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with this; if not, write to the Free Software Foundation,
# Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307 USA or get it at http://www.gnu.org/licenses/gpl.html

# ----------------------------------------------------------------------------------------------------------------------------------

use strict;
no strict "subs"; # For allowing symbolic names for syslog priorities.
use warnings;
use Expect; # https://metacpan.org/pod/release/RGIERSIG/Expect-1.15/Expect.pod
use Getopt::Std;
use Sys::Syslog;

# We use syslog in the following way:
# LOG_ERR for when we die();
# LOG_WARNING for non fatal conditions
# LOG_INFO for regular messages
# LOG_DEBUG for context in what we're doing currently

# ----------------------------------------------------------------------------------------------------------------------------------
# Variables.

our $config;
require "/etc/fail2ban/cisco-asa-shunner.asacreds"; # For safety reasons, this data is not in the script.
my $hostname = $config->{'hostname'};
my $username = $config->{'username'};
my $password = $config->{'password'};
my $enable   = $config->{'enable'};

# Connection.
my ($cnh, @cnh_parms);

# For Regex.
my ($pat, $err, $match, $before, $after, $command);

# Others.
my ($retval, $task, $ipaddr);

# Matches a Cisco-CLI-Prompt, so Expect knows when the result of the sent command has been sent.
my $prompt_re = '^((?!<).)*[\#>]\s?$';

# ----------------------------------------------------------------------------------------------------------------------------------

# See: https://alvinalexander.com/perl/perl-getopts-command-line-options-flags-in-perl/

my %options = ();
$retval = getopts("hd", \%options);

if ( $retval != 1 ) {
    printf(STDERR "Wrong parameter error.\n\n");
}

# Parse remaining arguments into variables.
# FIXME: How to do this properly?
# FIXME: Validate IP(v6) address.
my $N=0;
foreach (@ARGV) {
  if ( $N eq 0 ) {
      $task = $_;
  } elsif ( $N eq 1 ) {
      $ipaddr = $_;
  }
  $N++;
}

if ( defined($options{h}) || $retval != 1 ) {
    printf("Usage: cisco-asa-shunner(.pl) [options] [shun|unshun] <IP>\nOptions:
    -d: Enable debug mode
    -h: Show this help and exit\n\n");
    printf("Note that logging is done almost entirely via syslog, facility user.\n");
    exit(0);
}


# Enable debug mode.
if ( defined($options{d}) ) {
    openlog("cisco-asa-shunner", "perror,pid", "user");
} else {
    openlog("cisco-asa-shunner", "pid", "user");
    # Omit debug messages by default.
    # FIXME: What is the correct way to handle this with symbolic names?
    setlogmask(127);
}

# ----------------------------------------------------------------------------------------------------------------------------------
# Connect to ASA.

syslog(LOG_DEBUG, "Debug: Trying to connect to %s@%s to %s %s", $username, $hostname, $task, $ipaddr);

push(@cnh_parms, $username . "@" . $hostname);
$cnh = Expect->spawn("/usr/bin/ssh", @cnh_parms);
$cnh->log_stdout(0);
$cnh->exp_internal(0);

($pat, $err, $match, $before, $after) = $cnh->expect(10, '-re',
    '(\S+ )?[Pp]assword:',
    'Are you sure you want to continue connecting \(yes/no(/\[fingerprint\])?\)\?',
    '% Authorization failed\.'
);

if ( ! defined($err) ) {
    if ( $pat eq 2 ) {
        syslog(LOG_INFO, "Info: Accepting hostkey");
        $cnh->send("yes\n");
        $cnh->expect(10, '-re', '(\S+ )?[Pp]assword:');
    } elsif ( $pat eq 3 ) {
        syslog(LOG_ERR, "Err: failed local authorization");
        die;
    }
    # FIXME: How can we know if we (not) failed local authorization here? Blindly sending a password? Hmm.
    $cnh->send($password . "\n");
}

# If we can't log in, skip any further processing for that host.
if ( $err ) {
    syslog(LOG_ERR, "Err: Expect error %s encountered when spawning ssh", $err);
    die;
}

# --------------------------------------------------------------------------

# If we have a valid connection handle, continue talking to the device.
if ( $cnh ) {
    # Do we see a prompt? With or without being enabled?
    ($pat, $err, $match, $before, $after) = $cnh->expect(5,
        '-re', '^.*>\s?$',
        '-re', '^.*\#\s?$'
    );

    # Handle Connection timeouts properly?
    if ( ! defined($pat) ) {
        syslog(LOG_ERR, "Err: Timeout while waiting for command line prompt");
        die;
    }

    # Handle enabling of the user.
    if ( $pat == 1 ) {
        syslog(LOG_DEBUG, "Debug: We are NOT enabled");
        if ( $enable ) {
            $cnh->send("enable\n");
            $cnh->expect(5, '-re', '^\s*Password: \s?$');
            $cnh->send($enable . "\n");
        } else {
            syslog(LOG_ERR, "Err: Need to send 'enable' but enable password is not defined in configuration");
            die;
        }
    } else {
        # Just press return - altering send/expect is mandatory.
        $cnh->send("\n");
    }
    $cnh->expect(5, '-re', $prompt_re);


    # Send what we shall do.
    if ( $task eq 'shun' ) {
        $command = "shun";
    } elsif ( $task eq 'unshun' ) {
        $command = "no shun";
    }

    # Send command (shun or no shun).
    syslog(LOG_DEBUG, "Debug: Sending %s %s", $command, $ipaddr);
    $cnh->send($command . " " . $ipaddr . "\n");

    # See what we got back.
    ($pat, $err, $match, $before, $after) = $cnh->expect(5,
        '-re', $prompt_re,
        '-re', 'ERROR:',
    );

    if ( $pat == 2 ) {
        # Something's gone wrong. Missing command authorization?
        syslog(LOG_WARNING, "Warning: Command '%s' failed: '%s'", $command, $after);
    } else {
        syslog(LOG_DEBUG, "Debug: Got prompt back, command succeeded");
    }
} else {
    syslog(LOG_ERR, "Err: Could not obtain Expect-Handle");
}

#-----------------------------------------------------------------------------------------------------------------------------------

END {
    if (defined($cnh) ) {
        $cnh->send("exit\n");
        $cnh->soft_close();
    }

    syslog(LOG_DEBUG, "Debug: Finished");

    closelog;
}

#-----------------------------------------------------------------------------------------------------------------------------------
# vim: tabstop=4 shiftwidth=4 autoindent colorcolumn=133 expandtab textwidth=132 filetype=perl
# -EOF-

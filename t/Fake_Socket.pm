#---------------------------------------------------------------------
package t::Fake_Socket;
#
# Copyright 2015 Christopher J. Madsen
#
# Author: Christopher J. Madsen <perl@cjmweb.net>
# Created: 26 Dec 2015
#
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See either the
# GNU General Public License or the Artistic License for more details.
#
# ABSTRACT: Fake socket class for testing Telephony::Asterisk::AMI
#---------------------------------------------------------------------

# VERSION
# This file is part of {{$dist}} {{$dist_version}} ({{$date}})

use 5.008;
use strict;
use warnings;

use IO::Socket::IP ();
use Tie::Handle ();

use Exporter 5.57 'import';     # exported import method
our @EXPORT = qw(set_input socket_args socket_output);

our @ISA = qw(Tie::Handle);

#=====================================================================
# Socket implementation
#---------------------------------------------------------------------
my (@input, $output, $socket_args);

sub TIEHANDLE {
  $output = '';
  bless {}, shift;
}

sub READLINE { shift @input }

sub WRITE {
  my ($self, $data, $length, $offset) = @_;

  $output .= substr($data, $offset, $length);
  1;
}

sub CLOSE { 1 }

#=====================================================================
# Monkey-patch IO::Socket::IP to return a t::Fake_Socket instead
#---------------------------------------------------------------------
{
  no warnings 'redefine';

  sub IO::Socket::IP::new {
    my ($class, %args) = @_;

    $socket_args = \%args;

    tie *t::Fake_Socket::SOCKET_FH, 't::Fake_Socket';

    *t::Fake_Socket::SOCKET_FH;
  } # end IO::Socket::IP::new
}

#=====================================================================
# Exported subroutines
#---------------------------------------------------------------------

# Set up the @input array from a string
sub set_input {
  @input = split(/\r?\n/, shift, -1);
  $_ .= "\r\n" for @input;
} # end set_input

# Return the current $socket_args
sub socket_args {
  $socket_args;
}

# Return the current $output and clear it
sub socket_output {
  substr($output, 0, length($output), '');
}

#=====================================================================
# Package Return Value:

1;

__END__

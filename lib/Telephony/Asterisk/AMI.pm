#---------------------------------------------------------------------
package Telephony::Asterisk::AMI;
#
# Copyright 2015 Christopher J. Madsen
#
# Author: Christopher J. Madsen <perl@cjmweb.net>
# Created: 31 Oct 2015
#
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See either the
# GNU General Public License or the Artistic License for more details.
#
# ABSTRACT: Simple Asterisk Manager Interface client
#---------------------------------------------------------------------

use 5.008;
use strict;
use warnings;

use Carp ();
use IO::Socket::IP ();

our $VERSION = '0.001';
# This file is part of {{$dist}} {{$dist_version}} ({{$date}})

my $EOL = "\r\n";

#=====================================================================

=method new

  $ami = Telephony::Asterisk::AMI->new(%args);

Constructs a new C<$ami> object.  The C<%args> may be passed as a
hashref or a list of S<C<< key => value >>> pairs.

This does not do any network communication; you must call L</connect>
to open the connection before doing anything else.

The parameters are:

=over

=item C<Username>

The AMI username to use when logging in. (required)

=item C<Secret>

The AMI secret (password) to use when logging in. (required)

=item C<Host>

The hostname to connect to.
You can also specify C<hostname:port> as a single string.
(default: localhost).

=item C<Port>

The port number to connect to (if no port was specified with C<Host>).
(default: 5038)

=item C<ActionID>

The ActionID to start at.  Each call to L</action> increments the ActionID.
(Note: The L</connect> method also consumes an ActionID for the
implicit Login action.)
(default: 1)

=item C<Debug>

If set to a true value, sets C<Debug_FH> to C<STDERR>
(unless it was already set to a different value).
(default: false)

=item C<Debug_FH>

A filehandle to write a transcript of the communications to.
Lines sent to Asterisk are prefixed with C<<< >> >>>, and lines
received from Asterisk are prefixed with C<<< << >>>.
(default: no transcript)

=item C<Event_Callback>

A coderef that is called when an event is received from Asterisk.  The
event data is passed as a hashref, just like the return value of the
C<action> method.  Events are only received while waiting for a
response to an action.  You MUST NOT call any methods on C<$ami> from
inside the callback.
(default: events are ignored)

=back

The constructor throws an exception if a required parameter is
omitted.

=diag C<Required parameter %s not defined>

You omitted a required parameter from a method call.

=cut

sub new {
  my $class = shift;
  my $args = (@_ == 1) ? shift : { @_ };

  my $self = bless {
    Debug_FH => ($args->{Debug_FH} || ($args->{Debug} ? *STDERR : undef)),
    Event_Callback => $args->{Event_Callback},
    Host => $args->{Host} || 'localhost',
    Port => $args->{Port} || 5038,
    ActionID => $args->{ActionID} || 1,
  }, $class;

  for my $key (qw(Username Secret)) {
    defined( $self->{$key} = $args->{$key} )
        or Carp::croak("Required parameter '$key' not defined");
  }

  $self;
} # end new
#---------------------------------------------------------------------

=method connect

  $success = $ami->connect;

Opens the connection to Asterisk and logs in.
C<$success> is true if the login was successful, or C<undef> on error.
On failure, you can get the error message with C<< $ami->error >>.

=cut

sub connect {
  my $self = shift;

  # Open a socket to Asterisk.
  #   IO::Socket::IP->new reports error in $@
  local $@;

  $self->{socket} = IO::Socket::IP->new(
    Type => IO::Socket::IP::SOCK_STREAM(),
    PeerHost => $self->{Host},
    PeerService => $self->{Port},
  );

  unless ($self->{socket}) {
    $self->{error} = "Connection failed: $@";
    return undef;
  }

  # Automatically log in using Username/Secret
  my $response = $self->action({
    Action => 'Login',
    Username => $self->{Username},
    Secret => $self->{Secret},
  });

  # If login failed, set error
  unless ($response->{Response} eq 'Success') {
    $self->{error} = "Login failed: $response->{Message}";
    return undef;
  }

  # Login successful
  1;
} # end connect
#---------------------------------------------------------------------

=method action

  $response = $ami->action(%args);

Sends an action request to Asterisk and returns the response.  The
C<%args> may be passed as a hashref or a list of S<C<< key => value
>>> pairs.

The only required key is C<Action>.  (Asterisk may require other keys
depending on the value of C<Action>, but that is not enforced by this
module.)

The C<$response> is a hashref formed from Asterisk's response.  It
will have a C<Response> key whose value is either C<Success> or
C<Error>.

If communication with Asterisk fails, it will return a manufactured
Error response with Message "Writing to socket failed: %s" or
"Reading from socket failed: %s".  In this case, C<< $ami->error >>
will also be set.

=cut

sub action {
  my $self = shift;
  my $act = (@_ == 1) ? shift : { @_ };

  Carp::croak("Required parameter 'Action' not defined") unless $act->{Action};

  # Assemble the message to send to Asterisk
  my $debug_fh = $self->{Debug_FH};
  my $socket = $self->{socket};
  my $id = $self->{ActionID}++;
  my $message = "ActionID: $id$EOL";

  for my $key (sort keys %$act) {
    if (ref $act->{$key}) {
      $message .= "$key: $_$EOL" for @{ $act->{$key} };
    } else {
      $message .= "$key: $act->{$key}$EOL";
    }
  }

  $message .= $EOL;             # Message ends with blank line

  # If debugging, print out the message before sending it
  if ($debug_fh) {
    my $debug = $message;
    $debug =~ s/\r//g;
    $debug =~ s/^/>> /mg;
    print $debug_fh $debug;
  }

  # Send the request to Asterisk
  unless (print $socket $message) {
    return {
      Response => 'Error',
      Message => $self->{error} = "Writing to socket failed: $!",
    };
  }

  # Read responses until we get the response to this action
  local $/ = $EOL;
  while (1) {
    my %response;
    my $line;
    undef $!;

    # Read a response terminated by a blank line
    while ($line = <$socket>) {
      chomp $line;
      print $debug_fh "<< $line\n" if $debug_fh;

      last unless length $line;

      # Remove the key from the "Key: Value" line
      # If the line is not in that format, ignore it.
      $line =~ s/^([^:]+): // or next;

      if (not exists $response{$1}) {
        # First occurrence of this key, save as string
        $response{$1} = $line;
      } elsif (ref $response{$1}) {
        # Third or more occurrence of this key, append to arrayref
        push @{ $response{$1} }, $line;
      } else {
        # Second occurrence of this key, convert to arrayref
        $response{$1} = [ $response{$1}, $line ];
      }
    }

    # If this is the response to the action we just sent,
    # return it.
    if (($response{ActionID} || '') eq $id) {
      return \%response;
    }

    # If there was a communication failure, return an error.
    if (!defined($line) && $!) {
      return {
        Response => 'Error',
        Message => $self->{error} = "Reading from socket failed: $!",
      };
    }

    # If there is an event callback, send it this event
    if ($self->{Event_Callback}) {
      $self->{Event_Callback}->(\%response);
    }
  } # end infinite loop waiting for response
} # end action
#---------------------------------------------------------------------

=method error

  $error_message = $ami->error;

If communication with Asterisk fails, this method will return an error
message describing the problem.

If Asterisk returns "Response: Error" for some action, that does not
set C<< $ami->error >>.  The one exception is the automatic Login action
performed by the L</connect> method, which does set C<error> on failure.

It returns C<undef> if there has been no communication error.

=cut

sub error { shift->{error} }

#=====================================================================
# Package Return Value:

1;

__END__

=head1 SYNOPSIS

  use Telephony::Asterisk::AMI ();

  my $ami = Telephony::Asterisk::AMI->new(
    Username => 'user',
    Secret => 'password',
  );

  $ami->connect or die $ami->error;

  my $response = $ami->action(Action => 'Ping');

  $ami->action(Action => 'Logoff');


=head1 DESCRIPTION

Telephony::Asterisk::AMI is a simple client for the Asterisk Manager
Interface.  It's better documented and less buggy than
L<Asterisk::Manager>, and has fewer prerequisites than
L<Asterisk::AMI>.  It uses L<IO::Socket::IP>, so it should support
either IPv4 or IPv6.

If you need a more sophisticated client (especially for use in an
event-driven program), try Asterisk::AMI.


=head1 SEE ALSO

L<https://wiki.asterisk.org/wiki/display/AST/Home>

L<Asterisk::AMI> is a more sophisticated AMI client better suited for
event-driven programs.

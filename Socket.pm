######################################################################
# Base class for all socket types
######################################################################

package Danga::Socket;
use strict;

use vars qw{$VERSION};
$VERSION = do { my @r = (q$Revision$ =~ /\d+/g); sprintf "%d."."%02d" x $#r, @r };

use fields qw(sock fd write_buf write_buf_offset write_buf_size
          read_buf read_ahead read_size
          closed event_watch debug_level);

use Errno qw(EINPROGRESS EWOULDBLOCK EISCONN
             EPIPE EAGAIN EBADF ECONNRESET);

use Socket qw(IPPROTO_TCP);
use Carp qw{croak confess};

use constant TCP_CORK => 3; # FIXME: not hard-coded (Linux-specific too)

use constant DebugLevel => 0;

# for epoll definitions:
require 'syscall.ph';

# Explicitly define the poll constants, as either one set or the other won't be
# loaded. They're also badly implemented in IO::Epoll:
# The IO::Epoll module is buggy in that it doesn't export constants efficiently
# (at least as of 0.01), so doing constants ourselves saves 13% of the user CPU
# time
use constant EPOLLIN       => 1;
use constant EPOLLOUT      => 4;
use constant EPOLLERR      => 8;
use constant EPOLLHUP      => 16;
use constant EPOLL_CTL_ADD => 1;
use constant EPOLL_CTL_DEL => 2;
use constant EPOLL_CTL_MOD => 3;

use constant POLLIN        => 1;
use constant POLLOUT       => 4;
use constant POLLERR       => 8;
use constant POLLHUP       => 16;

# keep track of active clients
our (
    $HaveEpoll,                 # Flag -- is epoll available?  initially undefined.
    %DescriptorMap,             # fd (num) -> Danga::Socket object
    $Poll,                      # Global poll object (for IO::Poll only)
    $Epoll,                     # Global epoll fd (for epoll mode only)
    @ToClose,                   # sockets to close when event loop is done
    %OtherFds,                  # A hash of "other" (non-Danga::Socket) file
                                # descriptors for the event loop to track.
);

%OtherFds = ();

#####################################################################
### C L A S S   M E T H O D S
#####################################################################

### (CLASS) METHOD: HaveEpoll()
### Returns a true value if this class will use IO::Epoll for async IO.
sub HaveEpoll { $HaveEpoll };

### (CLASS) METHOD: WatchedSockets()
### Returns the number of file descriptors which are registered with the global
### poll object.
sub WatchedSockets {
    return scalar keys %DescriptorMap;
}
*watched_sockets = *WatchedSockets;


### (CLASS) METHOD: ToClose()
### Return the list of sockets that are awaiting close() at the end of the
### current event loop.
sub ToClose { return @ToClose; }


### (CLASS) METHOD: OtherFds( [%fdmap] )
### Get/set the hash of file descriptors that need processing in parallel with
### the registered Danga::Socket objects.
sub OtherFds {
    my $class = shift;
    if ( @_ ) { %OtherFds = @_ }
    return wantarray ? %OtherFds : \%OtherFds;
}


### (CLASS) METHOD: DescriptorMap()
### Get the hash of Danga::Socket objects keyed by the file descriptor they are
### wrapping.
sub DescriptorMap {
    return wantarray ? %DescriptorMap : \%DescriptorMap;
}
*descriptor_map = *DescriptorMap;
*get_sock_ref = *DescriptorMap;


### FUNCTION: EventLoop()
### Start processing IO events.
sub EventLoop { die "Placeholder eventloop not replaced." }


### The epoll-based event loop. Gets installed as EventLoop if IO::Epoll loads
### okay.
sub EpollEventLoop {
    my $class = shift;

    foreach my $fd ( keys %OtherFds ) {
        epoll_ctl($Epoll, EPOLL_CTL_ADD, $fd, EPOLLIN);
    }

    while (1) {
        my @events;
        my $i;
        my $evcount;
        # get up to 1000 events, no timeout (-1)
        while ($evcount = epoll_wait($Epoll, 1000, -1, \@events)) {
          EVENT:
            for ($i=0; $i<$evcount; $i++) {
                my $ev = $events[$i];

                # it's possible epoll_wait returned many events, including some at the end
                # that ones in the front triggered unregister-interest actions.  if we
                # can't find the %sock entry, it's because we're no longer interested
                # in that event.
                my Danga::Socket $pob = $DescriptorMap{$ev->[0]};
                my $code;

                # if we didn't find a Perlbal::Socket subclass for that fd, try other
                # pseudo-registered (above) fds.
                if (! $pob) {
                    if (my $code = $OtherFds{$ev->[0]}) {
                        $code->();
                    }
                    next;
                }

                DebugLevel >= 1 && $class->DebugMsg("Event: fd=%d (%s), state=%d \@ %s\n",
                                                    $ev->[0], ref($pob), $ev->[1], time);

                my $state = $ev->[1];
                $pob->event_read   if $state & EPOLLIN && ! $pob->{closed};
                $pob->event_write  if $state & EPOLLOUT && ! $pob->{closed};
                if ($state & (EPOLLERR|EPOLLHUP)) {
                    $pob->event_err    if $state & EPOLLERR && ! $pob->{closed};
                    $pob->event_hup    if $state & EPOLLHUP && ! $pob->{closed};
                }
            }

            # now we can close sockets that wanted to close during our event processing.
            # (we didn't want to close them during the loop, as we didn't want fd numbers
            #  being reused and confused during the event loop)
            $_->close while ($_ = shift @ToClose);
        }
        print STDERR "Event loop ending; restarting.\n";
    }
    exit 0;
}


### The fallback IO::Poll-based event loop. Gets installed as EventLoop if
### IO::Epoll fails to load.
sub PollEventLoop {
    my $class = shift;

    my Danga::Socket $pob;
    my $fd;

    $Poll ||= new IO::Poll or
        die "# fail: new IO::Poll: $!\n";
    DebugLevel >= 1 && $class->DebugMsg("Using IO::Poll object for PollEventLoop: %s\n", $Poll);

    foreach my $fd ( keys %OtherFds ) {
        my $handle = IO::Handle->new_from_fd( $fd, "r" );
        $Poll->mask( $handle, POLLIN );
    }

    my $count;
  POLL: while (( $count = $Poll->poll )) {
        next POLL unless $count;

        # Fetch handles with read events
        foreach my $handle ( $Poll->handles(POLLIN) ) {
            $fd = fileno $handle;
            $pob = $DescriptorMap{$fd};

            if ( !$pob && (my $code = $OtherFds{$fd}) ) {
                $code->();
                next;
            }

            $pob->event_read unless $pob->{closed};
        }

        # Write events
        foreach my $handle ( $Poll->handles(POLLOUT) ) {
            $fd = fileno $handle;
            $pob = $DescriptorMap{$fd};
            $pob->event_write unless $pob->{closed};
        }

        # Error events
        foreach my $handle ( $Poll->handles(POLLERR) ) {
            $fd = fileno $handle;
            $pob = $DescriptorMap{$fd};
            $pob->event_err unless $pob->{closed};
        }

        # Hangup events
        foreach my $handle ( $Poll->handles(POLLHUP) ) {
            $fd = fileno $handle;
            $pob = $DescriptorMap{$fd};
            $pob->event_hup unless $pob->{closed};
        }


        # now we can close sockets that wanted to close during our event processing.
        # (we didn't want to close them during the loop, as we didn't want fd numbers
        #  being reused and confused during the event loop)
        my $sock;
        $sock->close while( $sock = shift @ToClose );
    }

    DebugLevel >= 1 && $class->DebugMsg("Poll error on %s", $Poll);
    exit 0;
}


### (CLASS) METHOD: DebugMsg( $format, @args )
### Print the debugging message specified by the C<sprintf>-style I<format> and
### I<args>
sub DebugMsg {
    my ( $class, $fmt, @args ) = @_;
    chomp $fmt;
    printf STDERR ">>> $fmt\n", @args;
}


### METHOD: new( $socket )
### Create a new Danga::Socket object for the given I<socket> which will react
### to events on it during the C<wait_loop>.
sub new {
    my Danga::Socket $self = shift;
    $self = fields::new($self) unless ref $self;

    my $sock = shift;

    $self->{sock}        = $sock;
    my $fd = fileno($sock);
    $self->{fd}          = $fd;
    $self->{write_buf}      = [];
    $self->{write_buf_offset} = 0;
    $self->{write_buf_size} = 0;
    $self->{closed} = 0;

    $self->{event_watch} = POLLERR|POLLHUP;

    # Make the poll object if it hasn't been already
    unless (defined $HaveEpoll) {
        $Epoll = eval { epoll_create(1024); };
        $HaveEpoll = $Epoll >= 0;
        if ($HaveEpoll) {
            *EventLoop = *EpollEventLoop;            
        } else {
            require IO::Poll;
            $Poll = new IO::Poll or
                die "# fail: new IO::Poll: $!\n";
            *EventLoop = *PollEventLoop;
        }
    }

    if ($HaveEpoll) {
        epoll_ctl($Epoll, EPOLL_CTL_ADD, $fd, $self->{event_watch})
            and die "couldn't add epoll watch for $fd\n";

    } else {
        $Poll->mask( $sock, $self->{event_watch} )
            or die "couldn't add poll watch for $fd\n";
    }

    $DescriptorMap{$fd} = $self;
    return $self;
}



#####################################################################
### I N S T A N C E   M E T H O D S
#####################################################################

### METHOD: tcp_cork( $boolean )
### Turn TCP_CORK on or off depending on the value of I<boolean>.
sub tcp_cork {
    my Danga::Socket $self = shift;
    my $val = shift;

    setsockopt($self->{sock}, IPPROTO_TCP, TCP_CORK,
           pack("l", $val ? 1 : 0))   || die "setsockopt: $!";
}

### METHOD: close( [$reason] )
### Close the socket. The I<reason> argument will be used in debugging messages.
sub close {
    my Danga::Socket $self = shift;
    my $reason = shift || "";

    my $fd = $self->{fd};
    my $sock = $self->{sock};
    $self->{closed} = 1;

    # we need to flush our write buffer, as there may
    # be self-referential closures (sub { $client->close })
    # preventing the object from being destroyed
    $self->{write_buf} = [];

    if (DebugLevel) {
        my ($pkg, $filename, $line) = caller;
        print STDERR "Closing \#$fd due to $pkg/$filename/$line ($reason)\n";
    }

    if ($HaveEpoll) {
        if (epoll_ctl($Epoll, EPOLL_CTL_DEL, $fd, $self->{event_watch}) == 0) {
            DebugLevel >= 1 && $self->debugmsg("Client %d disconnected.\n", $fd);
        } else {
            DebugLevel >= 1 && $self->debugmsg("poll->remove failed on fd %d\n", $fd);
        }
    } else {
        $Poll->remove( $self->{sock} ); # Return value is useless
    }

    delete $DescriptorMap{$fd};

    # defer closing the actual socket until the event loop is done
    # processing this round of events.  (otherwise we might reuse fds)
    push @ToClose, $sock;

    return 0;
}



### METHOD: sock()
### Returns the underlying IO::Handle for the object.
sub sock {
    my Danga::Socket $self = shift;
    return $self->{sock};
}


### METHOD: write( $data )
### Write the specified data to the underlying handle.  I<data> may be scalar,
### scalar ref, code ref (to run when there), or undef just to kick-start.
### Returns 1 if writes all went through, or 0 if there are writes in queue. If
### it returns 1, caller should stop waiting for 'writable' events)
sub write {
    my Danga::Socket $self;
    my $data;
    ($self, $data) = @_;

    # nobody should be writing to closed sockets, but caller code can
    # do two writes within an event, have the first fail and
    # disconnect the other side (whose destructor then closes the
    # calling object, but it's still in a method), and then the
    # now-dead object does its second write.  that is this case.  we
    # just lie and say it worked.  it'll be dead soon and won't be
    # hurt by this lie.
    return 1 if $self->{closed};

    my $bref;

    # just queue data if there's already a wait
    my $need_queue;

    if (defined $data) {
        $bref = ref $data ? $data : \$data;
        if ($self->{write_buf_size}) {
            push @{$self->{write_buf}}, $bref;
            $self->{write_buf_size} += ref $bref eq "SCALAR" ? length($$bref) : 1;
            return 0;
        }

        # this flag says we're bypassing the queue system, knowing we're the
        # only outstanding write, and hoping we don't ever need to use it.
        # if so later, though, we'll need to queue
        $need_queue = 1;
    }

  WRITE:
    while (1) {
        return 1 unless $bref ||= $self->{write_buf}[0];

        my $len;
        eval {
            $len = length($$bref); # this will die if $bref is a code ref, caught below
        };
        if ($@) {
            if (ref $bref eq "CODE") {
                unless ($need_queue) {
                    $self->{write_buf_size}--; # code refs are worth 1
                    shift @{$self->{write_buf}};
                }
                $bref->();
                undef $bref;
                next WRITE;
            }
            die "Write error: $@";
        }

        my $to_write = $len - $self->{write_buf_offset};
        my $written = syswrite($self->{sock}, $$bref, $to_write, $self->{write_buf_offset});

        if (! defined $written) {
            if ($! == EPIPE) {
                return $self->close("EPIPE");
            } elsif ($! == EAGAIN) {
                # since connection has stuff to write, it should now be
                # interested in pending writes:
                if ($need_queue) {
                    push @{$self->{write_buf}}, $bref;
                    $self->{write_buf_size} += $len;
                }
                $self->watch_write(1);
                return 0;
            } elsif ($! == ECONNRESET) {
                return $self->close("ECONNRESET");
            }

            DebugLevel >= 1 && $self->debugmsg("Closing connection ($self) due to write error: $!\n");

            return $self->close("write_error");
        } elsif ($written != $to_write) {
            DebugLevel >= 2 && $self->debugmsg("Wrote PARTIAL %d bytes to %d",
                                               $written, $self->{fd});
            if ($need_queue) {
                push @{$self->{write_buf}}, $bref;
                $self->{write_buf_size} += $len;
            }
            # since connection has stuff to write, it should now be
            # interested in pending writes:
            $self->{write_buf_offset} += $written;
            $self->{write_buf_size} -= $written;
            $self->watch_write(1);
            return 0;
        } elsif ($written == $to_write) {
            DebugLevel >= 2 && $self->debugmsg("Wrote ALL %d bytes to %d (nq=%d)",
                                               $written, $self->{fd}, $need_queue);
            $self->{write_buf_offset} = 0;

            # this was our only write, so we can return immediately
            # since we avoided incrementing the buffer size or
            # putting it in the buffer.  we also know there
            # can't be anything else to write.
            return 1 if $need_queue;

            $self->{write_buf_size} -= $written;
            shift @{$self->{write_buf}};
            undef $bref;
            next WRITE;
        }
    }
}


### METHOD: read( $bytecount )
### Read at most I<bytecount> bytes from the underlying handle; returns scalar
### ref on read, or undef on connection closed.
sub read {
    my Danga::Socket $self = shift;
    my $bytes = shift;
    my $buf;
    my $sock = $self->{sock};

    my $res = sysread($sock, $buf, $bytes, 0);
    DebugLevel >= 2 && $self->debugmsg("sysread = %d; \$! = %d", $res, $!);

    if (! $res && $! != EWOULDBLOCK) {
        # catches 0=conn closed or undef=error
        DebugLevel >= 2 && $self->debugmsg("Fd \#%d read hit the end of the road.", $self->{fd});
        return undef;
    }

    return \$buf;
}


### METHOD: drain_read_buf_to( $destination )
### Write read-buffered data (if any) from the receiving object to the
### I<destination> object.
sub drain_read_buf_to {
    my ($self, $dest) = @_;
    return unless $self->{read_ahead};

    DebugLevel >= 2 && $self->debugmsg("drain_read_buf_to (%d -> %d): %d bytes",
                                       $self->{fd}, $dest->{fd}, $self->{read_ahead});

    while (my $bref = shift @{$self->{read_buf}}) {
        $dest->write($bref);
        $self->{read_ahead} -= length($$bref);
    }
}


### (VIRTUAL) METHOD: event_read()
### Readable event handler. Concrete deriviatives of Danga::Socket should
### provide an implementation of this. The default implementation will die if
### called.
sub event_read  { die "Base class event_read called for $_[0]\n"; }


### (VIRTUAL) METHOD: event_err()
### Error event handler. Concrete deriviatives of Danga::Socket should
### provide an implementation of this. The default implementation will die if
### called.
sub event_err   { die "Base class event_err called for $_[0]\n"; }


### (VIRTUAL) METHOD: event_hup()
### 'Hangup' event handler. Concrete deriviatives of Danga::Socket should
### provide an implementation of this. The default implementation will die if
### called.
sub event_hup   { die "Base class event_hup called for $_[0]\n"; }


### METHOD: event_write()
### Writable event handler. Concrete deriviatives of Danga::Socket may wish to
### provide an implementation of this. The default implementation calls
### C<write()> with an C<undef>.
sub event_write {
    my $self = shift;
    $self->write(undef);
}


### METHOD: watch_read( $boolean )
### Turn 'readable' event notification on or off.
sub watch_read {
    my Danga::Socket $self = shift;
    return if $self->{closed};

    my $val = shift;
    my $event = $self->{event_watch};
    $event &= ~POLLIN if ! $val;
    $event |=  POLLIN if   $val;

    # If it changed, set it
    if ($event != $self->{event_watch}) {
        if ($HaveEpoll) {
            epoll_ctl($Epoll, EPOLL_CTL_MOD, $self->{fd}, $event)
                and print STDERR "couldn't modify epoll settings for $self->{fd} " .
                "($self) from $self->{event_watch} -> $event\n";
        } else {
            $Poll->mask( $self->{sock}, $event )
                or print STDERR "couldn't modify epoll settings for $self->{fd} " .
                "($self) from $self->{event_watch} -> $event\n";
        }
        $self->{event_watch} = $event;
    }
}


### METHOD: watch_read( $boolean )
### Turn 'writable' event notification on or off.
sub watch_write {
    my Danga::Socket $self = shift;
    return if $self->{closed};

    my $val = shift;
    my $event = $self->{event_watch};
    $event &= ~POLLOUT if ! $val;
    $event |=  POLLOUT if   $val;

    # If it changed, set it
    if ($event != $self->{event_watch}) {
        if ($HaveEpoll) {
            epoll_ctl($Epoll, EPOLL_CTL_MOD, $self->{fd}, $event)
                and print STDERR "couldn't modify epoll settings for $self->{fd} " .
                "($self) from $self->{event_watch} -> $event\n";
        } else {
            $Poll->mask( $self->{sock}, $event )
                or print STDERR "couldn't modify epoll settings for $self->{fd} ".
                "($self) from $self->{event_watch} -> $event\n";
        }
        $self->{event_watch} = $event;
    }
}


### METHOD: debugmsg( $format, @args )
### Print the debugging message specified by the C<sprintf>-style I<format> and
### I<args> if the object's C<debug_level> is greater than or equal to the given
### I<level>.
sub debugmsg {
    my ( $self, $fmt, @args ) = @_;
    confess "Not an object" unless ref $self;

    chomp $fmt;
    printf STDERR ">>> $fmt\n", @args;
}


### METHOD: peer_addr_string()
### Returns the string describing the peer for the socket which underlies this
### object.
sub peer_addr_string {
    my Danga::Socket $self = shift;
    my $pn = getpeername($self->{sock}) or return undef;
    my ($port, $iaddr) = Socket::sockaddr_in($pn);
    return Socket::inet_ntoa($iaddr) . ":$port";
}

### METHOD: as_string()
### Returns a string describing this socket.
sub as_string {
    my Danga::Socket $self = shift;
    my $ret = ref($self) . ": " . ($self->{closed} ? "closed" : "open");
    my $peer = $self->peer_addr_string;
    if ($peer) {
        $ret .= " to " . $self->peer_addr_string;
    }
    return $ret;
}

#####################################################################
### U T I L I T Y   F U N C T I O N S
#####################################################################

# epoll_create wrapper
# ARGS: (size)
sub epoll_create {
    syscall(&SYS_epoll_create, $_[0]);
}

# epoll_ctl wrapper
# ARGS: (epfd, op, fd, events)
sub epoll_ctl {
    syscall(&SYS_epoll_ctl, $_[0]+0, $_[1]+0, $_[2]+0, pack("LLL", $_[3], $_[2]));
}

# epoll_wait wrapper
# ARGS: (epfd, maxevents, timeout, arrayref)
#  arrayref: values modified to be [$fd, $event]
our $epoll_wait_events;
our $epoll_wait_size = 0;
sub epoll_wait {
    # resize our static buffer if requested size is bigger than we've ever done
    if ($_[1] > $epoll_wait_size) {
        $epoll_wait_size = $_[1];
        $epoll_wait_events = pack("LLL") x $epoll_wait_size;
    }
    my $ct = syscall(&SYS_epoll_wait, $_[0]+0, $epoll_wait_events, $_[1]+0, $_[2]+0);
    for ($_ = 0; $_ < $ct; $_++) {
        @{$_[3]->[$_]}[1,0] = unpack("LL", substr($epoll_wait_events, 12*$_, 8));
    }
    return $ct;
}



1;


# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
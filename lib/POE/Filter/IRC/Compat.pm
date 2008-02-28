package POE::Filter::IRC::Compat;

use strict;
use warnings;
use Carp;
use POE::Filter::IRCD;
use File::Basename ();
use base qw(POE::Filter);
use vars qw($VERSION);

$VERSION = '1.3';

sub new {
    my ($package, %params) = @_;
    
    $params{lc $_} = delete $params{$_} for keys %params;
    $params{BUFFER} = [ ];
    $params{_ircd} = POE::Filter::IRCD->new();
    $params{chantypes} = [ '#', '&' ] if ref $params{chantypes} ne 'ARRAY';
    $params{commands} = {
        qr/^\d{3,3}$/ => sub {
            my ($self, $event, $line) = @_;
            $event->{args}->[0] = _decolon( $line->{prefix} );
            shift @{ $line->{params} };
            if ( $line->{params}->[0] && $line->{params}->[0] =~ /\s+/ ) {
                $event->{args}->[1] = $line->{params}->[0];
            }
            else {
                $event->{args}->[1] = join(' ', ( map { /\s+/ ? ":$_" : $_ } @{ $line->{params} } ) );
            }
            $event->{args}->[2] = $line->{params};
        },
        qr/notice/ => sub {
            my ($self, $event, $line) = @_;
            if ($line->{prefix}) {
                $event->{args} = [ _decolon( $line->{prefix} ), [split /,/, $line->{params}->[0]], $line->{params}->[1] ];
            }
            else {
                $event->{name} = 'snotice';
                $event->{args}->[0] = $line->{params}->[1];
            }
        },
        qr/privmsg/ => sub {
            my ($self, $event, $line) = @_;
            if ( grep { index( $line->{params}->[0], $_ ) >= 0 } @{ $self->{chantypes} } ) {
                $event->{args} = [ _decolon( $line->{prefix} ), [split /,/, $line->{params}->[0]], $line->{params}->[1] ];
                $event->{name} = 'public';
            }
            else {
                $event->{args} = [ _decolon( $line->{prefix} ), [split /,/, $line->{params}->[0]], $line->{params}->[1] ];
                $event->{name} = 'msg';
            }
        },
        qr/invite/ => sub {
            my ($self, $event, $line) = @_;
            shift( @{ $line->{params} } );
            unshift( @{ $line->{params} }, _decolon( $line->{prefix} || '' ) ) if $line->{prefix};
            $event->{args} = $line->{params};
        },
    };
  
    return bless \%params, $package;
}

# Set/clear the 'debug' flag.
sub debug {
    my ($self, $flag) = @_;
    if (defined $flag) {
        $self->{debug} = $flag;
        $self->{_ircd}->debug($flag);
    }
    return $self->{debug};
}

sub chantypes {
    my ($self, $ref) = @_;
    return if ref $ref ne 'ARRAY' || !scalar @{ $ref };
    $self->{chantypes} = $ref;
    return 1;
}

sub get {
    my ($self, $raw_lines) = @_;
    my $events = [ ];

    LINE: for my $line (@$raw_lines) {
        if (ref $line ne 'HASH' || !$line->{command} || !$line->{params}) {
            warn "Received line '$line' that is not IRC protocol\n" if $self->{debug};
            next LINE;
        }
    
        my $event = {
            name     => lc $line->{command},
            raw_line => $line->{raw_line},
        };
    
        if ( $line->{raw_line} =~ tr/\001// ) {
            push @$events, @{ $self->_get_ctcp( [ $line->{raw_line} ] ) };
            next LINE;
        }
            
        for my $cmd (keys %{ $self->{commands} }) {
            if ($event->{name} =~ $cmd) {
                $self->{commands}->{$cmd}->($self, $event, $line);
                push @$events, $event;
                next LINE;
            }
        }
    
        # default
        unshift( @{ $line->{params} }, _decolon( $line->{prefix} || '' ) ) if $line->{prefix};
        $event->{args} = $line->{params};
        push @$events, $event;
    }
  
    return $events;
}

sub _get_ctcp {
    my ($self, $line) = @_;
    my ($who, $type, $where, $ctcp, $text) = _ctcp_dequote( $line );

    my $events = [ ];
    my ($name, $args);
    CTCP: for my $string (@$ctcp) {
        if (!(($name, $args) = $string =~ /^(\w+)(?: (.*))?/)) {
            warn "Received malformed CTCP message: '$string'\n" if $self->{debug};
            last CTCP;
        }
            
        if (lc $name eq 'dcc') {
            my ($type, $file, $addr, $port, $size);
            
            if (!(($type, $file, $addr, $port, $size)
                = $args =~ /^(\w+) (".+"|\S+) (\d+) (\d+)(?: (\d+))?$/)) {
                warn "Received malformed DCC request: '$args'\n" if $self->{debug};
                last CTCP;
            }
            $file =~ s/^"|"$//g;
            $file = File::Basename::fileparse($file);
                
            push @$events, {
                name => 'dcc_request',
                args => [
                    $who,
                    uc $type,
                    $port,
                    {
                        open => undef,
                        nick => $who,
                        type => uc $type,
                        file => $file,
                        size => $size,
                        done => 0,
                        addr => $addr,
                        port => $port,
                    },
                    $file,
                    $size,
                ],
                raw_line => $line,
            };
        }
        else {
            push @$events, {
                name => $type . '_' . lc $name,
                args => [
                    $who,
                    [split /,/, $where],
                    (defined $args ? $args : ''),
                ],
                raw_line => $line,
            };
        }
    }

    if ($text && scalar @$text) {
        my $what;
        ($what) = $line =~ /^(:\S+ +\w+ +\S+ +)/
            or warn "What the heck? '$line'\n" if $self->{debug};
        $text = (defined $what ? $what : '') . ':' . join '', @$text;
        $text =~ s/\cP/^P/g;
        warn "CTCP: $text\n" if $self->{debug};
        push @$events, @{ $self->{_ircd}->get([$text]) };
    }
    
    return $events;
}

sub get_one_start {
    my ($self, $raw_lines) = @_;

    for my $line (@$raw_lines) {
        push ( @{ $self->{BUFFER} }, $line );
    }
    return;
}

sub get_one {
    my ($self) = @_;

    my $events = $self->get($self->{BUFFER});
    $self->{BUFFER} = [ ];
    return $events;
}

sub clone {
    my $self = shift;
    my $nself = { };
    $nself->{$_} = $self->{$_} for keys %{ $self };
    $nself->{BUFFER} = [ ];
    return bless $nself, ref $self;
}

sub _decolon {
    my ($line) = @_;

    $line =~ s/^://;
    return $line;
}

# Quotes a string in a low-level, protocol-safe, utterly brain-dead
# fashion. Returns the quoted string.
sub _low_quote {
    my ($line) = @_;
    my %enquote = ("\012" => 'n', "\015" => 'r', "\0" => '0', "\cP" => "\cP");

    if (!defined $line) {
        croak 'Not enough arguments to POE::Filter::IRC::Compat->_low_quote';
    }

    if ($line =~ tr/[\012\015\0\cP]//) { # quote \n, \r, ^P, and \0.
        $line =~ s/([\012\015\0\cP])/\cP$enquote{$1}/g;
    }

    return $line;
}

# Does low-level dequoting on CTCP messages. I hate this protocol.
# Yes, I copied this whole section out of Net::IRC.
sub _low_dequote {
    my ($line) = @_;
    my %dequote = (n => "\012", r => "\015", 0 => "\0", "\cP" => "\cP");

    if (!defined $line) {
        croak 'Not enough arguments to POE::Filter::IRC::Compat->_low_dequote';
    }

    # dequote \n, \r, ^P, and \0.
    # Thanks to Abigail (abigail@foad.org) for this clever bit.
    if ($line =~ tr/\cP//) {
        $line =~ s/\cP([nr0\cP])/$dequote{$1}/g;
    }

    return $line;
}


# Properly CTCP-quotes a message. Whoop.
sub _ctcp_quote {
    my ($line) = @_;

    $line = _low_quote( $line );
    #$line =~ s/\\/\\\\/g;
    $line =~ s/\001/\\a/g;

    return "\001$line\001";
}

# Splits a message into CTCP and text chunks. This is gross. Most of
# this is also stolen from Net::IRC, but I (fimm) wrote that too, so it's
# used with permission. ;-)
sub _ctcp_dequote {
    my ($line) = @_;
    my (@chunks, $ctcp, $text, $who, $type, $where, $msg);

    # CHUNG! CHUNG! CHUNG!

    if (!defined $line) {
        croak 'Not enough arguments to POE::Filter::IRC::Compat->_ctcp_dequote';
    }

    # Strip out any low-level quoting in the text.
    $line = _low_dequote( $line );

    # Filter misplaced \001s before processing... (Thanks, tchrist!)
    substr($line, rindex($line, "\001"), 1, '\\a')
        if ($line =~ tr/\001//) % 2 != 0;

    return if $line !~ tr/\001//;

    ($who, $type, $where, $msg) = ($line =~ /^:(\S+) +(\w+) +(\S+) +:?(.*)$/)
        or return;
    
    @chunks = split /\001/, $msg;
    shift @chunks if !length $chunks[0]; # FIXME: Is this safe?

    for (@chunks) {
        # Dequote unnecessarily quoted chars, and convert escaped \'s and ^A's.
        s/\\([^\\a])/$1/g;
        s/\\\\/\\/g;
        s/\\a/\001/g;
    }

    # If the line begins with a control-A, the first chunk is a CTCP
    # message. Otherwise, it starts with text and alternates with CTCP
    # messages. Really stupid protocol.
    if ($msg =~ /^\001/) {
        push @$ctcp, shift @chunks;
    }

    while (@chunks) {
        push @$text, shift @chunks;
        push @$ctcp, shift @chunks if @chunks;
    }

    # Is this a CTCP request or reply?
    $type = $type eq 'PRIVMSG' ? 'ctcp' : 'ctcpreply';

    return ($who, $type, $where, $ctcp, $text);
}

sub put {
    my ($self, $lineref) = @_;
    my $quoted = [ ];
    push @$quoted, _ctcp_quote($_) for @$lineref;
    return $quoted;
}

1;
__END__

=head1 NAME

POE::Filter::IRC::Compat - A filter which converts L<POE::Filter::IRCD|POE::Filter::IRCD>
output into L<POE::Component::IRC|POE::Component::IRC> events.

=head1 DESCRIPTION

POE::Filter::IRC::Compat is a L<POE::Filter|POE::Filter> that converts
L<POE::Filter::IRCD|POE::Filter::IRCD> output into the L<POE::Component::IRC|POE::Component::IRC>
compatible event references. Basically a hack, so I could replace
L<POE::Filter::IRC|POE::Filter::IRC> with something that was more
generic.

=head1 CONSTRUCTOR

=over

=item C<new>

Returns a POE::Filter::IRC::Compat object.

=back

=head1 METHODS

=over

=item C<get>

Takes an arrayref of L<POE::Filter::IRCD> hashrefs and produces an arrayref of
L<POE::Component::IRC|POE::Component::IRC> compatible event hashrefs. Yay.

=item C<get_one_start>

=item C<get_one>

These perform a similar function as C<get()> but enable the filter to work with
L<POE::Filter::Stackable|POE::Filter::Stackable>.

=item C<chantypes>

Takes an arrayref of possible channel prefix indicators.

=item C<debug>

Takes a true/false value which enables/disables debugging accordingly.
Returns the debug status.

=item C<clone>

Makes a copy of the filter, and clears the copy's buffer.

=item C<put>

Takes an array reference of CTCP messages to be properly quoted. This
doesn't support CTCPs embedded in normal messages, which is a
brain-dead hack in the protocol, so do it yourself if you really need
it. Returns an array reference of the quoted lines for sending.

=back

=head1 AUTHOR

Chris 'BinGOs' Williams

=head1 SEE ALSO

L<POE::Filter::IRCD|POE::Filter::IRCD>

L<POE::Filter|POE::Filter>

L<POE::Filter::Stackable|POE::Filter::Stackable>

=cut

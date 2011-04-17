package POE::Component::IRC::Plugin::BotTraffic;

use strict;
use warnings FATAL => 'all';
use POE::Component::IRC::Plugin qw( :ALL );
use POE::Filter::IRCD;
use POE::Filter::IRC::Compat;

sub new {
    my ($package) = @_;
    return bless { }, $package;
}

sub PCI_register {
    my ($self, $irc) = splice @_, 0, 2;

    $self->{filter} = POE::Filter::IRCD->new();
    $self->{compat} = POE::Filter::IRC::Compat->new();
    $irc->plugin_register( $self, 'USER', qw(privmsg notice) );
    return 1;
}

sub PCI_unregister {
    return 1;
}

sub U_notice {
    my ($self, $irc) = splice @_, 0, 2;
    my $output  = ${ $_[0] };
    my $line    = $self->{filter}->get([ $output ])->[0];
    my $text    = $line->{params}->[1];
    my $targets = [ split(/,/, $line->{params}->[0]) ];

    $irc->send_event_next(irc_bot_notice => $targets => $text);

    return PCI_EAT_NONE;
}

sub U_privmsg {
    my ($self, $irc) = splice @_, 0, 2;
    my $output = ${ $_[0] };
    my $line   = $self->{filter}->get([ $output ])->[0];
    my $text   = $line->{params}->[1];

    if ($text =~ /^\001/) {
        my $ctcp_event = $self->{compat}->get([$line])->[0];
        return PCI_EAT_NONE if $ctcp_event->{name} ne 'ctcp_action';
        $irc->send_event_next(irc_bot_action => @{ $ctcp_event->{args} }[1..2]);
    }
    else {
        my $chantypes = join('', @{ $irc->isupport('CHANTYPES') || ['#', '&']});
        for my $recipient ( split(/,/, $line->{params}->[0]) ) {
            my $event = 'irc_bot_msg';
            $event = 'irc_bot_public' if $recipient =~ /^[$chantypes]/;
            $irc->send_event_next($event => [ $recipient ] => $text);
        }
    }

    return PCI_EAT_NONE;
}

1;

=encoding utf8

=head1 NAME

POE::Component::IRC::Plugin::BotTraffic - A PoCo-IRC plugin that generates
events when you send messages

=head1 SYNOPSIS

 use POE::Component::IRC::Plugin::BotTraffic;

 $irc->plugin_add( 'BotTraffic', POE::Component::IRC::Plugin::BotTraffic->new() );

 sub irc_bot_public {
     my ($kernel, $heap) = @_[KERNEL, HEAP];
     my $channel = $_[ARG0]->[0];
     my $what = $_[ARG1];

     print "I said '$what' on channel $channel\n";
     return;
 }

=head1 DESCRIPTION

POE::Component::IRC::Plugin::BotTraffic is a L<POE::Component::IRC|POE::Component::IRC>
plugin. It watches for when your bot sends PRIVMSGs and NOTICEs to the server
and generates the appropriate events.

These events are useful for logging what your bot says.

=head1 METHODS

=head2 C<new>

No arguments required. Returns a plugin object suitable for feeding to
L<POE::Component::IRC|POE::Component::IRC>'s C<plugin_add> method.

=head1 OUTPUT

These are the events generated by the plugin. Both events have C<ARG0> set
to an arrayref of recipients and C<ARG1> the text that was sent.

=head2 C<irc_bot_public>

C<ARG0> will be an arrayref of recipients. C<ARG1> will be the text sent.

=head2 C<irc_bot_msg>

C<ARG0> will be an arrayref of recipients. C<ARG1> will be the text sent.

=head2 C<irc_bot_action>

C<ARG0> will be an arrayref of recipients. C<ARG1> will be the text sent.

=head2 C<irc_bot_notice>

C<ARG0> will be an arrayref of recipients. C<ARG1> will be the text sent.

=head1 AUTHOR

Chris 'BinGOs' Williams [chris@bingosnet.co.uk]

=head1 SEE ALSO

L<POE::Component::IRC>

=cut

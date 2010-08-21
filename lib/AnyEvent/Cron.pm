package AnyEvent::Cron;
use warnings;
use strict;
use DateTime;
use AnyEvent;
use Any::Moose;

our $VERSION = '0.02';

has after =>
    ( is => 'rw' , isa => 'Int' , default => sub { 0 } );

has interval => 
    ( is => 'rw' , isa => 'Int' , default => sub { 1 } );

has events => 
    ( is =>  'rw' , isa => 'ArrayRef' , default => sub { [  ] } );

has verbose => 
    ( is => 'rw' , isa => 'Bool' , default => sub { 0 } );

has debug =>
    ( is => 'rw' , isa => 'Bool' , default => sub { 0 } );

# TODO:
has ignore_floating =>
    ( is => 'rw',  isa => 'Bool' , default => sub { 0 } );

use Scalar::Util qw(refaddr);

sub create_interval_event {
    my $self = shift;
    my $ref  = shift;
    $ref = {
        %$ref,
        type      => 'interval',
        triggered => 0,
        };
    $ref->{name} ||= 'interval-' . refaddr($ref);
    print "hook interval on: "
            , join( ':', grep {$_} map { $ref->{$_} } qw(hour minute second) ) 
            , "\n" 
            if $self->verbose;
    push @{ $self->events }, $ref;
}

sub delete {
    my $self = shift;
    my $name = shift;
    my @events = @{ $self->events };
    $self->events( [ grep { $_->{name} ne $name } @{ $self->events } ] );
}

sub create_datatime_event {
    my ( $self, $dt, $cb ) = @_;
    push @{ $self->events }, {
        type      => 'datetime',
        triggered => 0,
        datetime  => $dt,
        callback  => $cb,
        name      => 'datetime-'. refaddr($cb),
    };
}

sub add {
    my $self = shift;
    if ( !ref( $_[0] ) && ref( $_[1] ) eq 'CODE' ) {
        my ( $ts_string, $cb ) = @_;

        # TODO: support more format

        # hour:minute
        if ( $ts_string =~ m{^(\d+):(\d+)$} ) {
            my ( $hour, $minute ) = ( $1, $2 );
            $self->create_interval_event( {
                    hour     => $hour,
                    minute   => $minute,
                    callback => $cb,
            } );
        }
        elsif( $ts_string =~ m{^(\d+):(\d+):(\d+)$} ) {
            my ( $hour, $minute ,$second ) = ( $1, $2 , $3 );
            print "hook interval on: $hour $minute $second" if $self->verbose;
            $self->create_interval_event( {
                    hour     => $hour,
                    minute   => $minute,
                    second   => $second,
                    callback => $cb,
            });
        }
        elsif( $ts_string =~ m{(\d+):\*:\*} ) {
            my $hour = $1;
            $self->create_interval_event( { hour => $hour, callback => $cb } );
        }
        elsif( $ts_string =~ m{\*:(\d+):\*} ) {
            my $minute = $1;
            $self->create_interval_event( { minute => $minute, callback => $cb } );
        }
        elsif( $ts_string =~ m{\*:\*:(\d+)} ) {
            my $second = $1;
            $self->create_interval_event( { second => $second, callback => $cb } );
        }
        else {
            warn 'time string format is not supported.';
            return;
        }
    }
    elsif( ref($_[0]) eq 'DateTime' && ref($_[1]) eq 'CODE' ) {
        my ($dt,$cb) = @_;
        $self->create_datatime_event( $dt, $cb );
    }
    else {
        my @es = @_;
        map { $_->{triggered} = 0 } @es;
        push @{ $self->events }, @es;
    }
    return $self;
}



sub _check_interval {
    my ( $self, $e, $dt ) = @_;
    my @keys = qw(hour minute second);
    my $ret  = 1;

    # find all defined columns and compare them with anyevent datetime object.
    map { $e->{$_} != $dt->$_ ? $ret = 0 : undef } grep { defined $e->{$_} } @keys;
    return $ret;
}

sub _call_event {
    my ( $self, $e, $dt ) = @_;
    unless ( $e->{triggered} ) {
        print $e->{name} . " triggered\n" if $self->verbose;
        $e->{callback}->( $self, $e, $dt );
        $e->{triggered} = 1;
    }
}

sub run {
    my $self = shift;
    $self->{w} = AnyEvent->timer (
        after    => $self->after,
        interval => $self->interval,
        cb       => sub {
            # check time
            my $now = AnyEvent->now;
            my $dt = DateTime->from_epoch( epoch => $now );
            print $dt , "\n" if $self->verbose;
            for my $e ( @{ $self->events } ) {
                if( $e->{type} eq 'interval' ) {
                    my $match = $self->_check_interval( $e , $dt );
                    if( $match ) {
                        $self->_call_event( $e , $dt );
                    }
                    else {
                        # reset triggered flag
                        $e->{triggered} = 0 if $e->{triggered} ;
                    }
                }
                elsif( $e->{type} eq 'datetime' ) {
                    # ignore floating
                    if( ! $e->{triggered} 
                            && $dt->month == $e->{datetime}->month
                            && $dt->day == $e->{datetime}->day
                            && $dt->hour == $e->{datetime}->hour
                            && $dt->minute == $e->{datetime}->minute
                            && $dt->second == $e->{datetime}->second
                        )
                    {
                        $self->_call_event( $e , $dt );
                    }
                }
            }
        }
    );
}


1;
__END__

=head1 NAME

AnyEvent::Cron - Crontab in AnyEvent! provide an interface to register event on specified time.

=head1 SYNOPSIS

    my $cron = AnyEvent::Cron->new( 
            verbose => 1,
            debug => 1,
            after => 1,
            interval => 1,
            ignore_floating => 1
    );

    # 00:00 (hour:minute)
    $cron->add("00:00" => sub { warn "zero"; })

        # hour : minute : second 
        ->add( "*:*:10" => sub { })
        ->add( "1:*:*" => sub { })

        ->add( DateTime->now => sub { warn "datetime now" } )
        ->run();

    my $cv = AnyEvent->condvar;
    $cv->recv;

Or:

    $cron->add({  
        type => 'interval',
        second => 0 ,
        triggered => 0,
        callback => sub { 
            warn "SECOND INTERVAL TRIGGERD";
        },
    },{  
        type => 'interval',
        hour => DateTime->now->hour , 
        minute =>  DateTime->now->minute ,
        callback => sub { 
            warn "HOUR+MINUTE INTERVAL TRIGGERD";
        },
    },{  
        type => 'interval',
        hour => DateTime->now->hour ,
        callback => sub { 
            warn "HOUR INTERVAL TRIGGERD";
        },
    },{  
        type => 'interval',
        minute => DateTime->now->minute ,
        callback => sub { 
            warn "MINUTE INTERVAL TRIGGERD";
        },
    },{
        type => 'datetime' ,
        callback => sub { warn "DATETIME TRIGGED"  },
        datetime => (sub { 
                # my $dt = DateTime->now->add_duration( DateTime::Duration->new( minutes => 0 ) );
                my $dt = DateTime->now;
                # $dt->set_second(0);
                # $dt->set_nanosecond(0);
                warn "Next trigger: ", $dt;
                return $dt; })->()
    })->run();


=head1 METHODS

=head2 add( @events )

=head2 add( "12:36" => sub {     } )

=head2 add( DateTime->now => sub {     } )

=head2 create_interval_event

    $cron->create_interval_event({
        hour => $hour,
        minute => $minute,
        callback => $cb,
    });

=head2 create_datatime_event

=head1 AUTHOR

Cornelius, C<< <cornelius.howl_at_gmail.com> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-anyevent-cron at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=AnyEvent-Cron>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc AnyEvent::Cron


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=AnyEvent-Cron>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/AnyEvent-Cron>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/AnyEvent-Cron>

=item * Search CPAN

L<http://search.cpan.org/dist/AnyEvent-Cron/>

=back


=head1 ACKNOWLEDGEMENTS


=head1 LICENSE AND COPYRIGHT

Copyright 2010 Cornelius.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.


=cut

1; # End of AnyEvent::Cron

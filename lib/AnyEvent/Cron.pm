package AnyEvent::Cron;
use warnings;
use strict;
use DateTime;
use AnyEvent;
use Moose;
use Try::Tiny;
use DateTime::Event::Cron;
use v5.12;

our $VERSION = '0.02';


# map of expiration formats to their respective time in seconds
my %_Expiration_Units = ( map(($_,             1), qw(s second seconds sec)),
                          map(($_,            60), qw(m minute minutes min)),
                          map(($_,         60*60), qw(h hour hours)),
                          map(($_,      60*60*24), qw(d day days)),
                          map(($_,    60*60*24*7), qw(w week weeks)),
                          map(($_,   60*60*24*30), qw(M month months)),
                          map(($_,  60*60*24*365), qw(y year years)) );

has run_after =>
    is => 'rw', 
    isa => 'Int', 
    default => 0;

has interval => 
    ( is => 'rw' , isa => 'Int' , default => sub { 1 } );

has verbose => 
    ( is => 'rw' , isa => 'Bool' , default => sub { 0 } );

has debug =>
    ( is => 'rw' , isa => 'Bool' , default => sub { 0 } );

# TODO:
has ignore_floating =>
    ( is => 'rw',  isa => 'Bool' , default => sub { 0 } );

has jobs =>
    traits  => ['Array'],
    handles => {
        add_job => 'push'
    },
    is => 'rw', 
    isa => 'ArrayRef' ,
    default => sub {  [ ] }

    ;


has timers => ( is => 'rw', isa => 'ArrayRef' , default => sub { [ ] } );

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
            if $self->debug;
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
    my ( $timespec, $cb , %args ) = @_;

    # try to create with crontab format
    try {
        my $cron_event = DateTime::Event::Cron->new($timespec);
        $self->add_job({
            event => $cron_event,
            cb => $cb,
            %args
        });
    } 
    catch {
        given ( $timespec ) {
            when( m{^\s*(\d+)\s*(\w+)} ) {
                my ( $number, $unit ) = ( $1, $2 );
                my $seconds = $number * $_Expiration_Units{$unit};
                $self->add_job({
                    seconds => $seconds,
                    cb      => $cb,
                    %args
                });
                # $self->create_interval_event( { second => $seconds, callback => $cb } );
            }
            default {
                die 'time string format is not supported.';
            }
        }
    };
    return $self;
}

sub _call_event {
    my ( $self, $e, $dt ) = @_;
    unless ( $e->{triggered} ) {
        print $e->{name} . " triggered\n" if $self->verbose;
        $e->{callback}->( $self, $e, $dt );
        $e->{triggered} = 1;
    }
}

sub _schedule {
    my ($self,$job) = @_;

    AnyEvent->now_update();
    my $now_epoch = AnyEvent->now;
    my $next_epoch;
    my $delay;
    my $name = $job->{name};
    my $debug = $job->{debug};

    if( $job->{event} ) {
        my $event = $job->{event};
        $next_epoch = $event->next->epoch;  # set next schedule time
        $delay      = $next_epoch - $now_epoch;
        warn "delay:",$delay if $debug;
    } 
    elsif( $job->{seconds} ) {
        $next_epoch = $now_epoch + $job->{seconds};
        $delay      = $next_epoch - $now_epoch;
        warn "delay:",$delay if $debug;
    }

    $job->{next}{ $next_epoch } = 1;
    $job->{watchers}{$next_epoch} = AnyEvent->timer(
        after    => $delay,
        cb       => sub {
            $self->{_cv}->begin;
            delete $job->{watchers}{$next_epoch};

            $self->_schedule($job) unless $job->{once};

            if ( $job->{single} && $job->{running}++ ) {
                print STDERR "Skipping job '$name' - still running\n"
                    if $debug;
            }
            else {
                eval { $job->{cb}->( $self->{_cv}, $job ); 1 }
                    or warn $@ || 'Unknown error';
                delete $job->{running};
                print STDERR "Finished job '$name'\n"
                    if $debug;
            }
            $self->{_cv}->end;
        }
    );
}

sub run {
    my $self = shift;
    my $cv = $self->{_cv} = AnyEvent->condvar;
    for my $job ( @{ $self->jobs } ) {
        $self->_schedule($job);
    }
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

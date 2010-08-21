# AnyEvent-Cron

    my $cron = AnyEvent::Cron->new( 
            verbose => 1,
            debug => 1,
            after => 1,
            interval => 1,
            ignore_floating => 1
    );

    # 00:00 (hour:minute)
    $cron->add("00:00" => sub { warn "zero"; })
        ->add( DateTime->now => sub { warn "datetime now" } )
        ->run();

    my $cv = AnyEvent->condvar;
    $cv->recv;


## INSTALLATION

To install this module, run the following commands:

	perl Makefile.PL
	make
	make test
	make install


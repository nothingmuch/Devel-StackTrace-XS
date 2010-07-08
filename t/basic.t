#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use ok 'Devel::StackTrace::XS';

sub Foo::foo { map { $_->new } @_ }
sub bar { Foo::foo(@_) }
sub gorch { bar(@_) }
sub quxx { gorch(@_) }
sub zot { quxx(@_) }
sub baz { zot(@_) }

my ( $xs, $pp ) = baz(qw(Devel::StackTrace::XS Devel::StackTrace));

is( $xs->as_string, $pp->as_string, "stack dump is the same" );

done_testing;

# ex: set sw=4 et:


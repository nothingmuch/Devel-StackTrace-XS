#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use Devel::Peek;
use ok 'Devel::StackTrace::XS';

sub Foo::foo { Devel::StackTrace::XS->new, Devel::StackTrace->new }
sub bar { Foo::foo() }
sub baz { bar() }

my ( $xs, $pp ) = baz();

is( $xs->as_string, $pp->as_string, "stack dump is the same" );

done_testing;

# ex: set sw=4 et:


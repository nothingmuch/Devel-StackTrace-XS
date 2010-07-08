package Devel::StackTrace::XS;

use strict;
use warnings;

require 5.008001;
use parent qw(DynaLoader Devel::StackTrace);

our $VERSION = '0.03';
$VERSION = eval $VERSION;

sub dl_load_flags { 0x01 }

__PACKAGE__->bootstrap($VERSION);

sub _record_caller_data {
    my $self = shift;

    $self->_xs_record_caller_data( $self->{raw} = ["trace in SV magic"], $self->_params_to_flags );
}

sub _params_to_flags {
    my $self = shift;

    return 0;
}


sub _make_frames {
    my $self = shift;

    my $filter = $self->_make_frame_filter;

    for my $r ( $self->_build_raw($self->{raw}) ) {
        next unless $filter->($r);

        $self->_add_frame( $r->{caller}, $r->{args} );
    }
}



__PACKAGE__

__END__



# ex: set sw=4 et:

package Devel::StackTrace::XS;

use strict;
use warnings;

sub SAVE_ERR () { 0x01 }
sub SAVE_ARGS () { 0x02 }
sub SAVE_CV () { 0x04 }
sub SAVE_EVAL_TEXT () { 0x08 }
sub SAVE_MASK () { 0x0f }

sub STRINGIFY_ARGS () { 0x10 }
sub RESPECT_OVERLOAD_ARGS () { 0x20 }

sub STRINGIFY_ERR () { 0x40 }
sub RESPECT_OVERLOAD_ERR () { 0x80 }

sub STRINGIFY_CV () { 0x100 }

require 5.008001;
use parent qw(DynaLoader Devel::StackTrace);

our $VERSION = '0.03';
$VERSION = eval $VERSION;

sub dl_load_flags { 0x01 }

__PACKAGE__->bootstrap($VERSION);


sub _record_caller_data {
    my $self = shift;

    $self->_xs_record_caller_data( $self->_params_to_flags );
}

sub _params_to_flags {
    my $self = shift;

    my $flags = SAVE_CV | SAVE_ARGS;

    $flags |= STRINGIFY_ARGS if $self->{no_refs};
    $flags |= RESPECT_OVERLOAD_ARGS if $self->{respect_overload};

    return $flags;
}


sub _make_frames {
    my $self = shift;

    my $filter = $self->_make_frame_filter;

    for my $r ( $self->_get_raw_frames ) {
        next unless $filter->($r);

        $self->_add_frame( $r->{caller}, $r->{args} );
    }
}



__PACKAGE__

__END__



# ex: set sw=4 et:

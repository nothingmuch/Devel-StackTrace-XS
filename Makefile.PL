use 5.008001;
use strict;
use warnings;


use inc::Module::Install 0.91;
use ExtUtils::Depends;

name 'Devel-StackTrace-XS';
all_from 'lib/Devel/StackTrace/XS.pm';

requires 'parent';
configure_requires 'ExtUtils::Depends' => 0.302; #minimum version that works on Win32+gcc
test_requires 'Test::More';
test_requires 'Test::use::ok';

my $pkg = ExtUtils::Depends->new('Devel::StackTrace::XS');
$pkg->install('devel_stacktrace_xs.h');
$pkg->add_xs('XS.xs');
$pkg->add_pm('lib/Devel/StackTrace/XS.pm' => '$(INST_LIB)/lib/Devel/StackTrace/XS.pm');

mkdir 'build';
$pkg->save_config('build/IFiles.pm');

makemaker_args(
    $pkg->get_makefile_vars,
    DL_FUNCS => { 'Devel::StackTrace::XS' => [] },
);

repository 'git://github.com/nothingmuch/Devel-StackTrace-XS.git';

ppport;

WriteAll;


#!/usr/bin/env perl
# The distro versions all its modules together: Makefile.PL reads the
# version from Lego::PartsList (VERSION_FROM), so a module drifting out
# of sync would ship under a version PAUSE indexes as a different
# release.  (Guard added after Claude review feedback on PR #19.)

use strict;
use warnings;
use utf8;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

use Lego::BrickArchitect;
use Lego::Compare;
use Lego::Constants;
use Lego::LabelCoverage;
use Lego::PartsList;
use Lego::Rebrickable;

use Test::More;

my @modules = qw(
	Lego::BrickArchitect
	Lego::Compare
	Lego::Constants
	Lego::LabelCoverage
	Lego::PartsList
	Lego::Rebrickable
);

# Makefile.PL's VERSION_FROM source defines the distro version.
my $distro = Lego::PartsList->VERSION;

for my $module (@modules) {
	is( $module->VERSION, $distro, "$module versions with the distro" );
}

done_testing();

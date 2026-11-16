#!/usr/bin/env perl
# All Lego:: modules load cleanly.

use strict;
use warnings;

use Test::More;

require Lego::Compare;
require Lego::PartsList;
require Lego::Rebrickable;

for my $module (qw(Lego::BrickArchitect Lego::Compare Lego::Constants
	Lego::LabelCoverage Lego::PartsList Lego::Rebrickable)) {
	require_ok($module);
}

done_testing();

#!/usr/bin/env perl
# Live API smoke test - only runs when explicitly requested:
#
#   LIVE_API=1 REBRICKABLE_API_KEY=... prove -lr t/live/api.t
#
# Skipped otherwise (CI has no key; the fixture cache covers offline
# behavior).

use strict;
use warnings;

use Test::More;

if ( !$ENV{LIVE_API} || !$ENV{REBRICKABLE_API_KEY} ) {
	plan skip_all => 'live tests need LIVE_API=1 and REBRICKABLE_API_KEY';
}

use Lego::Rebrickable;

my $api    = Lego::Rebrickable->new( cache_dir => 'data/cache' );
my $colors = $api->colors;
cmp_ok( scalar keys %{$colors}, '>', 250, 'color metadata loaded' );

my $plate = $api->part_colors('3958');
ok( $plate && @{$plate}, 'colors found for 3958 (Plate 6 x 6)' );
my ($black) = grep { $_->{color_id} == 0 } @{$plate};
ok( $black, '3958 comes in black' );

# The colors endpoint answers unknown part numbers with an empty list
# rather than a 404 (see Lego::PartsList->resolve) - that is why bogus
# numbers yield [] here instead of undef.
my $bogus = $api->part_colors('not-a-part');
ok( defined $bogus && !@{$bogus},
	'bogus part number gives an empty list, not an error' );

done_testing();

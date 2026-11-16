#!/usr/bin/env perl
# Live Brick Architect smoke test - only runs when explicitly requested:
#
#   LIVE_API=1 prove -lr t/live/brickarchitect.t
#
# Skipped otherwise (CI has no network; the fixture suite covers offline
# behavior).  The legacy collection zip is a 20 MB download, so it needs
# its own opt-in:
#
#   LIVE_API=1 LIVE_LEGACY=1 prove -lr t/live/brickarchitect.t
#
# No API key is involved - the site is public - and every response lands
# in data/cache/ so repeat runs are free.

use strict;
use warnings;
use utf8;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

use Test::More;

if ( !$ENV{LIVE_API} ) {
	plan skip_all => 'live tests need LIVE_API=1';
}

use Lego::BrickArchitect;

my $ba = Lego::BrickArchitect->new( cache_dir => 'data/cache' );

# --- cheap first: one index page, two part pages --------------------------------
my $cats = $ba->categories;
cmp_ok( scalar @{$cats}, '==', 12, 'all twelve guide categories discovered' );

my $part = $ba->part('3023');
is( $part->{name}, '1×2 Plate', 'part page parsed (3023)' );
is( $part->{category}, 'Basic', 'category breadcrumb parsed' );
ok( defined $part->{in_legacy} && $part->{in_legacy},
	'3023 is in the legacy collection' );
ok( defined $part->{label_url}, 'label download link found' );

my $redirect = $ba->part('3684');
is( $redirect->{alias}, '98560',
	'old part numbers redirect to modern ones (3684 -> 98560)' );
ok( !exists $part->{alias}, 'non-redirected numbers report no alias' );

# --- the categorized index: twelve category fetches, cached after this run --------
# The category pages hold the guide's ~2900 organized parts (the "5000+"
# figure on the site also counts parts that only surface through search,
# which coverage mode resolves per-part).
my $index = $ba->index;
cmp_ok( scalar keys %{$index}, '>', 2500,
	'index covers the categorized guide (the site says 2500+)' );
ok( $index->{'3023'}, 'a known part is in the index' );

my $hits = $ba->search('bracket');
cmp_ok( scalar @{$hits}, '>', 0, 'search finds brackets' );
ok( ( grep { lc( $_->{name} ) =~ /bracket/ } @{$hits} ) > 0,
	'search matches names, not just numbers' );

# --- legacy collection (20 MB one-time download, cached) --------------------------
SKIP: {
	skip 'legacy zip test needs LIVE_LEGACY=1 too', 4
		unless $ENV{LIVE_LEGACY};

	my $legacy = $ba->legacy_lookup('3684');
	is( $legacy->{category}, 'ANGLE', 'legacy category for 3684' );
	like( $legacy->{group}, qr/slope/, 'legacy drawer for 3684' );
	cmp_ok( scalar keys %{ $ba->legacy_index->{parts} }, '>', 1500,
		'legacy zip indexes the whole ~1800-label collection' );
	ok( $ba->legacy_lookup('3068b'),
		'legacy lookups answer variant numbers directly' );
}

done_testing();

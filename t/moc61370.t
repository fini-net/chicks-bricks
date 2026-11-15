#!/usr/bin/env perl
# End-to-end run of the Business Card Holder example (MOC-61370) against the
# committed fixture cache - no network access required.

use strict;
use warnings;

use Cwd           qw(abs_path);
use File::Basename qw(dirname);
use File::Spec;
use Test::More;

use Lego::Compare;
use Lego::PartsList;
use Lego::Rebrickable;

my $root        = dirname( dirname( abs_path($0) ) );    # t/.. = repo root
my $fixture_dir = File::Spec->catdir( $root, 't', 'fixtures', 'rebrickable' );
plan skip_all =>
	"no fixture cache yet: source .env and run bin/generate-rebrickable-fixtures"
	if !-d $fixture_dir;

my $api = Lego::Rebrickable->new(
	cache_dir => $fixture_dir,
	offline   => 1,
	api_key   => 'offline fixtures',
);

# --- the example parts list --------------------------------------------------
my $csv = File::Spec->catfile( $root, 'examples',
	'business_card_holder.parts.csv' );
my $parts = Lego::PartsList->from_file($csv);
is( scalar @{$parts}, 11, 'eleven distinct parts in the example' );

# --- LDraw variant resolution ------------------------------------------------
# 3684c is what LDraw (and the MOC's own README) calls the solid-stud slope;
# Rebrickable only knows 3684.  The fixture cache holds the empty colors
# response for 3684c (the API answers unknown part numbers with an empty
# list) and the real 19-color response for 3684.
my $probe = Lego::PartsList->resolve( $api,
	[ { input_num => '3684c', part_num => '3684c', name => 'Slope', qty => 1 } ]
);
is( $probe->[0]{part_num}, '3684',
	'LDraw 3684c resolves to Rebrickable 3684' );

# --- fetch colors for every part ----------------------------------------------
Lego::PartsList->resolve( $api, $parts );
my %resolved;
for my $part ( @{$parts} ) {
	my $entries = $api->part_colors( $part->{part_num} );
	ok( defined $entries, "colors found for $part->{part_num}" ) or next;
	my %colors;
	for my $entry ( @{$entries} ) {
		my $meta = $api->colors()->{ $entry->{color_id} };
		$colors{ $entry->{color_id} } = {
			name => $entry->{color_name}
				|| ( defined $meta ? $meta->{name} : undef ),
			num_sets => $entry->{num_sets},
			is_trans => $meta && $meta->{is_trans} ? 1 : 0,
		};
	}
	$part->{colors} = \%colors;
	$resolved{ $part->{part_num} } = $part;
}

# --- the comparison -----------------------------------------------------------
my $cmp   = Lego::Compare->new( parts => \%resolved );
my $inter = $cmp->intersection;

is( $cmp->piece_count, 33, 'business card holder is 33 pieces' );
ok( $inter->{0},  'Black is a monochrome option' );
ok( $inter->{15}, 'White is a monochrome option' );
cmp_ok( scalar keys %{$inter}, '>=', 1, 'at least one monochrome color' );
cmp_ok( scalar keys %{$inter}, '<=', 25, 'monochrome list stays plausible' );

for my $cid ( sort keys %{$inter} ) {
	for my $num ( sort keys %resolved ) {
		ok( $resolved{$num}{colors}{$cid},
			"intersection color $cid really is available for $num" );
	}
}

my $text = $cmp->render_text(
	title        => 'MOC-61370 Business Card Holder',
	min_coverage => 50,
);
like( $text, qr/Monochrome: available for all 11 parts/,
	'report headline' );
like( $text, qr/Bottlenecks/, 'report has bottlenecks' );

# --- the CLI, run offline against the same fixtures ---------------------------
chdir $root;
my $cli_out = `$^X bin/part-colors --parts-file examples/business_card_holder.parts.csv --cache-dir t/fixtures/rebrickable --offline --title MOC-61370`;
is( $? >> 8, 0, 'CLI exits cleanly against fixtures' );
like( $cli_out, qr/MOC-61370/, 'CLI prints the title' );
like( $cli_out, qr/Monochrome: available for all 11 parts/,
	'CLI reports the monochrome section' );

done_testing();

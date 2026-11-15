#!/usr/bin/env perl
# Lego::Compare set math with synthetic part/color data.

use strict;
use warnings;

use Test::More;

use Lego::Compare;

# ids: 0=Black 1=Blue 2=Green 3=Red 4=Trans-Red 5=Lime 6=Yellow
sub color_entry {
	my ( $name, $num_sets, $is_trans ) = @_;
	return { name => $name, num_sets => $num_sets // 10,
		is_trans => $is_trans ? 1 : 0 };
}

my %parts = (
	A => { name => 'Part A', qty => 1, colors => {
		0 => color_entry('Black'),
		1 => color_entry('Blue'),
		4 => color_entry( 'Trans-Red', 3, 1 ),
	} },
	B => { name => 'Part B', qty => 2, colors => {
		0 => color_entry('Black'),
		1 => color_entry('Blue'),
		3 => color_entry('Red'),
	} },
	C => { name => 'Part C', qty => 3, colors => {
		0 => color_entry('Black'),
		5 => color_entry('Lime'),
	} },
);

my $cmp = Lego::Compare->new( parts => \%parts );

is( $cmp->part_count,  3, 'part_count' );
is( $cmp->piece_count, 6, 'piece_count sums quantities' );

my $inter = $cmp->intersection;
is_deeply( [ sort { $a <=> $b } keys %{$inter} ], [0],
	'intersection is the colors shared by every part' );

my $cov = $cmp->coverage;
is( $cov->{0}{count}, 3, 'black covers all parts' );
is_deeply( $cov->{0}{missing}, [], 'black missing nothing' );
is_deeply( $cov->{3}{missing}, [ 'A', 'C' ], 'red missing A and C' );
is( $cov->{5}{pct}, 100 * 1 / 3, 'coverage pct' );

my $near = $cmp->near_misses(0);
is( scalar @{$near}, 4, 'all non-intersection colors are near misses' );
is( $near->[0]{color_id}, 1, 'blue ranks first (2/3 parts)' );
is_deeply( $near->[0]{missing}, ['C'], 'blue missing only C' );

my $bott = $cmp->bottlenecks;
is_deeply(
	[ map { $_->{part_num} } @{$bott} ],
	[ 'C', 'A', 'B' ],
	'bottlenecks ordered by fewest available colors',
);
is( $bott->[0]{available_colors}, 2, 'part C has 2 colors' );

# --exclude_trans drops color 4 everywhere
my $notrans = Lego::Compare->new( parts => \%parts, exclude_trans => 1 );
is_deeply(
	[ sort { $a <=> $b } keys %{ $notrans->intersection } ],
	[0], 'exclude_trans does not change this intersection',
);
my $cov_notrans = $notrans->coverage;
ok( !exists $cov_notrans->{4}, 'transparent color filtered from coverage' );

# --min_sets 5 drops color 4 (3 sets) from part A
my $rare = Lego::Compare->new( parts => \%parts, min_sets => 5 );
my $cov_rare = $rare->coverage;
ok( !exists $cov_rare->{4}, 'min_sets filters rare colors' );

# empty intersection when a part shares nothing
my %disjoint = (
	A => { name => 'A', qty => 1, colors => { 0 => color_entry('Black') } },
	B => { name => 'B', qty => 1, colors => { 3 => color_entry('Red') } },
);
my $empty = Lego::Compare->new( parts => \%disjoint );
is( scalar keys %{ $empty->intersection }, 0, 'disjoint parts: empty intersection' );
like( $empty->render_text( title => 'Test' ), qr/Monochrome.*\(none\)/s,
	'render_text reports no monochrome options' );

# summary_data structure
my $data = $cmp->summary_data( title => 'synthetic', min_coverage => 0 );
is( $data->{title},      'synthetic', 'summary title' );
is( $data->{part_count}, 3,            'summary part_count' );
is( scalar @{ $data->{monochrome} }, 1, 'summary monochrome count' );
is( $data->{monochrome}[0]{name},  'Black', 'summary monochrome name' );
is( $data->{near_misses}[0]{name}, 'Blue',  'summary near miss name' );
is( $data->{near_misses}[0]{pct},   100 * 2 / 3, 'summary near miss pct' );

# render_text sections
my $text = $cmp->render_text( title => 'synthetic', min_coverage => 50 );
like( $text, qr/^synthetic$/m,        'render_text title' );
like( $text, qr/Monochrome/,          'render_text monochrome section' );
like( $text, qr/Near misses \(>= 50%/, 'render_text near misses header' );
like( $text, qr/Bottlenecks/,         'render_text bottlenecks section' );

# render_csv
my $csv = $cmp->render_csv;
like( $csv, qr/\Acolor,parts_available,parts_total,coverage_pct,missing_parts\n/,
	'render_csv header' );
like( $csv, qr/^Black,3,3,100\.0,$/m, 'render_csv full-coverage row' );
like( $csv, qr/^Red,1,3,33\.3,A;C$/m, 'render_csv partial row with missing' );

# a part with no colors at all blocks everything
my %blocked = (
	A => { name => 'A', qty => 1, colors => { 0 => color_entry('Black') } },
	B => { name => 'B', qty => 1, colors => {} },
);
my $blocker = Lego::Compare->new( parts => \%blocked );
is( scalar keys %{ $blocker->intersection }, 0,
	'part with no colors empties the intersection' );

# constructor sanity
eval { Lego::Compare->new };
like( $@, qr/parts must be a hashref/, 'constructor requires parts' );

done_testing();

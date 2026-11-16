#!/usr/bin/env perl
# Lego::LabelCoverage: label coverage math, legacy classification, and
# rendering - all against fixture-backed mock transports, no network.

use strict;
use warnings;
use utf8;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

use File::Spec ();
use Encode     qw(decode);
use Test::More;

use Lego::BrickArchitect;
use Lego::LabelCoverage;
use Lego::PartsList;

# A HTTP::Tiny stand-in: serves canned responses, 404s everything else.
{
	package TestUa;

	sub new {
		my ( $class, %args ) = @_;
		return bless { responses => $args{responses} || {}, requests => [] },
			$class;
	}

	sub get {
		my ( $self, $url, $options ) = @_;
		push @{ $self->{requests} }, { url => $url };
		if ( exists $self->{responses}{$url} ) {
			return { success => 1, status => 200, reason => 'OK',
				url => $url, content => $self->{responses}{$url} };
		}
		return { success => 0, status => 404, reason => 'Not Found',
			url => $url, content => q{} };
	}

	sub request_count {
		my ( $self, $url ) = @_;
		return scalar grep { $_->{url} eq $url } @{ $self->{requests} };
	}
}

my $BASE = 'https://brickarchitect.com';
my $ZIP  = 'https://brickarchitect.com/files/LEGO_BRICK_LABELS.zip';

sub fixture {
	my ($name) = @_;
	open my $fh, '<',
		File::Spec->catfile( 't', 'fixtures', 'brickarchitect', $name )
		or die "cannot read fixture '$name': $!";
	local $/;
	return <$fh>;
}

# A legacy zip with a drawer for 3684 and one holding the 3068b variant.
sub legacy_zip_bytes {
	require IO::Compress::Zip;
	my $mk_lbx = sub {
		my ($xml) = @_;
		my $lbx = q{};
		my $z   = IO::Compress::Zip->new( \$lbx, Name => 'label.xml' )
			or die 'cannot build lbx';
		$z->print($xml);
		$z->close;
		return $lbx;
	};
	my $outer = q{};
	my $z     = IO::Compress::Zip->new( \$outer,
		Name => 'LEGO_BRICK_LABELS-v40/ABOUT.txt' );
	$z->print("about\n");
	$z->newStream(
		Name => 'LEGO_BRICK_LABELS-v40/Labels/1. BASIC/BASIC-tile_1.lbx' );
	$z->print( $mk_lbx->( join q{}, map {qq{originalName="$_.png" }} 3068, '3068b' ) );
	$z->newStream(
		Name => 'LEGO_BRICK_LABELS-v40/Labels/7. ANGLE/ANGLE-slope_55_65_75.lbx' );
	$z->print( $mk_lbx->('originalName="3684.png"') );
	$z->close;
	return $outer;
}

# The label page the guide serves for 3684: its canonical number is 98560.
# (Only ASCII bits are rewritten: the fixture is raw HTTP::Tiny bytes, and
# decoded-char substitutions would not match them.)
my $redirected_98560 = do {
	my $page = fixture('part-3023.html');
	$page =~ s/\(Part 3023\)/(Part 98560)/;
	$page =~ s{parts/3023}{parts/98560}g;
	$page =~ s{label/3023}{label/98560}g;
	$page;
};

sub build_client {
	my (%extra) = @_;
	my $ua = TestUa->new( responses => {
		"$BASE/parts/category-1?&retired=1" => fixture('category-basic.html'),
		"$BASE/parts/3023"                  => fixture('part-3023.html'),
		"$BASE/parts/3684"                  => $redirected_98560,
		$ZIP                                => legacy_zip_bytes(),
	} );
	return Lego::BrickArchitect->new(
		ua         => $ua,
		categories => [1],
		gentle     => 0,    # tests never sleep between mock fetches
		%extra,
	);
}

sub test_parts {
	# input_num/part_num rows like Lego::PartsList produces
	return [
		{ input_num => '3622',  part_num => '3622',  name => 'Brick 1 x 3',        qty => 2 },
		{ input_num => '3023',  part_num => '3023',  name => 'Plate 1 x 2',         qty => 4 },
		{ input_num => '3684',  part_num => '3684',  name => 'Slope Brick 75 2 x 2 x 3', qty => 12 },
		{ input_num => '3068b', part_num => '3068b', name => 'Tile 2 x 2 with Groove',  qty => 1 },
		{ input_num => '4865b', part_num => '4865b', name => 'Panel 1 x 2 x 1 Rounded', qty => 2 },
	];
}

# --- constructor guards -----------------------------------------------------
{
	eval { Lego::LabelCoverage->new( parts => {}, ba => bless {}, 'X' ) };
	like( $@, qr/parts must be an arrayref/, 'parts must be an arrayref' );
	eval { Lego::LabelCoverage->new( parts => [], ba => {} ) };
	like( $@, qr/ba must be a Lego::BrickArchitect client/, 'ba must be a client' );
}

# --- coverage with deep lookups + legacy --------------------------------------
{
	my $ba  = build_client;
	my $cov = Lego::LabelCoverage->new(
		parts  => test_parts,
		ba     => $ba,
		legacy => 1,
	);
	my $rows = $cov->analyze;

	is( $cov->part_count, 5,  'part count' );
	is( $cov->piece_count, 21, 'piece count sums quantities' );
	is( $cov->labeled_parts, 3, 'three parts have guide labels' );
	is( $cov->labeled_pieces, 18, 'labeled pieces are quantity-weighted' );
	cmp_ok( $cov->coverage_pct, '==', 60, 'coverage percent' );
	cmp_ok( $cov->pieces_pct, '==', 100 * 18 / 21, 'piece coverage percent' );

	my %by_input = map { $_->{input_num} => $_ } @{$rows};

	is( $by_input{'3622'}{source}, 'index', 'index hit via the category crawl' );
	is( $by_input{'3622'}{category}, 'Basic', 'index rows carry the breadcrumb' );
	is( $by_input{'3023'}{source}, 'page', 'non-index part fetched per-page' );
	is( $by_input{'3023'}{label_name}, '1×2 Plate', 'deep lookup parses the page' );
	is( $by_input{'3684'}{alias}, '98560', 'old number resolves to its alias' );
	is( $by_input{'3684'}{label_name}, '1×2 Plate',
		'alias row carries the canonical page name' );
	is( $by_input{'3684'}{url}, "$BASE/parts/98560",
		'alias row points at the canonical page' );
	ok( !$by_input{'3068b'}{has_label}, 'page-less part is unlabeled' );
	is( $by_input{'3068b'}{in_legacy}, 1, 'variant number hits the legacy zip' );
	is( $by_input{'3068b'}{legacy_group}, 'BASIC-tile_1', 'legacy drawer reported' );
	ok( !$by_input{'4865b'}{has_label} && !$by_input{'4865b'}{in_legacy},
		'unknown part has neither label nor legacy entry' );

	my $stats = $cov->legacy_stats;
	is_deeply( [ map { $_->{input_num} } @{ $stats->{both} } ],      ['3684'], 'in both' );
	is_deeply( [ map { $_->{input_num} } @{ $stats->{guide_only} } ], [ '3622', '3023' ],
		'guide only (analyze order)' );
	is_deeply( [ map { $_->{input_num} } @{ $stats->{legacy_only} } ], ['3068b'], 'legacy only' );
	is_deeply( [ map { $_->{input_num} } @{ $stats->{neither} } ],     ['4865b'], 'neither' );

	# the legacy print queue only contains the guide-only gaps
	my $text = $cov->render_text( title => 'Test collection' );
	like( $text, qr/^Label coverage: 3\/5 parts \(60%\), 18\/21 pieces \(86%\)$/m,
		'render_text shows part and piece coverage' );
	like( $text, qr/^  3684 = 98560/m, 'aliases display as input = canonical' );
	like( $text, qr/^Label pages to print \(2\)$/m,
		'legacy mode queues only the guide-only gaps' );
	like( $text, qr{^\s+\Q$BASE/parts/3023\E$}m, 'queue holds label page URLs' );
	unlike( $text, qr{^\Q$BASE/parts/98560\E$}m,
		'already-legacy parts are not in the queue' );
	like( $text, qr/Legacy v40 comparison/, 'legacy comparison section' );
	like( $text, qr/3684 = 98560 \(legacy drawer: ANGLE \/ ANGLE-slope_55_65_75\)/,
		'legacy drawers render next to their parts' );

	# without legacy, the queue covers every labeled part
	my $cov2 = Lego::LabelCoverage->new( parts => test_parts, ba => build_client );
	my $text2 = $cov2->render_text( title => 'Test collection' );
	like( $text2, qr/^Label pages to print \(3\)$/m, 'default queue is all labeled parts' );
	unlike( $text2, qr/Legacy/, 'no legacy section without the flag' );

	# csv: header, one row per part, legacy columns appended
	my $csv = $cov->render_csv;
	my @lines = split /\n/, $csv;
	like( $lines[0], qr/^input_num,part_num,name,has_label/, 'csv header' );
	like( $lines[0], qr/in_legacy,legacy_category,legacy_group,url\z/,
		'csv header gains legacy columns' );
	is( scalar @lines, 6, 'one csv row per part' );
	like( $csv, qr/^3068b,3068b,Tile 2 x 2 with Groove,no,,,,,yes,BASIC,BASIC-tile_1/m,
		'legacy-only part row shows both sides' );

	# summary_data feeds the JSON output
	my $data = $cov->summary_data( title => 'Test collection' );
	is( $data->{labeled_parts}, 3, 'summary coverage counts' );
	is( $data->{legacy}{both}[0], '3684', 'summary legacy classification' );
	is( scalar @{ $data->{parts} }, 5, 'summary carries every part' );
}

# --- index-only mode (--no-deep) ------------------------------------------------
{
	my $ba  = build_client;
	my $cov = Lego::LabelCoverage->new(
		parts => test_parts,
		ba    => $ba,
		deep  => 0,
	);
	my %by_input = map { $_->{input_num} => $_ } @{ $cov->analyze };
	is( $by_input{'3023'}{has_label}, 0,
		'index-only mode does not fetch per-part pages' );
	is( $cov->labeled_parts, 1, 'only the indexed part counts as labeled' );
	is( $ba->{ua}->request_count("$BASE/parts/3023"), 0,
		'no per-part requests were made' );
}

# --- the bundled example parts list, end to end ---------------------------------
{
	my $ba  = build_client;
	my $parts = Lego::PartsList->from_file('examples/business_card_holder.parts.csv');
	my $cov = Lego::LabelCoverage->new(
		parts => $parts,
		ba    => $ba,
		deep  => 0,
	);
	# the fixture index only covers the Basic bricks, so only 3622 and
	# 3010 of the eleven example parts match with deep lookups disabled
	is( $cov->part_count, 11, 'all eleven distinct example parts load' );
	is( $cov->labeled_parts, 2, 'two match the fixture index' );
	my $text = $cov->render_text(
		title => 'MOC-61370 Business Card Holder' );
	like( $text, qr/^Label coverage: 2\/11 parts \(18%\)/m,
		'example report renders coverage' );
	like( $text, qr/^  3622\s+1×3\s+Basic > Brick > 1× Brick$/m,
		'labeled rows show name and breadcrumb' );
}

# --- csv_escape: the quoting rules (RFC 4180-ish) ----------------------------------
{
	is( Lego::LabelCoverage::csv_escape('plain'), 'plain',
		'plain fields pass through untouched' );
	is( Lego::LabelCoverage::csv_escape(q{}), q{}, 'empty fields stay empty' );
	is( Lego::LabelCoverage::csv_escape('Tile 1 x 2, Round'),
		'"Tile 1 x 2, Round"', 'commas quote' );
	is( Lego::LabelCoverage::csv_escape('say "hi"'), '"say ""hi"""',
		'quotes quote and double' );
	is( Lego::LabelCoverage::csv_escape("with\nnewline"), "\"with\nnewline\"",
		'LF quotes' );
	is( Lego::LabelCoverage::csv_escape("with\rcarriage"),
		"\"with\rcarriage\"",
		'CR quotes too (a bare \r would corrupt the row)' );

	# undef must become empty without a peep
	my $warnings = q{};
	local $SIG{__WARN__} = sub { $warnings .= $_[0] };
	is( Lego::LabelCoverage::csv_escape(undef), q{}, 'undef becomes empty' );
	is( $warnings, q{}, 'without uninitialized warnings' );

	# the quoted shapes round-trip through the repo's own parser
	my @row = Lego::PartsList->parse_csv(
		join ',', map { Lego::LabelCoverage::csv_escape($_) }
			'Tile 1 x 2, Round', 'say "hi"' );
	is_deeply( \@row, [ 'Tile 1 x 2, Round', 'say "hi"' ],
		'quoted fields round-trip through parse_csv' );
}

done_testing();

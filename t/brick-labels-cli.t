#!/usr/bin/env perl
# bin/brick-labels end to end: offline runs against a cache pre-populated
# from the fixtures, one test per output format.  The code review found
# both of the tool's bugs in here (unterminated CSV quoting, and search
# terms with spaces never matching), so this file exists to keep the CLI
# honest - module tests cannot see what the script prints.

use strict;
use warnings;
use utf8;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

use Digest::SHA qw(sha1_hex);
use Encode     qw(decode encode);
use File::Spec  ();
use File::Temp  ();
use JSON::PP    qw(decode_json);
use Test::More;

use Lego::PartsList ();

my $BIN  = File::Spec->catfile( 'bin', 'brick-labels' );
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

# A part page with a comma in the name, to prove CSV quoting survives the
# whole pipeline.  Mirrors the guide's markup closely enough for
# parse_part_page (h1, chapternav breadcrumb, legacy sentence, .lbx link).
my $comma_page = encode( 'UTF-8', <<'END_HTML' );
<!DOCTYPE html><html><head><meta charset="UTF-8">
<title>3069 - Tile 1 x 2, Round - LEGO Parts Guide - Brick Architect</title></head><body>
<div class="chapternav"><span class="highlight"> &lsaquo; <a href="https://brickarchitect.com/parts">The LEGO Parts Guide</a> <span style="font-weight: 100; color: #444">&rsaquo;</span> <a href="https://brickarchitect.com/parts/category-1">Basic</a> <span style="font-weight: 100; color: #444">&rsaquo;</span> <a href="https://brickarchitect.com/parts/category-16">Plate</a> <span style="font-weight: 100; color: #444">&rsaquo;</span> <a href="https://brickarchitect.com/parts/category-31">1× Plate</a></span></div>
<h1>Tile 1 x 2, Round <span style="font-weight: normal; white-space: nowrap;">(Part 3069)</span></h1>
<div class="partinfo"><div class="partoverview"><div class="part_years">2000-2026</div></div></div>
<p class="smallest"><em>Included in legacy <a href="https://brickarchitect.com/labels">LEGO Brick Labels</a> collection.</em></p>
<div class="labelstyle border"><a href="https://brickarchitect.com/parts/../label/3069.lbx" style="margin-bottom: 12px;"><div class="partcontainer"><table><tr><td align="center">3069.lbx</td></tr></table></div></a></div>
</body></html>
END_HTML

# A small legacy-collection zip, same shape as the real download.
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

# Write one cache entry, exactly as Lego::BrickArchitect would have.
sub put_cache {
	my ( $dir, $url, $ext, $bytes ) = @_;
	open my $fh, '>', File::Spec->catfile( "$dir", sha1_hex($url) . ".$ext" )
		or die "cannot write cache: $!";
	binmode $fh;
	print {$fh} $bytes;
	close $fh;
	return;
}

my $dir = File::Temp->newdir;

# the guide index: /parts/ plus its three fixture categories
put_cache( $dir, "$BASE/parts/", 'html', fixture('parts-index.html') );
put_cache( $dir, "$BASE/parts/category-1?&retired=1", 'html',
	fixture('category-basic.html') );
put_cache( $dir, "$BASE/parts/category-2?&retired=1", 'html',
	fixture('category-basic.html') );
put_cache( $dir, "$BASE/parts/category-12?&retired=1", 'html',
	fixture('category-basic.html') );
# label pages: the fixture part, the comma-named synthetic, and a 404
put_cache( $dir, "$BASE/parts/3023", 'html', fixture('part-3023.html') );
put_cache( $dir, "$BASE/parts/3069", 'html', $comma_page );
put_cache( $dir, "$BASE/parts/99999", 'html',
	"__BRICKARCHITECT_NOT_FOUND__\n" );
# the legacy collection
put_cache( $dir, $ZIP, 'zip', legacy_zip_bytes() );

# Run the CLI with @args plus --offline --cache-dir, capturing stdout
# (decoded), stderr, and the exit code.  List-form pipe open keeps terms
# with spaces intact without shell quoting games.  STDERR is redirected at
# the file-descriptor level (a mere glob rebinding never reaches the
# child).
sub run_cli {
	my (@args) = @_;
	my $err_file = File::Spec->catfile( "$dir", "stderr.$$.txt" );
	open my $err, '>', $err_file or die "cannot open $err_file: $!";
	open my $saved_stderr, '>&', STDERR or die "cannot dup stderr: $!";
	open STDERR, '>&', $err or die "cannot redirect stderr: $!";
	my $ok = open my $ph, '-|', $^X, $BIN, @args, '--offline',
		'--cache-dir', "$dir";
	open STDERR, '>&', $saved_stderr or die "cannot restore stderr: $!";
	close $saved_stderr;
	die "cannot run $BIN: $!" if !$ok;
	local $/;
	my $out = <$ph>;
	close $ph;
	close $err;
	my $exit = $? >> 8;
	$out = decode( 'UTF-8', defined $out ? $out : q{} );
	my $stderr = do {
		open my $ef, '<', $err_file or die "cannot read $err_file: $!";
		local $/;
		decode( 'UTF-8', <$ef> // q{} );
	};
	return ( $exit, $out, $stderr );
}

# --- lookup: text ---------------------------------------------------------------
{
	my ( $exit, $out ) = run_cli(3023);
	is( $exit, 0, 'lookup exits cleanly' );
	like( $out, qr/^3023: 1×2 Plate$/m, 'text lookup names the part' );
	like( $out, qr/^  Basic > Plate > 1× Plate$/m, 'breadcrumb renders' );
	like( $out, qr{^  \.lbx:  \Q$BASE/label/3023.lbx\E$}m, 'label link renders' );
	like( $out, qr/^  in legacy LEGO Brick Labels$/m, 'legacy sentence renders' );
}

# --- lookup: csv (the comma-in-name quoting regression) ---------------------------
{
	my ( $exit, $out ) = run_cli( 3069, '--format', 'csv' );
	is( $exit, 0, 'csv lookup exits cleanly' );
	my @lines = split /\n/, $out;
	is( scalar @lines, 2, 'csv lookup emits header plus one row' );
	# columns are alphabetical (uniq_keys) - the point is the quoting
	like( $lines[1], qr/"Tile 1 x 2, Round",3069,Plate,/m,
		'the comma-named field is quoted and terminated' );
	unlike( $lines[1], qr/,3069,Plate,\z/, 'row ends cleanly (no dangling quote)' );
	my @fields = Lego::PartsList->parse_csv( $lines[1] );
	my %by_name;
	@by_name{ Lego::PartsList->parse_csv( $lines[0] ) } = @fields;
	is( $by_name{name}, 'Tile 1 x 2, Round',
		'round-trips through the repo csv parser' );
}

# --- lookup: json ------------------------------------------------------------------
{
	my ( $exit, $out ) = run_cli( 3069, '--format', 'json' );
	is( $exit, 0, 'json lookup exits cleanly' );
	# decode_json wants bytes; $out arrived decoded for the text tests
	my $data = decode_json( encode( 'UTF-8', $out ) );
	is( $data->{parts}[0]{name}, 'Tile 1 x 2, Round', 'json carries the name' );
	is( $data->{parts}[0]{label_url}, "$BASE/label/3069.lbx", 'json label url' );
}

# --- lookup: a cached 404 ------------------------------------------------------------
{
	my ( $exit, $out ) = run_cli(99999);
	is( $exit, 0, 'missing label page still exits cleanly' );
	like( $out, qr/^99999: no label in the parts guide$/m,
		'cached 404 replays as "no label"' );
}

# --- lookup: an uncached number must die offline ---------------------------------------
{
	my ( $exit, $out, $stderr ) = run_cli(12345);
	isnt( $exit, 0, 'offline cache miss exits nonzero' );
	like( $stderr, qr/offline mode: no cached response/,
		'and says so on stderr' );
}

# --- search ---------------------------------------------------------------------------
{
	my ( $exit, $out ) = run_cli( '--search', '2 Corner' );
	is( $exit, 0, 'search exits cleanly' );
	like( $out, qr/^2357: 2×2 Corner$/m,
		'search terms with spaces match (double-escape regression)' );
	like( $out, qr/^  Basic > Brick > 2× Brick$/m, 'search shows breadcrumbs' );

	( $exit, $out ) = run_cli( '--search', '2 Corner', '--format', 'csv' );
	is( $exit, 0, 'csv search exits cleanly' );
	like( $out, qr/^Basic,2× Brick,yes,https:\/\/brickarchitect\.com\/label\/2357\.lbx,2×2 Corner,2357,/m,
		'csv search row is well-formed' );

	# UTF-8 arguments must decode before matching the index names
	( $exit, $out ) = run_cli( '--search', '2×2 Corner' );
	is( $exit, 0, 'utf8 search exits cleanly' );
	like( $out, qr/^2357: 2×2 Corner$/m, 'utf8 args decode and match names' );
}

# --- coverage: the bundled example, index-only ------------------------------------------
{
	my ( $exit, $out ) = run_cli(
		'--parts-file', 'examples/business_card_holder.parts.csv',
		'--no-deep', '--title', 'MOC-61370 Business Card Holder' );
	is( $exit, 0, 'coverage exits cleanly' );
	like( $out, qr/^MOC-61370 Business Card Holder$/m, 'title renders' );
	like( $out, qr/^Label coverage: 2\/11 parts \(18%\), 7\/33 pieces \(21%\)$/m,
		'coverage line (fixture index covers 3622 and 3010 only)' );
	like( $out, qr/^  3622\s+1×3\s+Basic > Brick > 1× Brick$/m,
		'labeled row with breadcrumb' );
	like( $out, qr/^Label pages to print \(2\)$/m, 'print queue count' );
	like( $out, qr{^\s+\Q$BASE/parts/3622\E$}m, 'print queue urls' );
}

# --- coverage: legacy columns in csv -----------------------------------------------------
{
	my ( $exit, $out ) = run_cli(
		'--parts-file', 'examples/business_card_holder.parts.csv',
		'--no-deep', '--legacy', '--format', 'csv' );
	is( $exit, 0, 'legacy csv coverage exits cleanly' );
	my @lines = split /\n/, $out;
	like( $lines[0], qr/in_legacy,legacy_category,legacy_group,url\z/,
		'csv header grows the legacy columns' );
	my %row;
	for my $line (@lines[ 1 .. $#lines ]) {
		my @f = Lego::PartsList->parse_csv($line);
		$row{ $f[0] } = \@f;
	}
	is( $row{'3068b'}[8], 'yes', '3068b is in the legacy zip' );
	is( $row{'3068b'}[9], 'BASIC', '...with its legacy category' );
	is( $row{'3068b'}[10], 'BASIC-tile_1', '...and its drawer' );
	is( $row{'3622'}[3], 'yes', '3622 has a guide label' );
	is( $row{'3622'}[8], 'no', '...but is not in this legacy zip' );
}

# --- coverage: legacy classification in text ----------------------------------------------
{
	my ( $exit, $out ) = run_cli(
		'--parts-file', 'examples/business_card_holder.parts.csv',
		'--no-deep', '--legacy' );
	is( $exit, 0, 'legacy text coverage exits cleanly' );
	like( $out, qr/^  Legacy only: +3684 \(legacy drawer: ANGLE \/ ANGLE-slope_55_65_75\), 3068b \(legacy drawer: BASIC \/ BASIC-tile_1\)$/m,
		'legacy-only parts render with their drawers' );
	like( $out, qr/^  Guide only: +3622, 3010$/m,
		'guide-only parts are the fixture-index hits' );
}

done_testing();

#!/usr/bin/env perl
# Lego::BrickArchitect client behavior: parsers against committed
# fixtures, the disk cache, mock transports, and the legacy zip walk -
# no network access anywhere in this test.

use strict;
use warnings;
use utf8;    # the fixture part names below contain × and ⅔

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

use Digest::SHA ();
use Encode     qw(decode);
use File::Spec  ();
use File::Temp  ();
use Test::More;

use Lego::BrickArchitect;

# A HTTP::Tiny stand-in that serves canned responses and records requests.
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
				url     => $url,
				content => $self->{responses}{$url} };
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

# Every test client: gentle => 0 so the fetch-pacing sleep never slows
# the suite.  The pacing itself gets its own dedicated test below.
sub new_ba {
	return Lego::BrickArchitect->new( gentle => 0, @_ );
}

# Fixture bytes exactly as HTTP::Tiny would fetch them (raw).  Tests that
# call the parsers directly decode first, because get() hands the parsers
# decoded text.
sub fixture {
	my ($name) = @_;
	open my $fh, '<',
		File::Spec->catfile( 't', 'fixtures', 'brickarchitect', $name )
		or die "cannot read fixture '$name': $!";
	local $/;
	return <$fh>;
}

sub decoded_fixture {
	return decode( 'UTF-8', fixture( $_[0] ) );
}

# Build a small legacy-collection zip in memory, mirroring the real
# LEGO_BRICK_LABELS.zip layout: Labels/<N. CATEGORY>/<GROUP>.lbx, where
# each .lbx is itself a zip holding a label.xml that names its part
# images after part numbers.
sub legacy_zip_bytes {
	require IO::Compress::Zip;
	my %args = @_;

	my $mk_lbx = sub {
		my ($xml) = @_;
		my $lbx = q{};
		my $z   = IO::Compress::Zip->new( \$lbx, Name => 'label.xml' )
			or die 'cannot build lbx';
		$z->print($xml);
		$z->newStream( Name => 'Object0.bmp' );
		$z->print("BM-fake-image-bytes");
		$z->close;
		return $lbx;
	};

	my $brick_xml = join q{}, map { qq{originalName="$_.png" } }
		@{ $args{bricks} // [ 3005, 3004, 3004 ] };
	my $angle_xml = join q{}, map { qq{originalName="$_.png" } }
		@{ $args{angles} // [3684] };

	my $outer = q{};
	my $z     = IO::Compress::Zip->new( \$outer,
		Name => 'LEGO_BRICK_LABELS-v40/ABOUT.txt' );
	$z->print("about\n");
	$z->newStream(
		Name => 'LEGO_BRICK_LABELS-v40/Labels/1. BASIC/BASIC-brick-1x.lbx' );
	$z->print( $mk_lbx->($brick_xml) );
	$z->newStream(
		Name => 'LEGO_BRICK_LABELS-v40/Labels/1. BASIC/INDEX-BASIC.lbx' );
	$z->print( $mk_lbx->('originalName="INDEX.png"') );
	$z->newStream(
		Name => 'LEGO_BRICK_LABELS-v40/Labels/7. ANGLE/ANGLE-slope.lbx' );
	$z->print( $mk_lbx->($angle_xml) );
	$z->newStream(
		Name => 'LEGO_BRICK_LABELS-v40/New_in_v40/Updated_in_v40-labels_1.lbx' );
	$z->print( $mk_lbx->('originalName="99999.png"') );
	$z->close;
	return $outer;
}

# --- parsers: category page ----------------------------------------------------
{
	my $ba     = Lego::BrickArchitect->new;
	my $rows   = $ba->parse_category_page( decoded_fixture('category-basic.html') );
	my $parts  = $rows->{parts};
	is( $rows->{category}, 'Basic', 'category name from resultsheadercount' );
	is( scalar keys %{$parts}, 9, 'all fixture part rows parsed' );

	my $corner = $parts->{2357};
	is( $corner->{name}, '2×2 Corner', 'name with a space parses' );
	is( $corner->{group}, '2× Brick', 'rows follow their own h3 group' );

	my $plate = $parts->{3005};
	is( $plate->{name}, '1×1', 'part name decoded as UTF-8 text' );
	is( $plate->{subcategory}, 'Brick', 'h2 subcategory tracked' );
	is( $plate->{group}, '1× Brick', 'h3 group tracked' );
	is( $plate->{url}, "$BASE/parts/3005", 'guide URL built' );
	ok( !$plate->{is_new} && !$plate->{retired}, 'plain row has no markers' );

	my $retired = $parts->{3755};
	ok( $retired->{retired}, 'retired indicator detected' );
	is( $retired->{group}, 'Tall Brick', 'rows after a later h3 follow it' );

	my $blate = $parts->{86996};
	is( $blate->{subcategory}, 'Blate', 'parts can sit directly under an h2' );
	ok( !exists $blate->{group}, 'no group key when there was no h3' );
	is( $blate->{name}, '1×1×⅔', 'unicode part names survive the parser' );

	like( $parts->{3005}{url}, qr{/parts/3005\z}, 'query-free URL for plain view' );
}

# --- parsers: part page --------------------------------------------------------
{
	my $ba   = Lego::BrickArchitect->new;
	my $row  = $ba->parse_part_page( decoded_fixture('part-3023.html') );
	is( $row->{part_num}, '3023', 'part number from the h1' );
	is( $row->{name}, '1×2 Plate', 'part name from the h1' );
	is( $row->{category}, 'Basic', 'breadcrumb category' );
	is( $row->{subcategory}, 'Plate', 'breadcrumb subcategory' );
	is( $row->{group}, '1× Plate', 'breadcrumb group' );
	is( $row->{in_legacy}, 1, '"Included in legacy" marker parsed' );
	is( $row->{label_url}, "$BASE/label/3023.lbx", 'non-QR .lbx label link' );

	my $new = $ba->parse_part_page( decoded_fixture('part-77842.html') );
	is( $new->{in_legacy}, 0, '"New Label! Not included" marker parsed' );
	is( $new->{label_url}, "$BASE/label/77842.lbx", 'new parts still have labels' );
}

# --- parsers: legacy zip --------------------------------------------------------
{
	my $ba    = Lego::BrickArchitect->new;
	my $bytes = legacy_zip_bytes(
		bricks => [ 3005, 3004, '3068b' ],
		angles => [ 3684, 98560 ],
	);
	my ( $parts, $version ) = $ba->parse_legacy_zip($bytes);
	is( $version, 40, 'version parsed from the v40 folder name' );
	is( scalar keys %{$parts}, 5, 'all label parts indexed, duplicates once' );
	is_deeply( $parts->{3005},
		{ category => 'BASIC', group => 'BASIC-brick-1x' },
		'category numbering stripped, drawer name kept' );
	is_deeply( $parts->{3684},
		{ category => 'ANGLE', group => 'ANGLE-slope' },
		'legacy rows carry category and drawer' );
	ok( !exists $parts->{INDEX}, 'INDEX- lbx pages are not labels' );
	ok( !exists $parts->{99999}, 'New_in_v40 folders are not label drawers' );
}

# --- categories discovery + index ------------------------------------------------
{
	my %pages = (
		"$BASE/parts/" => fixture('parts-index.html'),
		map { ( ba_url($_) => fixture('category-basic.html') ) } 1, 2, 12,
	);
	my $ua = TestUa->new( responses => \%pages );
	my $ba = new_ba( ua => $ua );

	my $cats = $ba->categories;
	is( scalar @{$cats}, 3, 'categories discovered from the index page' );
	is_deeply( $cats->[0], { id => 1, name => 'BASIC' }, 'category id + name' );

	# The same fixture page serves all three discovered categories, so
	# every part is "listed twice" - which exercises the duplicate warning.
	my $warnings = q{};
	local $SIG{__WARN__} = sub { $warnings .= $_[0] };
	my $index = $ba->index;
	is( scalar keys %{$index}, 9, 'index holds the fixture parts once each' );
	like( $warnings, qr/part 3005 listed in both Basic and Basic - keeping the first/,
		'a part listed twice warns and keeps the first' );
	ok( $index->{3622} && $index->{3622}{subcategory} eq 'Brick',
		'index rows carry the breadcrumb' );
	is( $ua->request_count("$BASE/parts/"), 1, 'index page fetched once' );
	is( $ua->request_count("$BASE/parts/category-1?&retired=1"), 1,
		'category page fetched once (memoized)' );

	my $hit = $ba->index_lookup('3068b');
	ok( !$hit, 'variant lookup misses when the base is absent' );
}

sub ba_url {    # category URL for an id, on the default base
	my ($id) = @_;
	return "$BASE/parts/category-$id?&retired=1";
}

# --- parsers: legacy zip, robust against bad drawers ----------------------------
{
	my $ba = Lego::BrickArchitect->new( gentle => 0 );

	# three drawers: one good, one with no label.xml, one corrupt
	require IO::Compress::Zip;
	my $good_lbx = q{};
	my $zg = IO::Compress::Zip->new( \$good_lbx, Name => 'label.xml' );
	$zg->print('originalName="3005.png" ');
	$zg->close;
	my $empty_lbx = q{};
	my $ze = IO::Compress::Zip->new( \$empty_lbx, Name => 'Object0.bmp' );
	$ze->print('BM-no-label-xml-in-here');
	$ze->close;
	my $outer = q{};
	my $zo    = IO::Compress::Zip->new( \$outer,
		Name => 'LEGO_BRICK_LABELS-v40/ABOUT.txt' );
	$zo->print("about\n");
	$zo->newStream( Name => 'LEGO_BRICK_LABELS-v40/Labels/1. BASIC/GOOD.lbx' );
	$zo->print($good_lbx);
	$zo->newStream( Name => 'LEGO_BRICK_LABELS-v40/Labels/1. BASIC/EMPTY.lbx' );
	$zo->print($empty_lbx);
	$zo->newStream( Name => 'LEGO_BRICK_LABELS-v40/Labels/1. BASIC/BROKEN.lbx' );
	$zo->print('this is not a zip at all');
	$zo->close;

	my $warnings = q{};
	local $SIG{__WARN__} = sub { $warnings .= $_[0] };
	my ( $parts, $version ) = $ba->parse_legacy_zip($outer);
	is( $version, '40', 'the walk completed past the bad drawers' );
	is( $parts->{'3005'}{group}, 'GOOD', 'the good drawer is indexed' );
	is( scalar keys %{$parts}, 1, 'bad drawers contribute no parts' );
	like( $warnings, qr/no label\.xml in drawer 'EMPTY'/,
		'a drawer without label.xml warns' );
	like( $warnings, qr/no label\.xml in drawer 'BROKEN'/,
		'a corrupt .lbx warns the same way' );
	unlike( $warnings, qr/Use of uninitialized/,
		'no uninitialized-value warnings from bad drawers' );
}

# --- parsers: the decompression ceiling -----------------------------------------
{
	require IO::Compress::Zip;
	my $zip = q{};
	my $z   = IO::Compress::Zip->new( \$zip, Name => 'blob' );
	$z->print( 'x' x 100_000 );
	$z->close;

	my $ba = Lego::BrickArchitect->new(
		gentle           => 0,
		max_member_bytes => 10_000,
	);
	eval { $ba->parse_legacy_zip($zip) };
	like( $@, qr/zip member exceeds 10000 bytes while decompressing/,
		'oversized members die with the ceiling named' );
}

# --- entities: numeric refs are clamped ------------------------------------------
{
	my $warnings = q{};
	local $SIG{__WARN__} = sub { $warnings .= $_[0] };
	is( Lego::BrickArchitect::_decode_entities('&#99999999999;'), "\x{FFFD}",
		'absurd numeric entity clamps to the replacement char' );
	is( Lego::BrickArchitect::_decode_entities('&#x110000;'), "\x{FFFD}",
		'past the Unicode ceiling clamps too' );
	is( Lego::BrickArchitect::_decode_entities('&#8212;'), "\x{2014}",
		'valid numeric entities still decode' );
	is( $warnings, q{}, 'no warnings from clamping' );
}

# --- variant resolution (index + legacy) -----------------------------------------
{
	my $bytes = legacy_zip_bytes( angles => [3684] );
	my $ba = new_ba(
		ua => TestUa->new( responses => {} ) );
	my ( $parts, undef ) = $ba->parse_legacy_zip($bytes);
	# inject: exact 3684 and variant-based 3068b -> 3068
	$parts->{3068} = { category => 'BASIC', group => 'BASIC-tile_1' };

	ok( $ba->_lookup( 3684, $parts ), 'exact legacy hit' );
	ok( $ba->_lookup( '3068b', $parts ), 'variant falls back to the base number' );
	ok( !$ba->_lookup( 99, $parts ), 'miss returns undef' );
}

# --- search -----------------------------------------------------------------------
{
	my $ua = TestUa->new( responses => {
		"$BASE/parts/" => fixture('parts-index.html'),
		map { ( ba_url($_) => fixture('category-basic.html') ) } 1, 2, 12,
	} );
	my $ba = new_ba(
		ua         => $ua,
		categories => [1],
	);
	is( scalar @{ $ba->search('brick') }, 0,
		'search with no matches gives an empty list' );
	my $hits = $ba->search('300');
	is( scalar @{$hits}, 4, 'search matches part numbers by substring' );
	is( $hits->[0]{part_num}, '3004', 'search results sorted by part number' );
	is( $hits->[0]{name}, '1×2', 'number hits carry names' );
	is( scalar @{ $ba->search('86996') }, 1, 'exact number hit' );

	# terms with spaces and non-word punctuation must match literally
	# (this is the regression test for the quotemeta+\Q..\E double escape)
	is( scalar @{ $ba->search('2×2 Corner') }, 1,
		'search term with a space and punctuation matches' );
	is( $ba->search('2×2 Corner')->[0]{part_num}, '2357',
		'the spacey name is the hit' );
	is( scalar @{ $ba->search('1×3') }, 2,
		'punctuation-only terms are not mangled' );
	is( scalar @{ $ba->search('no such part') }, 0,
		'multi-word misses stay misses' );

	eval { $ba->search(q{}) };
	like( $@, qr/no term given/, 'empty search term dies' );
}

# --- part lookup: alias, 404, validation ------------------------------------------
{
	# /parts/3684 answers with 98560's page: the guide redirects old
	# numbers to modern ones, and the page h1 states the canonical number.
	my $redirected = fixture('part-3023.html');
	$redirected =~ s/\(Part 3023\)/(Part 98560)/;
	$redirected =~ s{parts/3023}{parts/98560}g;
	$redirected =~ s{label/3023}{label/98560}g;
	my $ua = TestUa->new( responses => {
		"$BASE/parts/3684"   => $redirected,
		"$BASE/parts/3023"   => fixture('part-3023.html'),
	} );

	my $ba   = new_ba( ua => $ua );
	my $row  = $ba->part('3684');
	is( $row->{part_num}, '98560', 'canonical number parsed from the page' );
	is( $row->{alias}, '98560', 'redirect alias reported' );
	is( $row->{requested_num}, '3684', 'requested number kept' );
	is( $row->{url}, "$BASE/parts/98560", 'URL points at the canonical page' );

	is( $ba->part('3023')->{name}, '1×2 Plate', 'plain lookup, no alias' );
	ok( !exists $ba->part('3023')->{alias}, 'no alias key when numbers agree' );
	is( $ba->part('no-such-page'), undef, 'missing label page gives undef' );

	eval { $ba->part('3684/colors') };
	like( $@, qr/invalid part number/, 'part number with a slash dies' );
	is( $ua->request_count("$BASE/parts/3684/colors"), 0,
		'no request for malformed input' );
}

# --- cache: roundtrip, 404 sentinel, refresh, offline -------------------------------
{
	my $dir = File::Temp->newdir;

	my $live = new_ba(
		cache_dir => "$dir",
		ua        => TestUa->new( responses => {
			"$BASE/parts/3023" => fixture('part-3023.html'),
		} ),
	);
	is( $live->part('3023')->{name}, '1×2 Plate', 'live (mocked) lookup works' );
	is( $live->part('nope'), undef, '404 under a live client' );

	# everything is cached now; replay with no transport at all
	my $offline = new_ba(
		cache_dir => "$dir", offline => 1,
	);
	is( $offline->part('3023')->{name}, '1×2 Plate',
		'cached page replays offline' );
	is( $offline->part('3023')->{alias}, undef,
		'alias detection is redirect-free (works offline)' );
	is( $offline->part('nope'), undef, 'cached 404 replays as undef offline' );

	eval { $offline->part('also-nope') };
	like( $@, qr/offline mode: no cached response/,
		'offline cache miss dies' );

	# refresh re-hits the transport even with a warm cache
	my $ua2 = TestUa->new( responses => {
		"$BASE/parts/3023" => fixture('part-3023.html'),
	} );
	my $warm = new_ba( cache_dir => "$dir", ua => $ua2 );
	$warm->part('3023');
	is( $ua2->request_count("$BASE/parts/3023"), 0,
		'cached run skips the transport' );
	my $ua3 = TestUa->new( responses => {
		"$BASE/parts/3023" => fixture('part-3023.html'),
	} );
	new_ba( cache_dir => "$dir", refresh => 1, ua => $ua3 )
		->part('3023');
	is( $ua3->request_count("$BASE/parts/3023"), 1,
		'refresh re-hits the transport' );

	# cache writes are atomic: no temp files survive
	my @leftovers = grep { m{\.tmp} } glob "$dir/*";
	is( scalar @leftovers, 0, 'no temp files left behind after cache writes' );

	# binary bodies (the legacy zip) roundtrip byte-for-byte
	my $zip = legacy_zip_bytes( angles => [3684] );
	my $ua4 = TestUa->new( responses => {} );
	my $zip_url = 'https://brickarchitect.com/files/LEGO_BRICK_LABELS.zip';
	$ua4->{responses}{$zip_url} = $zip;
	my $live2 = new_ba( cache_dir => "$dir", ua => $ua4 );
	is( $live2->legacy_lookup('3684')->{group}, 'ANGLE-slope',
		'legacy index built from a fetched zip' );

	# the cached zip must be the exact payload - no trailing-newline padding
	# appended to binary bodies
	my $zip_cache = File::Spec->catfile( "$dir",
		Digest::SHA::sha1_hex($zip_url) . '.zip' );
	open my $zf, '<', $zip_cache or die "cannot read $zip_cache: $!";
	binmode $zf;
	local $/;
	my $cached_zip = <$zf>;
	close $zf;
	is( length $cached_zip, length $zip,
		'binary cache entries are byte-exact, not newline-padded' );

	my $offline2 = new_ba(
		cache_dir => "$dir", offline => 1 );
	is( $offline2->legacy_lookup('3684')->{group}, 'ANGLE-slope',
		'legacy zip replays from the binary cache offline' );
	is( $offline2->legacy_version, '40', 'legacy version replays offline' );
}

# --- gentle pacing between live fetches ------------------------------------------
{
	my $ua = TestUa->new( responses => {
		"$BASE/parts/slow1" => 'one',
		"$BASE/parts/slow2" => 'two',
	} );
	my $gentle = Lego::BrickArchitect->new( ua => $ua );    # gentle default
	my $start = time;
	$gentle->get("$BASE/parts/slow1");
	$gentle->get("$BASE/parts/slow2");
	cmp_ok( time - $start, '>=', 0.9,
		'gentle mode (default) pauses a second between live fetches' );

	my $fast = Lego::BrickArchitect->new( ua => $ua, gentle => 0 );
	my $start2 = time;
	$fast->get("$BASE/parts/slow1");
	$fast->get("$BASE/parts/slow2");
	cmp_ok( time - $start2, '<', 0.9, 'gentle => 0 fetches back to back' );
}

# --- server errors die with the status; missing SSL says so ---------------------
{
	{
		package ServerErrorUa;
		sub new { return bless { requests => [] }, shift }
		sub get {
			my ( $self, $url ) = @_;
			push @{ $self->{requests} }, { url => $url };
			return { success => 0, status => 500, reason => 'Internal Server Error',
				content => q{} };
		}
	}

	my $ba = new_ba( ua => ServerErrorUa->new );
	eval { $ba->part('3023') };
	like( $@, qr{GET \Q$BASE/parts/3023\E failed: 500 Internal Server Error},
		'non-404 errors die with status and reason' );
	is( scalar @{ $ba->{ua}{requests} }, 1, 'the request was attempted once' );

	# HTTP::Tiny's 599 with no SSL stack: name the fix instead of the code
	{
		package SsllessUa;
		sub new { return bless {}, shift }
		sub get {
			return { success => 0, status => 599, reason => 'Internal Exception',
				content => q{} };
		}
	}
	no warnings 'redefine';
	local *HTTP::Tiny::can_ssl = sub { 0 };
	my $no_ssl = new_ba( ua => SsllessUa->new );
	eval { $no_ssl->get("$BASE/parts/3023") };
	like( $@, qr/lacks HTTPS support.*IO::Socket::SSL.*Net::SSLeay/s,
		'599 without SSL support explains the install' );
}

# --- corrupt cache entries ------------------------------------------------------
{
	my $dir = File::Temp->newdir;

	# empty file for one URL, undecodable bytes for another
	my $empty = File::Spec->catfile( "$dir",
		Digest::SHA::sha1_hex("$BASE/parts/3023") . '.html' );
	open my $fh, '>', $empty or die "cannot write $empty: $!";
	print {$fh} q{};
	close $fh;
	my $bad = File::Spec->catfile( "$dir",
		Digest::SHA::sha1_hex("$BASE/parts/3005") . '.html' );
	open my $fh2, '>', $bad or die "cannot write $bad: $!";
	binmode $fh2;
	print {$fh2} "not \xc3\x28 utf8";
	close $fh2;

	my $warnings = q{};
	local $SIG{__WARN__} = sub { $warnings .= $_[0] };
	my $api = new_ba(
		cache_dir => "$dir",
		ua        => TestUa->new( responses => {
			"$BASE/parts/3023" => fixture('part-3023.html'),
			"$BASE/parts/3005" => fixture('part-3023.html'),
		} ),
	);
	is( $api->part('3023')->{name}, '1×2 Plate',
		'empty cache entry is refetched' );
	like( $warnings, qr/empty cache file/, 'empty cache entry warns' );
	$warnings = q{};
	$api->part('3005');
	like( $warnings, qr/invalid UTF-8 in cache file/,
		'undecodable cache entry warns and is refetched' );

	# the refetches replaced both corrupt files, so offline replay works
	my $offline = new_ba(
		cache_dir => "$dir", offline => 1 );
	is( $offline->part('3005')->{name}, '1×2 Plate',
		'refetch replaced the corrupt cache file' );

	# but offline + a corrupt cache nothing can repair dies loudly
	my $bad2 = File::Spec->catfile( "$dir",
		Digest::SHA::sha1_hex("$BASE/parts/3006") . '.html' );
	open my $fh3, '>', $bad2 or die "cannot write $bad2: $!";
	binmode $fh3;
	print {$fh3} "still \xc3\x28 not utf8";
	close $fh3;
	eval { $offline->part('3006') };
	like( $@, qr/invalid UTF-8 in cache file .* \(offline mode\)/,
		'offline corrupt cache entry dies' );
}

# --- the default transport follows redirects -------------------------------------
{
	my $ba = Lego::BrickArchitect->new;
	is( $ba->{ua}{max_redirect}, 5,
		'default transport follows redirects (the guide canonicalizes numbers)' );
}

done_testing();

#!/usr/bin/env perl
# Lego::Rebrickable client behavior with mock transports and the disk
# cache - no network access anywhere in this test.

use strict;
use warnings;

use Digest::SHA ();
use File::Spec  ();
use File::Temp  ();
use JSON::PP    qw(encode_json);
use Test::More;

use Lego::Rebrickable;

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
		push @{ $self->{requests} },
			{ url => $url, headers => $options->{headers} };
		if ( my $response = $self->{responses}{$url} ) {
			return { success => 1, status => 200, reason => 'OK',
				content => $response };
		}
		return { success => 0, status => 404, reason => 'Not Found',
			content => '{"detail": "not found"}' };
	}
}

# A transport whose every request fails with 403, like the removed MOC
# endpoints described in https://github.com/fini-net/chicks-bricks/issues/2.
{
	package ForbiddenUa;    ## no critic (ProhibitMultiplePackages) -- test mock

	sub new { return bless { requests => [] }, shift }

	sub get {
		my ( $self, $url, $options ) = @_;
		push @{ $self->{requests} }, { url => $url };
		return { success => 0, status => 403, reason => 'Forbidden',
			content => '{"detail": "You do not have permission"}' };
	}
}

my $BASE = 'https://api.test/v3';

sub json_page {
	my ( $rows, $next ) = @_;
	return encode_json(
		{ count => scalar @{$rows}, next => $next, results => $rows } );
}

# --- get_all follows pagination -------------------------------------------
{
	my %pages = (
		"$BASE/lego/parts/9999/colors/?page_size=1000" => json_page(
			[ { color_id => 0, color_name => 'Black' } ],
			"$BASE/lego/parts/9999/colors/?page=2&page_size=1000",
		),
		"$BASE/lego/parts/9999/colors/?page=2&page_size=1000" =>
			json_page( [ { color_id => 15, color_name => 'White' } ], undef ),
	);
	my $ua  = TestUa->new( responses => \%pages );
	my $api = Lego::Rebrickable->new(
		base_url => $BASE, api_key => 'k', ua => $ua,
	);
	my $rows = $api->part_colors('9999');
	is( scalar @{$rows}, 2, 'get_all concatenates pages' );
	is( $rows->[1]{color_name}, 'White', 'second page rows included' );
	is( scalar @{ $ua->{requests} }, 2, 'one request per page' );
	is( $ua->{requests}[0]{headers}{Authorization}, 'key k',
		'authorization header carries the API key' );
}

# --- unknown part returns undef --------------------------------------------
{
	my $api = Lego::Rebrickable->new(
		base_url => $BASE, api_key => 'k',
		ua => TestUa->new( responses => {} ),
	);
	is( $api->part_colors('nope'), undef, 'unknown part gives undef, not death' );
}

# --- server errors die with the API detail ----------------------------------
{
	my $api = Lego::Rebrickable->new(
		base_url => $BASE, api_key => 'k',
		ua => ForbiddenUa->new,
	);
	eval { $api->part_colors('9999') };
	like( $@, qr/403 Forbidden \(You do not have permission\)/,
		'403 dies with the API detail message' );
}

# --- cache roundtrip: live-with-mock then offline ---------------------------
{
	my $dir = File::Temp->newdir;

	my $live = Lego::Rebrickable->new(
		base_url  => $BASE,
		api_key   => 'k',
		cache_dir => "$dir",
		ua        => TestUa->new( responses => {} ),
	);
	is( $live->part_colors('nope'), undef, '404 under a live client' );

	# Same contract pin as t/brickarchitect.t, for the sub that actually
	# bare-returns (get_json; the memoized accessors like part_colors
	# return a scalar expression, which stays (undef) in list context):
	# a 404 is an empty list, not a one-element true list.
	my @missing = $live->get_json("$BASE/lego/parts/absent/colors/");
	is( scalar @missing, 0, '404 get_json in list context: empty list' );

	# the 404 is now cached; replay it with no key and no transport
	my $offline = Lego::Rebrickable->new(
		base_url  => $BASE,
		api_key   => undef,
		cache_dir => "$dir",
		offline   => 1,
	);
	is( $offline->part_colors('nope'), undef,
		'cached 404 replays as undef in offline mode' );

	# a URL that was never cached must die in offline mode, not go fishing
	eval { $offline->part_colors('also-nope') };
	like( $@, qr/offline mode: no cached response/,
		'offline cache miss dies' );
}

# --- refresh bypasses the cache ---------------------------------------------
{
	my $dir = File::Temp->newdir;

	my $ua1 = TestUa->new( responses => {} );
	Lego::Rebrickable->new(
		base_url => $BASE, api_key => 'k', cache_dir => "$dir", ua => $ua1,
	)->part_colors('nope');    # populates the 404 sentinel
	is( scalar @{ $ua1->{requests} }, 1, 'first run hits the API' );

	my $ua2 = TestUa->new( responses => {} );
	Lego::Rebrickable->new(
		base_url => $BASE, api_key => 'k', cache_dir => "$dir", ua => $ua2,
	)->part_colors('nope');
	is( scalar @{ $ua2->{requests} }, 0, 'cached run skips the API' );

	my $ua3 = TestUa->new( responses => {} );
	Lego::Rebrickable->new(
		base_url => $BASE, api_key => 'k', cache_dir => "$dir",
		refresh  => 1, ua => $ua3,
	)->part_colors('nope');
	is( scalar @{ $ua3->{requests} }, 1, 'refresh re-hits the API' );
}

# --- missing API key --------------------------------------------------------
{
	local $ENV{REBRICKABLE_API_KEY};    # unset for this block
	my $api = Lego::Rebrickable->new(
		base_url => $BASE, ua => TestUa->new,
	);
	eval { $api->get_json("$BASE/lego/colors/") };
	like( $@, qr/no Rebrickable API key/, 'missing API key dies' );
}

# --- invalid part/set numbers never reach the network ------------------------
{
	my $ua  = TestUa->new( responses => {} );
	my $api = Lego::Rebrickable->new(
		base_url => $BASE, api_key => 'k', ua => $ua,
	);
	eval { $api->part_colors('3684/colors') };
	like( $@, qr/invalid part number/, 'part number with a slash dies' );
	eval { $api->part_colors('3684?x=1') };
	like( $@, qr/invalid part number/, 'part number with a query dies' );
	eval { $api->part_colors(undef) };
	like( $@, qr/invalid part number/, 'undef part number dies' );
	eval { $api->set_parts('850425-1#frag') };
	like( $@, qr/invalid set number/, 'set number with a fragment dies' );
	is( scalar @{ $ua->{requests} }, 0, 'no requests were made for bad input' );
}

# --- pagination is never followed off base_url -------------------------------
{
	my %pages = (
		"$BASE/lego/parts/9999/colors/?page_size=1000" => json_page(
			[ { color_id => 0, color_name => 'Black' } ],
			'https://evil.example/v3/lego/parts/9999/colors/?page=2',
		),
	);
	my $api = Lego::Rebrickable->new(
		base_url => $BASE, api_key => 'k',
		ua => TestUa->new( responses => \%pages ),
	);
	eval { $api->part_colors('9999') };
	like( $@, qr/refusing to follow pagination to .*evil\.example/,
		'off-site pagination next URL dies' );
}

# --- the default transport refuses redirects ----------------------------------
{
	my $api = Lego::Rebrickable->new;
	is( $api->{ua}{max_redirect}, 0,
		'default transport does not follow redirects (protects the API key)' );
}

# --- cache writes are atomic: no temp files survive ---------------------------
{
	my $dir = File::Temp->newdir;
	Lego::Rebrickable->new(
		base_url => $BASE, api_key => 'k', cache_dir => "$dir",
		ua => TestUa->new( responses => {} ),
	)->part_colors('nope');
	my @leftovers = grep { m{\.tmp} } glob "$dir/*";
	is( scalar @leftovers, 0, 'no temp files left behind after cache writes' );
	ok( scalar( grep { m{\.json\z} } glob "$dir/*" ),
		'cache file was installed via rename' );
}

# --- corrupt cache entries: warn and refetch (die offline) --------------------
{
	my $dir  = File::Temp->newdir;
	my $url  = "$BASE/lego/parts/42/colors/?page_size=1000";
	my $file = File::Spec->catfile( "$dir", Digest::SHA::sha1_hex($url) . '.json' );
	open my $fh, '>', $file or die "cannot write $file: $!";
	print {$fh} 'not json at all';
	close $fh;

	my %pages
		= ( $url => json_page( [ { color_id => 1, color_name => 'Blue' } ], undef ) );
	my $warnings = q{};
	local $SIG{__WARN__} = sub { $warnings .= $_[0] };
	my $api = Lego::Rebrickable->new(
		base_url => $BASE, api_key => 'k', cache_dir => "$dir",
		ua => TestUa->new( responses => \%pages ),
	);
	my $rows = $api->part_colors('42');
	is( $rows->[0]{color_name}, 'Blue', 'corrupt cache entry is refetched' );
	like( $warnings, qr/invalid JSON in cache file/,
		'corrupt cache entry warns' );

	# the refetch replaces the corrupt file, so offline replay works now
	my $offline = Lego::Rebrickable->new(
		base_url => $BASE, cache_dir => "$dir", offline => 1, api_key => 'k',
	);
	is( $offline->part_colors('42')->[0]{color_name}, 'Blue',
		'refetch replaced the corrupt cache file' );

	# but offline + corrupt cache (no refetch possible) dies loudly
	my $url2  = "$BASE/lego/parts/43/colors/?page_size=1000";
	my $file2 = File::Spec->catfile( "$dir", Digest::SHA::sha1_hex($url2) . '.json' );
	open my $fh2, '>', $file2 or die "cannot write $file2: $!";
	print {$fh2} '{ still not json';
	close $fh2;
	eval { $offline->part_colors('43') };
	like( $@, qr/invalid JSON in cache file .* \(offline mode\)/,
		'offline corrupt cache entry dies' );
}

done_testing();

package Lego::BrickArchitect;

# Client for Tom Alphin's Brick Architect label collections:
#
#   https://brickarchitect.com/parts/   - the LEGO Parts Guide (current;
#                                         ~2900 categorized parts plus
#                                         search-only ones)
#   https://brickarchitect.com/labels/  - LEGO Brick Labels v40 (legacy,
#                                         frozen December 2023, ~1800 labels)
#
# Uses core Perl modules only (HTTP::Tiny, IO::Uncompress::Unzip, Encode).
# Every response is cached on disk as one file per URL, so repeat runs and
# the offline test suite never touch the network.  404s are cached too (as a
# sentinel body), so "part not found" answers replay offline - but a
# sentinel past notfound_ttl is re-checked on the next online run, since
# the guide keeps adding parts.
#
# Unlike Lego::Rebrickable, redirects ARE followed here: the guide
# canonicalizes old part numbers with 301s (/parts/3684 -> /parts/98560),
# and no credentials ride on these requests.  part() reports the alias.
#
# The guide's markup is machine-generated and regular; the parsers below
# are deliberately small and die loudly if a page's layout ever drifts.
# The legacy index is built from the freely-downloaded
# LEGO_BRICK_LABELS.zip: each Labels/*/*.lbx inside is itself a zip whose
# label.xml names its part images after part numbers.
# Label files are never redistributed - only their part numbers are read.

use strict;
use warnings;

use Carp                   qw(croak);
use Digest::SHA            qw(sha1_hex);
use Encode                 qw(decode);
use File::Path             qw(make_path);
use File::Spec             ();
use HTTP::Tiny             ();
use IO::Uncompress::Unzip  qw($UnzipError);
use Time::HiRes            qw(time sleep);
use Lego::Constants        qw($SAFE_NUMBER);
use Lego::PartsList        ();

our $VERSION = '0.01';

my $DEFAULT_BASE = 'https://brickarchitect.com';
my $LEGACY_ZIP   = 'https://brickarchitect.com/files/LEGO_BRICK_LABELS.zip';

# Cached 404 body: recognizable by _read_cache, meaningless to anyone else.
my $NOT_FOUND_BODY = "__BRICKARCHITECT_NOT_FOUND__\n";

# Decompression cap: zip members are read into memory, so a corrupted or
# hostile download could otherwise balloon.  The largest real member is
# about 1.5 MB, so 64 MiB is generous headroom while still bounded.
# Deliberately per MEMBER, not cumulative: each member is drained and
# released before the next, so peak memory is the zip plus the largest
# single member - a total budget would bound work, not peak memory.
# Overridable per client (tests set it low to exercise the guard).
my $MAX_MEMBER_BYTES = 64 * 1024 * 1024;

# Cached 404s go stale after 30 days: the guide keeps adding parts, so a
# remembered "no label" is worth re-checking occasionally, while successful
# responses never expire (nothing is re-fetched without refresh - the
# fetch-gently etiquette).  Overridable per client (tests set it low; 0
# disables expiry).
my $NOT_FOUND_TTL = 30 * 24 * 60 * 60;

sub new {
	my ( $class, %args ) = @_;
	my $ua = $args{ua} || HTTP::Tiny->new(
		timeout        => 30,
		max_redirect   => 5,    # the guide 301s old part numbers onward
		agent          => "chicks-bricks/$VERSION (+https://github.com/fini-net/chicks-bricks)",
	);
	my $self = bless {
		base_url  => $args{base_url} || $DEFAULT_BASE,
		cache_dir => $args{cache_dir},
		refresh   => $args{refresh} ? 1 : 0,
		offline   => $args{offline} ? 1 : 0,
		ua        => $ua,
		# Pause between consecutive live fetches (issue #5: "fetch
		# gently" - the site is one person's project).  Cache hits do
		# not pause; tests disable it to stay fast.
		gentle    => exists $args{gentle} ? ( $args{gentle} ? 1 : 0 ) : 1,
		# Category ids to crawl instead of discovering them from /parts
		# (tests pass one id so a single fixture page serves the index).
		categories => $args{categories},
		# Zip-member decompression ceiling (see $MAX_MEMBER_BYTES).
		max_member_bytes => $args{max_member_bytes} || $MAX_MEMBER_BYTES,
		# Seconds a cached 404 stays authoritative; 0 = never expires
		# (see $NOT_FOUND_TTL).
		notfound_ttl =>
			defined $args{notfound_ttl} ? $args{notfound_ttl} : $NOT_FOUND_TTL,
	}, $class;
	$self->{base_url} =~ s{/+\z}{};
	return $self;
}

# --- fetching ---------------------------------------------------------------

# Fetch one absolute URL, honoring the cache.  Returns the body (decoded as
# UTF-8 text unless binary => 1), or undef for a 404.  Dies on other errors
# and on cache misses in offline mode.  Cached 404s older than notfound_ttl
# are re-checked when online.
sub get {
	my ( $self, $url, %args ) = @_;
	my $ext = $args{ext} || 'html';

	if ( defined $self->{cache_dir} ) {
		my $cache_file = $self->_cache_path( $url, $ext );
		if ( !$self->{refresh} && -f $cache_file ) {
			my ( $data, $status, $error ) = $self->_read_cache( $cache_file, $args{binary} ? 0 : 1 );
			if ( $status eq 'corrupt' ) {
				croak "$error (offline mode)" if $self->{offline};
				warn "$error - ignoring, refetching\n";
			}
			elsif ( $status eq 'notfound' ) {
				# A cached 404 replays offline (nothing else to ask) and
				# while fresh; past its TTL an online run re-checks the
				# guide - it keeps adding parts, so "no label" answers
				# go stale.  The refetch below re-caches either answer,
				# which resets the entry's clock.
				return undef
					if $self->{offline}
					|| !$self->{notfound_ttl}
					|| time - ( stat $cache_file )[9] < $self->{notfound_ttl};
				warn "cached 404 for $url has expired - re-checking\n";
			}
			else {
				return $data;
			}
		}
	}

	croak "offline mode: no cached response for $url" if $self->{offline};

	# Fetch gently: after a live fetch, give the site a second of rest
	# before the next one.  First-ever fetch and cache hits are immediate.
	if ( $self->{gentle} && defined $self->{_last_fetch} ) {
		my $elapsed = time - $self->{_last_fetch};
		sleep 1 - $elapsed if $elapsed < 1;
	}

	my $response = $self->{ua}->get($url);
	$self->{_last_fetch} = time;
	if ( $response->{status} == 404 ) {
		$self->_cache_write( $url, $NOT_FOUND_BODY, $ext );
		return undef;
	}
	if ( !$response->{success} ) {
		my $reason = $response->{reason} // 'unknown error';
		# HTTP::Tiny's 599 means its own transport failed; for https that
		# is usually missing IO::Socket::SSL/Net::SSLeay, which are not
		# core on every perl.  Name the fix instead of the bare status.
		if (   $response->{status} == 599
			&& !HTTP::Tiny->can_ssl
			&& $url =~ m{\Ahttps://} )
		{
			croak "GET $url failed: this perl lacks HTTPS support - "
				. 'install IO::Socket::SSL and Net::SSLeay '
				. '(e.g. cpan IO::Socket::SSL Net::SSLeay)';
		}
		croak "GET $url failed: $response->{status} $reason";
	}
	$self->_cache_write( $url, $response->{content}, $ext,
		$args{binary} ? 1 : 0 );
	return $args{binary}
		? $response->{content}
		: decode( 'UTF-8', $response->{content} );
}

# The 12 categories of the parts guide, discovered from the /parts/ index
# page so new categories appear automatically.  Each entry: { id, name }.
sub categories {
	my ($self) = @_;
	return $self->{_categories} //= do {
		my @cats;
		if ( $self->{categories} ) {
			@cats = map { { id => $_ } } @{ $self->{categories} };
		}
		else {
			my $html = $self->get("$self->{base_url}/parts/")
				or croak 'GET /parts/ failed - is the site reachable?';
			while ( $html =~ m{<a\s+href="[^"]*/parts/category-(\d+)(?:\?[^"]*)?"\s+class="categorylistitem">.*?<div class="categorylistitem_name">([^<]+)</div>}gs ) {
				push @cats, { id => $1, name => $2 };
			}
			croak 'no categories found on the parts guide index page - '
				. 'did the layout change?'
				if !@cats;
		}
		\@cats;
	};
}

sub category_url {
	my ( $self, $id ) = @_;
	$id =~ m{\A\d+\z}
		or croak "invalid category id '$id'";
	# The literal '?&retired=1' (empty first parameter) is how the guide
	# spells its "include retired parts" view; keep it byte-for-byte so
	# cache keys stay stable.
	return "$self->{base_url}/parts/category-$id?&retired=1";
}

# Every part the guide has organized into a category, as a hashref of
# part_num => row.  Rows carry the Alphin name, category/subcategory/group
# breadcrumb, guide URL, and the new/retired markers.  Memoized: one crawl
# (13 requests) per process, and not at all across runs thanks to the
# cache.  Parts that live outside the category system (the guide's search
# knows more than its categories list) are reachable through part().
sub index {
	my ($self) = @_;
	return $self->{_index} //= do {
		my %index;
		for my $cat ( @{ $self->categories } ) {
			my $html = $self->get( $self->category_url( $cat->{id} ) );
			croak 'GET category page for ', $cat->{name} // $cat->{id},
				' failed - is the site reachable?'
				if !defined $html;
			my $rows = $self->parse_category_page($html);
			for my $num ( sort keys %{ $rows->{parts} } ) {
				# The guide currently lists each part exactly once; a
				# duplicate would mean the layout changed, so say so and
				# keep the first home.
				if ( $index{$num} ) {
					warn "part $num listed in both "
						. "$index{$num}{category} and $rows->{category} "
						. "- keeping the first\n";
					next;
				}
				$index{$num} = $rows->{parts}{$num};
			}
		}
		croak 'the parts guide index came back empty - did the layout change?'
			if !%index;
		\%index;
	};
}

# Find one part number in the index, trying Lego::PartsList variants
# (3068b -> 3068, 4865b -> 4865) when the exact number is absent.
# Returns the index row (which includes part_num) or undef.
sub index_lookup {
	my ( $self, $num ) = @_;
	return $self->_lookup( $num, $self->index );
}

# One part's label page, fetched fresh (from the network or the cache).
# Returns a hashref with name, breadcrumb, legacy membership, label URL,
# and - when the guide redirected an old number - the alias it resolved
# to.  undef means the guide has no page for this part number.
#
# The alias comes from the page's own <h1>, which states the canonical
# part number ("Part 98560"); that works offline from cache, unlike
# inspecting the HTTP redirect chain.
sub part {
	my ( $self, $num ) = @_;
	_check_part_num($num);

	my $url  = "$self->{base_url}/parts/$num";
	my $body = $self->get($url);
	return undef if !defined $body;

	my $row = $self->parse_part_page($body);
	$row->{requested_num} = $num;
	# alias only exists when the guide redirected an old number onward
	$row->{alias} = $row->{part_num} if $row->{part_num} ne $num;
	$row->{url} = defined $row->{alias}
		? "$self->{base_url}/parts/$row->{part_num}"
		: $url;
	return $row;
}

# --- legacy collection ------------------------------------------------------

# The frozen v40 collection: { version => '40', parts => { part_num => row } }
# where each row names the legacy category and the drawer (.lbx group) the
# label lives in.  The 20 MB zip is downloaded once and cached; only part
# numbers are retained, never the labels themselves.  (The zip bytes are
# held in memory a few times over - cached copy, parse buffer, per-member
# data - roughly 80 MB peak, which beats inventing a streaming archive
# layout for a once-per-collection cost.)
sub legacy_index {
	my ($self) = @_;
	return $self->{_legacy} //= do {
		my $zip = $self->get( $LEGACY_ZIP, ext => 'zip', binary => 1 );
		croak "GET $LEGACY_ZIP failed - is the site reachable?" if !defined $zip;
		my ( $parts, $version ) = $self->parse_legacy_zip($zip);
		croak 'the legacy labels zip yielded no parts - did its layout change?'
			if !%{$parts};
		{ version => $version, parts => $parts };
	};
}

sub legacy_lookup {
	my ( $self, $num ) = @_;
	return $self->_lookup( $num, $self->legacy_index->{parts} );
}

sub legacy_version { return $_[0]->legacy_index->{version} }

# --- search ------------------------------------------------------------------

# Case-insensitive substring match over the index names and part numbers.
# Returns an arrayref of index rows sorted by part number.  The term is
# quotemeta-escaped once (via \Q..\E) and precompiled, so spaces and
# punctuation in terms like "2×2 Corner" or "w/ 2-Studs" match literally
# without recompiling the regex for every row.
sub search {
	my ( $self, $term ) = @_;
	croak 'search: no term given' if !defined $term || !length $term;
	my $needle = lc $term;
	my $re     = qr/\Q$needle\E/;
	my @hits = grep {
		( defined $_->{name} && lc( $_->{name} ) =~ $re )
			|| ( lc( $_->{part_num} ) =~ $re )
	} values %{ $self->index };
	return [ sort { $a->{part_num} cmp $b->{part_num} } @hits ];
}

# --- parsers -----------------------------------------------------------------
# Pure functions on page bodies; every one is fixture-tested.  They are
# methods only so tests can call them on a client with no network at all.

# A category page: { category => NAME, parts => { part_num => row } }.
# Rows: part_num, name, category, subcategory, group, url, is_new, retired.
# Parts may sit directly under an <h2> subcategory with no <h3> group
# (the guide's "Blate" section does this), so group is optional.
sub parse_category_page {
	my ( $self, $html ) = @_;
	my ($category) = $html =~ m{<div class="resultsheadercount"><strong>([^<]+)</strong>};
	croak 'category page: no resultsheadercount header - did the layout change?'
		if !defined $category;

	my %parts;
	my ( $subcat, $group ) = ( undef, undef );
	# Single-line and /x-free on purpose: the markup patterns contain
	# literal spaces ("div class=...") that /x would silently strip.
	# The alternation walks the page in document order; the shapes it
	# matches, verbatim from a category page:
	#   <h2 class="partcategoryname" ...><a ...>Brick</a></h2>     (subcategory)
	#   <h3 class="partcategoryname" ...>... <a ...>1× Brick</a></h3>   (group)
	#   <a href=".../parts/3005?&retired=1"><div class="partcontainer">
	#     ... <div class="partname">1×1</div><div class="partnum">3005
	#     <div class="retired indicator">R</div></div>...</a>     (part row)
	my $row_re = qr{<h([23])\s+class="partcategoryname"[^>]*>(.*?)</h\1>|<a\s+href="[^"]*/parts/([\w.-]+)(?:\?[^"]*)?"[^>]*>(?:(?!</a>|<a\s).)*?<div class="partname">([^<]*)</div>\s*<div class="partnum">[^<]*(?:<div class="(new|retired) indicator">)?}s;
	while ( $html =~ /$row_re/g ) {
		if ( defined $1 ) {    # subcategory (h2) or group (h3) header
			my ( $level, $inner ) = ( $1, $2 );
			my ($text) = $inner =~ m{<a[^>]*>([^<]+)</a>};
			next if !defined $text;
			if ( $level eq '2' ) { $subcat = $text; $group = undef }
			else                 { $group = $text }
		}
		elsif ( defined $3 ) {    # one part row
			my ( $num, $name, $indicator ) = ( $3, _decode_entities($4), $5 );
			$parts{$num} = {
				part_num    => $num,
				name        => $name,
				category    => $category,
				( defined $subcat ? ( subcategory => $subcat ) : () ),
				( defined $group  ? ( group       => $group )  : () ),
				url         => "$self->{base_url}/parts/$num",
				is_new      => ( defined $indicator && $indicator eq 'new' )    ? 1 : 0,
				retired     => ( defined $indicator && $indicator eq 'retired' ) ? 1 : 0,
			};
		}
	}
	return { category => $category, parts => \%parts };
}

# A part page: name, breadcrumb (category/subcategory/group), in_legacy,
# label_url (the non-QR .lbx download), and part_num as the page states it.
sub parse_part_page {
	my ( $self, $html ) = @_;
	my ( $name, $num ) = $html =~ m{<h1>([^<]+) <span[^>]*>\(Part ([\w.-]+)\)</span></h1>};
	croak 'part page: no <h1> part header - did the layout change?'
		if !defined $name;

	my ( @crumbs, $in_legacy, $label_num );
	if ( $html =~ m{class="chapternav"[^>]*>(.*?)</div>}s ) {
		@crumbs = $1 =~ m{<a[^>]*>([^<]+)</a>}g;
		shift @crumbs;    # "The LEGO Parts Guide" is not part of the trail
	}
	$in_legacy
		= $html =~ /Not included in legacy/ ? 0
		: $html =~ /Included in legacy/    ? 1
		:                                  undef;
	for my $n ( $html =~ m{/label/([\w.-]+)\.lbx}g ) {
		next if $n =~ /-qr\z/;
		$label_num = $n;
		last;
	}

	return {
		part_num    => $num,
		name        => _decode_entities($name),
		( @crumbs >= 1 ? ( category    => _decode_entities( $crumbs[0] ) ) : () ),
		( @crumbs >= 2 ? ( subcategory => _decode_entities( $crumbs[1] ) ) : () ),
		( @crumbs >= 3 ? ( group       => _decode_entities( $crumbs[2] ) ) : () ),
		( defined $in_legacy ? ( in_legacy => $in_legacy ) : () ),
		( defined $label_num ? ( label_url => "$self->{base_url}/label/$label_num.lbx" ) : () ),
	};
}

# The legacy labels zip: { part_num => { category, group } } plus version.
# Structure: Labels/<N. CATEGORY>/<GROUP>.lbx, where each .lbx is itself a
# zip whose label.xml embeds part images named originalName="<part>.png".
#
# IO::Uncompress::Unzip iteration has two sharp edges, both learned the hard
# way (see the fixture tests): a fresh object starts at the FIRST member
# (so read it before calling nextStream), and each member must be drained
# to EOF or the walk stops early.  nextStream returning 0 or -1 ends the
# walk - a -1 left unhandled spins forever.
sub parse_legacy_zip {
	my ( $self, $zip_bytes ) = @_;
	croak 'parse_legacy_zip: no zip data given' if !defined $zip_bytes;

	my ( %parts, $version );
	my $z = IO::Uncompress::Unzip->new(\$zip_bytes)
		or croak "cannot open legacy labels zip: $UnzipError";
	my $max = $self->{max_member_bytes};
	while (1) {
		# Unzip defers garbage detection: new() can succeed on non-zip
		# bytes and only getHeaderInfo gives undef - so guard it.
		my $info = $z->getHeaderInfo;
		croak 'cannot open legacy labels zip: unreadable member headers '
			. '(is the download corrupt?)'
			if !defined $info;
		my $name = $info->{Name} // q{};
		my $data = _drain( $z, $max );
		( $name =~ /LEGO_BRICK_LABELS-v(\d+)/i ) && ( $version //= $1 );

		if ( $name =~ m{(?:\A|/)Labels/([^/]+)/([^/]+)\.lbx\z}
			&& $2 !~ /\AINDEX/i ) {    # skip INDEX-*.lbx pages, not labels
			my ( $cat, $group ) = ( $1, $2 );
			( my $clean = $cat ) =~ s{\A\d+\.\s*}{};
			my $xml = $self->_lbx_label_xml($data);
			if ( !defined $xml ) {
				# An unreadable drawer is worth hearing about - but the
				# walk must continue, and never "next" from here or the
				# nextStream advance at the bottom of the loop is
				# skipped and the walk spins on this member forever.
				warn "legacy zip: no label.xml in drawer '$group' - "
					. "skipping the drawer\n";
			}
			else {
				for my $num ( $xml =~ /originalName="([\w.-]+)\.png"/g ) {
					# A part shown in two drawers keeps the first one seen.
					$parts{$num} ||= { category => $clean, group => $group };
				}
			}
		}
		my $st = $z->nextStream;
		last if !$st || $st < 0;
	}
	close $z;
	return ( \%parts, $version );
}

# Pull label.xml out of one .lbx (which is a zip of a P-touch document).
# undef means the .lbx could not be opened as a zip or carries no
# label.xml - callers warn and move on.
sub _lbx_label_xml {
	my ( $self, $lbx_bytes ) = @_;
	my $lz = IO::Uncompress::Unzip->new(\$lbx_bytes)
		or return undef;
	my $xml;
	my $max = $self->{max_member_bytes};
	while (1) {
		# garbage bytes: new() succeeds, getHeaderInfo does not
		my $info = $lz->getHeaderInfo;
		if ( !defined $info ) {
			close $lz;
			return undef;
		}
		my $name = $info->{Name} // q{};
		my $body = _drain( $lz, $max );
		$xml = $body if $name =~ /label\.xml\z/;
		my $st = $lz->nextStream;
		last if !$st || $st < 0;
	}
	close $lz;
	return $xml;
}

# --- internals ----------------------------------------------------------------

# Decompression cap enforcement lives in _drain; the default ceiling is
# $MAX_MEMBER_BYTES (see the top of the file).
sub _drain {    # read one zip member to EOF (required before nextStream)
	my ( $z, $max_bytes ) = @_;
	$max_bytes ||= $MAX_MEMBER_BYTES;
	my $data = q{};
	while (1) {
		my $buf;
		my $n = $z->read( $buf, 262144 );
		last if !$n || $n < 0;
		# Check before appending so the ceiling is exact rather than
		# "ceiling plus one read buffer".
		croak "zip member exceeds $max_bytes bytes while decompressing - "
			. 'is the download corrupt?'
			if length($data) + $n > $max_bytes;
		$data .= $buf;
	}
	return $data;
}

# Exact match first, then LDraw/BrickLink variant numbers, exactly the way
# Lego::PartsList resolves them against Rebrickable (3684c -> 3684).
sub _lookup {
	my ( $self, $num, $index ) = @_;
	return $index->{$num} if exists $index->{$num};
	for my $variant ( Lego::PartsList->variants($num) ) {
		return $index->{$variant} if exists $index->{$variant};
	}
	return undef;
}

sub _check_part_num {
	my ($num) = @_;
	croak 'invalid part number '
		. ( defined $num ? "'$num'" : '(undef)' )
		. ' (letters, digits, dots, and dashes only)'
		if !defined $num || $num !~ $SAFE_NUMBER;
	return;
}

sub _decode_entities {
	my ($text) = @_;
	return undef if !defined $text;
	my %named = (
		'&amp;'  => '&',
		'&lt;'   => '<',
		'&gt;'   => '>',
		'&quot;' => q{"},
		'&apos;' => q{'},
		'&nbsp;' => ' ',
	);
	# All entity forms decode in ONE pass, so text that was escaped for
	# display stays escaped: "&amp;#65;" decodes once, to the literal
	# "&#65;" - a second pass would double-decode it to "A".  Numeric
	# refs are clamped in the same pass: chr() of something enormous
	# ("&#99999999999;") would otherwise die, and anything past the
	# Unicode ceiling is junk anyway.  Single-line and /x-free like
	# row_re: the pattern holds literal "#"-text that /x would eat.
	$text =~ s{(&amp;|&lt;|&gt;|&quot;|&apos;|&nbsp;)|&#(\d+);|&#x([0-9a-fA-F]+);}{
		if    ( defined $1 ) { $named{$1} }
		elsif ( defined $2 ) { $2 <= 0x10FFFF ? chr($2) : "\x{FFFD}" }
		else                 { hex($3) <= 0x10FFFF ? chr( hex $3 ) : "\x{FFFD}" }
	}ge;
	$text =~ s/\s+\z//;
	return $text;
}

sub _cache_path {
	my ( $self, $url, $ext ) = @_;
	return undef if !defined $self->{cache_dir};
	return File::Spec->catfile( $self->{cache_dir},
		sha1_hex($url) . ".$ext" );
}

# Write cache files atomically (temp file + rename) so an interrupted run
# can never leave a half-written entry behind.  Binary bodies are stored
# byte-for-byte - the trailing-newline convenience is for text only, or a
# 20 MB zip would gain a stray byte after its end-of-central-directory
# record.
sub _cache_write {
	my ( $self, $url, $body, $ext, $binary ) = @_;
	return if !defined $self->{cache_dir};
	my $cache_file = $self->_cache_path( $url, $ext );
	make_path( $self->{cache_dir} );
	my $tmp_file = "$cache_file.tmp$$";
	open my $fh, '>', $tmp_file
		or croak "cannot write cache file '$tmp_file': $!";
	binmode $fh;
	print {$fh} $body;
	print {$fh} "\n" if !$binary && $body !~ m{\n\z};
	close $fh or croak "cannot close cache file '$tmp_file': $!";
	if ( !rename( $tmp_file, $cache_file ) ) {
		unlink $tmp_file;    # never leave a temp file behind
		croak "cannot install cache file '$cache_file': $!";
	}
	return;
}

# Read one cache file.  Returns ( $data, $status, $error ): 'ok', 'notfound'
# (the cached 404 sentinel), or 'corrupt' (empty or undecodable junk, which
# callers treat as a miss unless they are offline).
sub _read_cache {
	my ( $self, $cache_file, $do_decode ) = @_;
	open my $fh, '<', $cache_file
		or croak "cannot read cache file '$cache_file': $!";
	local $/;
	my $body = <$fh>;
	close $fh;
	if ( $body eq $NOT_FOUND_BODY ) {
		return ( undef, 'notfound', undef );
	}
	if ( $body eq q{} ) {
		return ( undef, 'corrupt', "empty cache file '$cache_file'" );
	}
	if ($do_decode) {
		my $data = eval { decode( 'UTF-8', $body, Encode::FB_CROAK ) };
		if ($@) {
			my $why = "invalid UTF-8 in cache file '$cache_file'";
			return ( undef, 'corrupt', $why );
		}
		return ( $data, 'ok', undef );
	}
	return ( $body, 'ok', undef );
}

1;

__END__

=head1 NAME

Lego::BrickArchitect - label lookups against Tom Alphin's Brick Architect

=head1 SYNOPSIS

	use Lego::BrickArchitect;

	my $ba = Lego::BrickArchitect->new( cache_dir => 'data/cache' );

	my $row  = $ba->part('3684');        # label page; alias => '98560'
	my @hits = @{ $ba->search('bracket') };
	my $all  = $ba->index;               # every part in the guide

	# the frozen 2023 collection: drawers for folks who printed v40
	my $legacy = $ba->legacy_lookup('3684');   # { category, group }
	my $v      = $ba->legacy_version;           # '40'

=head1 DESCRIPTION

Answers "is there a Brick Architect label for this part?" across both
generations of Tom Alphin's label collections.  The current generation is
the L<LEGO Parts Guide|https://brickarchitect.com/parts/>, where every part
has a label page (name, category breadcrumb, and a printable C<.lbx>
download); L<index|"index"> crawls its twelve category pages - thirteen
requests, cached - to enumerate the ~2900 parts the guide organizes into
categories.  (The site advertises 5000+ parts overall; the remainder only
surface through its search, so coverage mode falls back to per-part
L<part|"part"> lookups for them.)  The legacy generation is the frozen
L<LEGO Brick Labels v40|https://brickarchitect.com/labels/>
(December 2023); L<legacy_index|"legacy_index"> downloads its zip once and
reads the part numbers out of the P-touch documents, which is the only
complete machine-readable index of the ~1800 legacy labels (the contact
sheet PDF rasterizes most of them).

Requests follow redirects because the guide canonicalizes old part numbers
(C</parts/3684> answers from C</parts/98560>); L<part|"part"> reports the
alias.  Variant numbers are resolved the same way L<Lego::PartsList> does
against Rebrickable: exact match first, then LDraw/BrickLink suffixes
stripped (C<3068b> -> C<3068>).

B<Etiquette>: every fetch goes through the on-disk cache and nothing is
re-fetched without C<refresh>; the legacy zip is 20 MB (one download,
cached); and label files themselves are never stored or redistributed -
only part numbers, names, and links.

=head1 METHODS

=over 4

=item new(%args)

Accepted arguments: C<base_url> (for tests), C<cache_dir> (optional
response cache), C<refresh> (ignore existing cache entries), C<offline>
(never touch the network; die on cache misses), C<gentle> (pause one
second between consecutive live fetches - the default, per the project's
fetch-gently etiquette; tests usually disable it), C<max_member_bytes>
(the per-member decompression ceiling for zip walks; default 64 MiB -
members are drained and released one at a time, so this is what bounds
the walk's peak memory),
C<notfound_ttl> (seconds a cached 404 stays authoritative - the guide
keeps adding parts, so "no label" answers are re-checked after it;
default 30 days, 0 = forever; expiry is judged by the cache file's
mtime, so a copied or restored cache directory starts the clock over -
use C<refresh> to force a re-check), C<ua> (an C<HTTP::Tiny>-compatible
object), and C<categories> (an arrayref of category ids to crawl
instead of discovering them from the guide index - mainly for tests).

HTTPS note: fetching uses core C<HTTP::Tiny>, but C<https> itself needs
C<IO::Socket::SSL> and C<Net::SSLeay>, which are not core on every perl.
A missing SSL stack dies with an install hint rather than a bare
C<599>.

=item categories()

The guide's categories as [{ id, name }], discovered from the C</parts/>
index page so new categories appear automatically.

=item index()

Hashref of every part the guide has organized into a category (~2900
rows): part_num => { part_num, name, category, subcategory, group, url,
is_new, retired }.  Memoized; the underlying pages are cached on disk.
Parts outside the category system resolve through part() instead.

=item index_lookup($part_num)

An index row for the part, trying C<Lego::PartsList> variant numbers when
the exact one is absent, or undef.

=item part($part_num)

The part's label page as a hashref: name, category/subcategory/group
breadcrumb, in_legacy (0/1), label_url, url, requested_num, and alias
(when the guide redirected an old part number to a modern one).  undef
when the guide has no page for the number.  One request, cached.

=item legacy_index()

{ version => '40', parts => { part_num => { category, group } } } for the
frozen v40 collection.  group is the drawer: the C<.lbx> file (label
group) the label lives in, for mapping a printed legacy set onto parts.

=item legacy_lookup($part_num)

A legacy row (category, group) for the part, or undef.  Variant numbers
resolve the same way as index_lookup.  The guide's renumbering aliases
are deliberately not followed: v40 predates them, so the zip carries
the old numbers (3684, not 98560) that printed collections were sorted
by.

=item legacy_version()

The version number of the legacy collection ('40').

=item search($term)

Case-insensitive substring matches over index names and part numbers,
sorted by part number.

=item parse_category_page($html), parse_part_page($html), parse_legacy_zip($zip)

The parsers, as pure functions on fixture-shaped input; documented here
because tests exercise them directly.

=back

=head1 SEE ALSO

L<https://brickarchitect.com/parts/>,
L<https://brickarchitect.com/labels/>,
L<Lego::PartsList>, L<Lego::Rebrickable>

=cut

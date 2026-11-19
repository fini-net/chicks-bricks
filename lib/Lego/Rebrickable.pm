package Lego::Rebrickable;

# Thin client for the Rebrickable API v3.
#
# https://rebrickable.com/api/v3/docs/
#
# Uses core Perl modules only (HTTP::Tiny, JSON::PP, Digest::SHA).  Responses
# are cached on disk as raw JSON files keyed by URL, so repeat runs and the
# offline test suite never touch the network.  404s are cached too (as a
# sentinel body), which lets tests replay "part not found" offline.
#
# Rebrickable removed the MOC endpoints (/lego/mocs/...) from API v3 on
# 2020-04-19; they now answer 403 for every key:
# https://github.com/fini-net/chicks-bricks/issues/2

use strict;
use warnings;

use Carp           qw(croak);
use Digest::SHA    qw(sha1_hex);
use File::Path     qw(make_path);
use File::Spec     ();
use HTTP::Tiny     ();
use JSON::PP       qw(decode_json);
use Lego::Constants qw($MOC_ISSUE_URL $SAFE_NUMBER);

our $VERSION = '0.01';

my $DEFAULT_BASE   = 'https://rebrickable.com/api/v3';
my $NOT_FOUND_JSON = '{"__status__":404}';

sub new {
	my ($class, %args) = @_;
	# The default transport never follows redirects: a 3xx should fail
	# loudly rather than re-send the Authorization key somewhere else.
	my $ua = $args{ua} || HTTP::Tiny->new( timeout => 30, max_redirect => 0 );
	my $self = bless {
		api_key   => $args{api_key} || $ENV{REBRICKABLE_API_KEY},
		base_url  => $args{base_url} || $DEFAULT_BASE,
		cache_dir => $args{cache_dir},
		refresh   => $args{refresh} ? 1 : 0,
		offline   => $args{offline} ? 1 : 0,
		ua        => $ua,
	}, $class;
	$self->{base_url} =~ s{/+\z}{};
	return $self;
}

# Part and set numbers are validated against Lego::Constants' $SAFE_NUMBER
# before they are interpolated into request paths (see _check_component).

sub _check_component {
	my ( $self, $value, $kind ) = @_;
	croak "invalid $kind number "
		. ( defined $value ? "'$value'" : '(undef)' )
		. ' (letters, digits, dots, and dashes only)'
		if !defined $value || $value !~ $SAFE_NUMBER;
	return;
}

# Fetch one absolute URL, honoring the cache.  Returns the decoded JSON, or
# undef for a 404.  Dies on other errors, or on a cache miss in offline mode.
sub get_json {
	my ($self, $url) = @_;

	if ( defined $self->{cache_dir} ) {
		my $cache_file = $self->_cache_path($url);
		if ( !$self->{refresh} && -f $cache_file ) {
			my ( $data, $status, $error ) = $self->_read_cache($cache_file);
			if ( $status eq 'corrupt' ) {
				# Only a genuinely broken cache entry reaches here; offline
				# mode has no way to repair it, so it must die loudly.
				croak "$error (offline mode)" if $self->{offline};
				warn "$error - ignoring, refetching\n";
			}
			else {
				return if $status eq 'notfound';
				return $data;
			}
		}
	}

	croak "offline mode: no cached response for $url" if $self->{offline};

	my $api_key = $self->{api_key}
		or croak 'no Rebrickable API key: '
		. 'set REBRICKABLE_API_KEY or pass api_key => ...';

	my $response
		= $self->{ua}->get( $url, { headers => { Authorization => "key $api_key" } } );

	if ( $response->{status} == 404 ) {
		$self->_cache_write( $url, $NOT_FOUND_JSON );
		return;
	}
	if ( !$response->{success} ) {
		my $reason = $response->{reason} // 'unknown error';
		my $detail = eval { decode_json( $response->{content} ) };
		my $hint   = $response->{status} == 429 ? 'rate limited; re-run later'
			: $response->{status} == 403
			? "permission denied (MOC endpoints were removed from API v3 "
			. "in April 2020: $MOC_ISSUE_URL)"
			: undef;
		croak "GET $url failed: $response->{status} $reason"
			. ( ref $detail eq 'HASH' && $detail->{detail} ? " ($detail->{detail})" : q{} )
			. ( defined $hint ? " - $hint" : q{} );
	}

	my $data = eval { decode_json( $response->{content} ) };
	croak "invalid JSON from $url: $@" if $@;
	$self->_cache_write( $url, $response->{content} );
	return $data;
}

# GET a paginated list endpoint and return every row across all pages.  The
# path is relative to base_url and may already carry a query string.  Returns
# undef if the first page 404s.
sub get_all {
	my ($self, $path) = @_;
	my $sep = $path =~ m{\?} ? '&' : '?';
	my $url = $self->{base_url} . q{/} . $path . $sep . 'page_size=1000';
	my @rows;
	while ( defined $url ) {
		my $data = $self->get_json($url) or return;
		croak "GET $url: expected a paginated list, got something else"
			if ref $data ne 'HASH' || ref $data->{results} ne 'ARRAY';
		push @rows, @{ $data->{results} };
		$url = $data->{next};
		if ( defined $url ) {
			# Never chase pagination off-site with the API key attached.
			croak "refusing to follow pagination to '$url' "
				. "(not under $self->{base_url})"
				if index( $url, $self->{base_url} . q{/} ) != 0;
		}
	}
	return \@rows;
}

# All color metadata as a hashref keyed by color id.
# https://rebrickable.com/api/v3/lego/colors/
sub colors {
	my ($self) = @_;
	return $self->{_colors} //= do {
		my $rows = $self->get_all('lego/colors/')
			or croak 'GET lego/colors/ failed';
		my %map;
		$map{ $_->{id} } = $_ for @$rows;
		\%map;
	};
}

# All colors a part has appeared in, as an arrayref of entries, or undef
# for an unknown part number.
# https://rebrickable.com/api/v3/lego/parts/{part_num}/colors/
sub part_colors {
	my ($self, $part_num) = @_;
	$self->_check_component( $part_num, 'part' );
	return $self->{_part_colors}{$part_num}
		//= $self->get_all("lego/parts/$part_num/colors/");
}

# Inventory rows of a set, or undef for an unknown set number.
# https://rebrickable.com/api/v3/lego/sets/{set_num}/parts/
sub set_parts {
	my ($self, $set_num) = @_;
	$self->_check_component( $set_num, 'set' );
	return $self->{_set_parts}{$set_num}
		//= $self->get_all("lego/sets/$set_num/parts/");
}

sub _cache_path {
	my ($self, $url) = @_;
	return if !defined $self->{cache_dir};
	return File::Spec->catfile( $self->{cache_dir}, sha1_hex($url) . '.json' );
}

# Write cache files atomically (temp file + rename) so an interrupted run
# can never leave a half-written entry behind.
sub _cache_write {
	my ($self, $url, $body) = @_;
	return if !defined $self->{cache_dir};
	my $cache_file = $self->_cache_path($url);
	make_path( $self->{cache_dir} );
	my $tmp_file = "$cache_file.tmp$$";
	open my $fh, '>', $tmp_file
		or croak "cannot write cache file '$tmp_file': $!";
	print {$fh} $body;
	print {$fh} "\n" if $body !~ m{\n\z};
	close $fh or croak "cannot close cache file '$tmp_file': $!";
	if ( !rename( $tmp_file, $cache_file ) ) {
		unlink $tmp_file;    # never leave a temp file behind
		croak "cannot install cache file '$cache_file': $!";
	}
}

# Read one cache file.  Returns ( $data, $status, $error ): $status is 'ok',
# 'notfound' (the cached 404 sentinel), or 'corrupt' (undecodable junk,
# which callers treat as a miss unless they are offline).
sub _read_cache {
	my ( $self, $cache_file ) = @_;
	open my $fh, '<', $cache_file
		or croak "cannot read cache file '$cache_file': $!";
	local $/;
	my $body = <$fh>;
	close $fh;
	my $data = eval { decode_json($body) };
	if ( my $err = $@ ) {
		my $why = "invalid JSON in cache file '$cache_file': $err";
		$why =~ s{\s+\z}{};
		return ( undef, 'corrupt', $why );
	}
	return ( undef, 'notfound', undef )
		if ref $data eq 'HASH' && ( $data->{__status__} // 0 ) == 404;
	return ( $data, 'ok', undef );
}

1;

__END__

=head1 NAME

Lego::Rebrickable - minimal Rebrickable API v3 client with on-disk caching

=head1 SYNOPSIS

	use Lego::Rebrickable;

	my $api = Lego::Rebrickable->new( cache_dir => 'data/cache' );
	my $colors = $api->part_colors('3958');   # undef if the part is unknown
	my $all    = $api->colors;                # hashref of color id => metadata

=head1 DESCRIPTION

A deliberately small client for the parts of the Rebrickable API v3 that the
chicks-bricks tools need: color metadata, the colors each part has appeared
in, and set inventories.  It speaks plain C<Authorization: key ...> headers,
follows list pagination automatically, and keeps every response in a
one-file-per-URL JSON cache so repeated runs are free and tests can run
without network access (see C<Lego::Rebrickable-E<gt>new> C<offline>).

Safety details worth knowing: part and set numbers are validated before
they are interpolated into request paths (letters, digits, dots, and dashes
only), pagination is never followed off C<base_url>, the default transport
refuses redirects (so the API key is never re-sent elsewhere), and cache
files are written atomically.  A corrupt cache entry is treated as a miss
and refetched - unless the client is offline, where it dies loudly.
Not-found answers are cached too: a part Rebrickable adds later stays
"unknown" until C<refresh> is passed or the cache file is removed.

=head1 METHODS

=over 4

=item new(%args)

Accepted arguments: C<api_key> (or the C<REBRICKABLE_API_KEY> environment
variable), C<base_url> (for tests), C<cache_dir> (optional response cache),
C<refresh> (ignore existing cache entries), C<offline> (never touch the
network; die on cache misses), and C<ua> (a C<HTTP::Tiny>-compatible object).

=item colors()

Hashref of all color metadata keyed by color id.

=item part_colors($part_num)

Arrayref of the colors a part has appeared in, or undef when the part number
is not known to Rebrickable.  Note that for the colors endpoint Rebrickable
usually answers an unknown number with an empty list rather than an error;
Lego::PartsList treats that as unknown.

=item set_parts($set_num)

Arrayref of inventory rows for a set, or undef when the set is unknown.

=back

=head1 SEE ALSO

L<https://rebrickable.com/api/v3/docs/>,
L<Lego::Compare>,
L<Lego::PartsList>

=head1 AUTHOR

Christopher Hicks, E<lt>chicks@chicks.netE<gt>

=head1 BUGS AND SUPPORT

Bugs, feature requests, and questions all go to the GitHub issue
tracker: L<https://github.com/fini-net/chicks-bricks/issues>.

=head1 LICENSE

This is free software; you can redistribute it and/or modify it under
the same terms as the GNU General Public License, version 2, as
published by the Free Software Foundation.  See the LICENSE file in
this distribution for the full license text.

=cut

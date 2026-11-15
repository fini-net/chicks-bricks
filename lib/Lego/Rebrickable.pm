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
# MOC endpoints (/lego/mocs/...) are not available to standard API keys:
# https://github.com/fini-net/chicks-bricks/issues/2

use strict;
use warnings;

use Carp         qw(croak);
use Digest::SHA  qw(sha1_hex);
use File::Path   qw(make_path);
use File::Spec   ();
use HTTP::Tiny   ();
use JSON::PP     qw(decode_json);

our $VERSION = '0.01';

my $DEFAULT_BASE   = 'https://rebrickable.com/api/v3';
my $NOT_FOUND_JSON = '{"__status__":404}';

sub new {
	my ($class, %args) = @_;
	my $self = bless {
		api_key   => $args{api_key} || $ENV{REBRICKABLE_API_KEY},
		base_url  => $args{base_url} || $DEFAULT_BASE,
		cache_dir => $args{cache_dir},
		refresh   => $args{refresh} ? 1 : 0,
		offline   => $args{offline} ? 1 : 0,
		ua        => $args{ua} || HTTP::Tiny->new( timeout => 30 ),
	}, $class;
	$self->{base_url} =~ s{/+\z}{};
	return $self;
}

# Fetch one absolute URL, honoring the cache.  Returns the decoded JSON, or
# undef for a 404.  Dies on other errors, or on a cache miss in offline mode.
sub get_json {
	my ($self, $url) = @_;

	if ( defined $self->{cache_dir} ) {
		my $cache_file = $self->_cache_path($url);
		if ( !$self->{refresh} && -f $cache_file ) {
			open my $fh, '<', $cache_file
				or croak "cannot read cache file '$cache_file': $!";
			local $/;
			my $body = <$fh>;
			close $fh;
			return $self->_decode( $body, $cache_file );
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
		return undef;
	}
	if ( !$response->{success} ) {
		my $reason = $response->{reason} // 'unknown error';
		my $detail = eval { decode_json( $response->{content} ) };
		my $hint   = $response->{status} == 429 ? 'rate limited; re-run later'
			: $response->{status} == 403
			? 'permission denied for this key '
			. '(MOC endpoints need special access: '
			. 'https://github.com/fini-net/chicks-bricks/issues/2)'
			: undef;
		croak "GET $url failed: $response->{status} $reason"
			. ( ref $detail eq 'HASH' && $detail->{detail} ? " ($detail->{detail})" : q{} )
			. ( defined $hint ? " - $hint" : q{} );
	}

	$self->_cache_write( $url, $response->{content} );
	return $self->_decode( $response->{content}, $url );
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
		my $data = $self->get_json($url) or return undef;
		croak "GET $url: expected a paginated list, got something else"
			if ref $data ne 'HASH' || ref $data->{results} ne 'ARRAY';
		push @rows, @{ $data->{results} };
		$url = $data->{next};
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

# All colors a part has appeared in, as an arrayref of entries, or undef for
# an unknown part number.
# https://rebrickable.com/api/v3/lego/parts/{part_num}/colors/
sub part_colors {
	my ($self, $part_num) = @_;
	return $self->{_part_colors}{$part_num}
		//= $self->get_all("lego/parts/$part_num/colors/");
}

# Inventory rows of a set, or undef for an unknown set number.
# https://rebrickable.com/api/v3/lego/sets/{set_num}/parts/
sub set_parts {
	my ($self, $set_num) = @_;
	return $self->{_set_parts}{$set_num}
		//= $self->get_all("lego/sets/$set_num/parts/");
}

sub _cache_path {
	my ($self, $url) = @_;
	return undef if !defined $self->{cache_dir};
	return File::Spec->catfile( $self->{cache_dir}, sha1_hex($url) . '.json' );
}

sub _cache_write {
	my ($self, $url, $body) = @_;
	return if !defined $self->{cache_dir};
	my $cache_file = $self->_cache_path($url);
	make_path( $self->{cache_dir} );
	open my $fh, '>', $cache_file
		or croak "cannot write cache file '$cache_file': $!";
	print {$fh} $body;
	print {$fh} "\n" if $body !~ m{\n\z};
	close $fh or croak "cannot close cache file '$cache_file': $!";
}

sub _decode {
	my ($self, $body, $where) = @_;
	my $data = eval { decode_json($body) };
	croak "invalid JSON from $where: $@" if $@;
	return undef
		if ref $data eq 'HASH' && ( $data->{__status__} // 0 ) == 404;
	return $data;
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
is not known to Rebrickable.

=item set_parts($set_num)

Arrayref of inventory rows for a set, or undef when the set is unknown.

=back

=head1 SEE ALSO

L<https://rebrickable.com/api/v3/docs/>,
L<Lego::Compare>,
L<Lego::PartsList>

=cut

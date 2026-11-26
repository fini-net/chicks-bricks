package Lego::LabelCoverage;

# Coverage analysis over a parts list: which parts have Brick Architect
# labels (the current LEGO Parts Guide), which are in the frozen legacy
# v40 collection, and the print queue for the gaps.  All I/O goes through
# a Lego::BrickArchitect client (and therefore the disk cache); the math
# and rendering here are pure.
#
# Input is a Lego::PartsList arrayref of rows:
#
#   { input_num => '3684', part_num => '3684',
#     name => 'Slope Brick 75 2 x 2 x 3', qty => 12 }
#
# Each row comes back annotated:
#
#   { ..., has_label => 1, alias => '98560',
#       label_name => '75° 2×2×3 Slope w/ 2-Studs',
#       category => 'Angle', subcategory => ..., group => ...,
#       url => 'https://brickarchitect.com/parts/98560',
#       in_legacy => 1, legacy_category => 'ANGLE',
#       legacy_group => 'ANGLE-slope_55_65_75' }

use strict;
use warnings;

use Carp           qw(croak);
use List::Util     qw(sum0);
use Scalar::Util   qw(blessed);
use Lego::PartsList ();

our $VERSION = '0.01';

sub new {
	my ( $class, %args ) = @_;
	croak 'parts must be an arrayref of part rows'
		if ref $args{parts} ne 'ARRAY';
	# Duck-typed: anything that answers the BrickArchitect API works,
	# which also lets tests substitute lighter clients.
	croak 'ba must be a Lego::BrickArchitect client'
		if !blessed( $args{ba} ) || !$args{ba}->can('index_lookup');
	return bless {
		parts  => $args{parts},
		ba     => $args{ba},
		legacy => $args{legacy} ? 1 : 0,
		# Fetch per-part label pages for parts the index does not know
		# (old numbers like 3684 that the guide redirects).  One request
		# per uncached part, first run only; disable to stay index-only.
		deep   => exists $args{deep} ? ( $args{deep} ? 1 : 0 ) : 1,
	}, $class;
}

# Annotate every part row (memoized - one pass per object).
sub analyze {
	my ($self) = @_;
	return $self->{_rows} //= [ map { $self->_analyze_one($_) } @{ $self->{parts} } ];
}

sub _analyze_one {
	my ( $self, $part ) = @_;
	my $num  = $part->{part_num};
	my $row  = { %{$part} };
	my $ba   = $self->{ba};

	if ( my $hit = $ba->index_lookup($num) ) {
		$row->{has_label}  = 1;
		$row->{source}     = 'index';
		$row->{alias}      = $hit->{part_num} ne $num ? $hit->{part_num} : undef;
		$row->{label_name} = $hit->{name};
		_row_from_index( $row, $hit );
	}
	elsif ( $self->{deep} && ( my $page = $self->_deep_page($num) ) ) {
		# Not in the index, but the guide may still answer under a
		# redirected number: /parts/3684 lives at /parts/98560.
		$row->{has_label}  = 1;
		$row->{source}     = 'page';
		$row->{alias}      = $page->{alias};
		$row->{label_name} = $page->{name};
		$row->{url}        = $page->{url};
		$row->{category}    = $page->{category}    if defined $page->{category};
		$row->{subcategory} = $page->{subcategory} if defined $page->{subcategory};
		$row->{group}       = $page->{group}       if defined $page->{group};
	}
	else {
		$row->{has_label} = 0;
	}

	if ( $self->{legacy} ) {
		# Keyed by the input number (plus its variants), deliberately
		# NOT the guide's alias: v40 predates the guide's renumbering,
		# so the zip carries the old numbers (3684, not 98560) that
		# printed collections were sorted by.
		if ( my $legacy = $ba->legacy_lookup($num) ) {
			$row->{in_legacy}       = 1;
			$row->{legacy_category} = $legacy->{category};
			$row->{legacy_group}    = $legacy->{group};
		}
		else { $row->{in_legacy} = 0 }
	}
	return $row;
}

# Try the part's own page, then its LDraw/BrickLink variants, stopping at
# the first label page the guide has (all cached after the first run).
sub _deep_page {
	my ( $self, $num ) = @_;
	for my $try ( $num, Lego::PartsList->variants($num) ) {
		my $page = $self->{ba}->part($try);
		return $page if $page;
	}
	return;
}

sub _row_from_index {
	my ( $row, $hit ) = @_;
	$row->{url}         = $hit->{url};
	$row->{part_num}    = $hit->{part_num};
	$row->{category}    = $hit->{category};
	$row->{subcategory} = $hit->{subcategory} if defined $hit->{subcategory};
	$row->{group}       = $hit->{group}        if defined $hit->{group};
	$row->{retired}     = $hit->{retired} ? 1 : 0;
	return;
}

# --- statistics --------------------------------------------------------------

sub part_count  { return scalar @{ $_[0]->analyze } }
sub piece_count { return sum0 map { $_->{qty} // 0 } @{ $_[0]->analyze } }

# Counts (not row lists) so callers can interpolate them anywhere.
sub labeled_parts {
	my ($self) = @_;
	return scalar grep { $_->{has_label} } @{ $self->analyze };
}

sub labeled_pieces {
	my ($self) = @_;
	return sum0 map { $_->{qty} // 0 } grep { $_->{has_label} } @{ $self->analyze };
}

sub coverage_pct {
	my ($self) = @_;
	my $total = $self->part_count;
	return $total ? 100 * $self->labeled_parts / $total : 0;
}

sub pieces_pct {
	my ($self) = @_;
	my $total = $self->piece_count;
	return $total ? 100 * $self->labeled_pieces / $total : 0;
}

sub legacy_stats {
	my ($self) = @_;
	return if !$self->{legacy};
	my @rows = @{ $self->analyze };
	my @both     = grep { $_->{has_label}  && $_->{in_legacy} } @rows;
	my @guide    = grep { $_->{has_label}  && !$_->{in_legacy} } @rows;
	my @legacy   = grep { !$_->{has_label} && $_->{in_legacy} } @rows;
	my @neither  = grep { !$_->{has_label} && !$_->{in_legacy} } @rows;
	return { both => \@both, guide_only => \@guide,
		legacy_only => \@legacy, neither => \@neither };
}

# --- rendering ----------------------------------------------------------------

sub summary_data {
	my ( $self, %args ) = @_;
	my $data = {
		title          => $args{title},
		version        => $self->{legacy} ? $self->{ba}->legacy_version : undef,
		part_count     => $self->part_count,
		piece_count    => $self->piece_count,
		labeled_parts  => $self->labeled_parts,
		coverage_pct   => $self->coverage_pct,
		labeled_pieces => $self->labeled_pieces,
		pieces_pct     => $self->pieces_pct,
		parts          => [ map { $self->_json_row($_) } @{ $self->analyze } ],
	};
	if ( my $stats = $self->legacy_stats ) {
		$data->{legacy} = {
			map { ( $_ => [ map { $_->{input_num} } @{ $stats->{$_} } ] ) }
				qw(both guide_only legacy_only neither)
		};
	}
	return $data;
}

sub _json_row {
	my ( $self, $row ) = @_;
	my %out = map { $_ => $row->{$_} }
		grep { defined $row->{$_} }
		qw(input_num part_num name qty has_label alias label_name
		category subcategory group url in_legacy
		legacy_category legacy_group);
	return \%out;
}

sub render_text {
	my ( $self, %args ) = @_;
	my $title = $args{title} // 'Parts list';
	my $rows  = $self->analyze;
	my $out   = q{};

	$out .= "$title\n";
	$out .= sprintf "%d distinct parts, %d pieces\n\n",
		$self->part_count, $self->piece_count;
	$out .= sprintf "Label coverage: %d/%d parts (%.0f%%), %d/%d pieces (%.0f%%)\n\n",
		$self->labeled_parts, $self->part_count, $self->coverage_pct,
		$self->labeled_pieces, $self->piece_count, $self->pieces_pct;

	my @labeled   = grep { $_->{has_label} } @{$rows};
	my @unlabeled = grep { !$_->{has_label} } @{$rows};

	$out .= "Parts with labels\n";
	$out .= @labeled
		? join( q{}, map { sprintf "  %-8s %-34s %s\n",
			_display_num($_), _display_name($_), _crumb($_) } @labeled )
		: "  (none)\n";
	$out .= "\n";

	$out .= "Parts without labels\n";
	$out .= @unlabeled
		? join( q{}, map { sprintf "  %-8s %s\n", _display_num($_), $_->{name} } @unlabeled )
		: "  (none)\n";
	$out .= "\n";

	if ( $self->{legacy} ) {
		my $stats = $self->legacy_stats;
		$out .= sprintf "Legacy v%s comparison\n", $self->{ba}->legacy_version;
		_out_row( \$out, '  In both (guide + legacy): ', $stats->{both} );
		_out_row( \$out, '  Guide only:              ', $stats->{guide_only} );
		_out_row( \$out, '  Legacy only:             ', $stats->{legacy_only} );
		_out_row( \$out, '  Neither:                 ', $stats->{neither} );
		$out .= "\n";
	}

	# The print queue: label pages for everything covered by the guide
	# (in legacy mode, the legacy set is already printed - queue the gaps).
	my @queue = $self->{legacy}
		? @{ $self->legacy_stats->{guide_only} }
		: @labeled;
	$out .= sprintf "Label pages to print (%d)\n", scalar @queue;
	$out .= @queue
		? join( q{}, map { "  $_->{url}\n" } @queue )
		: "  (none)\n";
	return $out;
}

sub _out_row {
	my ( $out, $label, $rows ) = @_;
	my @items = map {
		my $num = _display_num($_);
		defined $_->{legacy_group}
			? "$num (legacy drawer: $_->{legacy_category} / $_->{legacy_group})"
			: $num;
	} @{$rows};
	${$out} .= @items ? "$label" . join( q{, }, @items ) . "\n"
		: "$label(none)\n";
	return;
}

sub _display_num {
	my ($row) = @_;
	return $row->{alias} ? "$row->{input_num} = $row->{alias}" : $row->{input_num};
}

sub _display_name {
	my ($row) = @_;
	return $row->{label_name} // $row->{name} // q{};
}

sub _crumb {
	my ($row) = @_;
	my @crumb = grep { defined } ( $row->{category}, $row->{subcategory}, $row->{group} );
	return join ' > ', @crumb;
}

sub render_csv {
	my ($self) = @_;
	my @lines = ( 'input_num,part_num,name,has_label,label_name,category,subcategory,group'
		. ( $self->{legacy} ? ',in_legacy,legacy_category,legacy_group' : q{} )
		. ',url' );
	for my $row ( @{ $self->analyze } ) {
		my @fields = (
			$row->{input_num},   $row->{part_num},   $row->{name},
			$row->{has_label} ? 'yes' : 'no',        $row->{label_name} // q{},
			$row->{category} // q{},                 $row->{subcategory} // q{},
			$row->{group} // q{},
		);
		if ( $self->{legacy} ) {
			push @fields, ( $row->{in_legacy} ? 'yes' : 'no' ),
				$row->{legacy_category} // q{}, $row->{legacy_group} // q{};
		}
		push @fields, $row->{url} // q{};
		push @lines, join q{,}, map { csv_escape($_) } @fields;
	}
	return join( "\n", @lines ) . "\n";
}

# The CSV quoting rules (RFC 4180-ish), shared with bin/brick-labels so
# every writer quotes identically: quote fields containing commas,
# quotes, or CR/LF (a bare \r would corrupt the row), doubling embedded
# quotes.  No spreadsheet-formula guarding (prefixing a leading =, +, -,
# or @): the names come from brickarchitect.com's own pages, mangling
# them would break round-trips, so the theoretical risk is accepted.
sub csv_escape {
	my ($field) = @_;
	return q{} if !defined $field;
	return $field if $field !~ m{[",\r\n]};
	$field =~ s/"/""/g;
	return qq{"$field"};
}

1;

__END__

=encoding UTF-8

=head1 NAME

Lego::LabelCoverage - which of your parts have Brick Architect labels?

=head1 SYNOPSIS

	use Lego::BrickArchitect;
	use Lego::LabelCoverage;
	use Lego::PartsList;

	my $ba   = Lego::BrickArchitect->new( cache_dir => 'data/cache' );
	my $rows = Lego::PartsList->from_file('examples/business_card_holder.parts.csv');
	my $cov  = Lego::LabelCoverage->new( parts => $rows, ba => $ba, legacy => 1 );
	print $cov->render_text( title => 'MOC-61370' );
	print $cov->render_csv;

=head1 DESCRIPTION

Given a parts list and a L<Lego::BrickArchitect> client, annotate every
part with its label status: covered by the current guide (L</analyze()>)
or not, and - with C<legacy> - whether the frozen v40 collection carries
it, down to the drawer it lives in.  Parts missing from the guide index
are looked up per-page (C<deep>, the default), which is how old part
numbers such as 3684 resolve to their modern label pages (98560).

Rendering helpers mirror L<Lego::Compare>:
L<render_text()|/"render_text(%args)"> for humans (including a
label-page URL queue to print), L<summary_data()|/"summary_data(%args)">
for JSON, and L</render_csv()> for rows.

=head1 METHODS

=over 4

=item new(%args)

C<parts> (Lego::PartsList rows), C<ba> (client), C<legacy> (also compare
against the frozen v40 collection), C<deep> (fetch per-part label pages
for parts the index does not know - the default; one cached request per
uncached part).

=item analyze()

The annotated rows (memoized).

=item part_count(), piece_count(), labeled_parts(), labeled_pieces(), coverage_pct(), pieces_pct()

Coverage statistics; the C<pieces> variants are quantity-weighted.

=item legacy_stats()

With C<legacy>: { both, guide_only, legacy_only, neither } row lists.

=item summary_data(%args)

Report hashref for JSON output; pass C<title>.

=item render_text(%args)

Human report; pass C<title>.  Ends with the label-page URL queue: every
covered part normally, or just the guide-only gaps in legacy mode (the
legacy labels are already printed).

=item render_csv()

Row report.

=item csv_escape($field)

The CSV quoting helper used by render_csv - public so bin/brick-labels
quotes identically instead of duplicating the rules.  Quotes fields
containing commas, quotes, or CR/LF, doubling embedded quotes; no
spreadsheet-formula guarding, since names come from the guide itself
and mangling them would break round-trips.

=back

=head1 SEE ALSO

L<Lego::BrickArchitect>, L<Lego::PartsList>, L<Lego::Compare>

=head1 AUTHOR

Christopher Hicks, E<lt>chicks@chicks.netE<gt>

=head1 BUGS AND SUPPORT

Bugs, feature requests, and questions all go to the GitHub issue
tracker: L<https://github.com/fini-net/chicks-bricks/issues>.

=head1 LICENSE

This is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License, version 2, as published
by the Free Software Foundation.  See the LICENSE file in this
distribution for the full license text.

=head1 TRADEMARKS

LEGO® is a trademark of the LEGO Group of companies which does not
sponsor, authorize or endorse this software.

=cut

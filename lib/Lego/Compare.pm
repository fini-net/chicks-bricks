package Lego::Compare;

# Pure set math over part/color availability data - no I/O, no API access.
#
# Input is a hashref keyed by Rebrickable part number:
#
#   { '3958' => { name => 'Plate 6 x 6', qty => 2,
#       colors => { 0 => { name => 'Black', num_sets => 430, is_trans => 0 } } } }
#
# The headline question is the intersection: which colors is EVERY part in
# the list available in (your monochrome build options)?  Near misses and
# bottlenecks round out the answer.

use strict;
use warnings;

use Carp       qw(croak);
use List::Util qw(sum0);

our $VERSION = '0.01';

sub new {
	my ( $class, %args ) = @_;
	my $parts = $args{parts};
	croak 'parts must be a hashref of part_num => {...}'
		if ref $parts ne 'HASH';
	return bless {
		parts         => $parts,
		exclude_trans => $args{exclude_trans} ? 1 : 0,
		min_sets      => $args{min_sets},
	}, $class;
}

sub part_count { return scalar keys %{ $_[0]->{parts} } }

sub piece_count {
	return sum0 map { $_->{qty} // 0 } values %{ $_[0]->{parts} };
}

# Color ids for one part after the exclude_trans / min_sets filters,
# sorted numerically.
sub _colors_for {
	my ( $self, $part ) = @_;
	my $colors = $part->{colors} || {};
	return grep {
		!( $self->{exclude_trans} && $colors->{$_}{is_trans} )
		&& ( !defined $self->{min_sets}
			|| ( $colors->{$_}{num_sets} // 0 ) >= $self->{min_sets} )
	} sort { $a <=> $b } keys %{$colors};
}

sub _cname {
	my ( $self, $cid, $meta ) = @_;
	return defined $meta && defined $meta->{name} && length $meta->{name}
		? $meta->{name}
		: "color #$cid";
}

# Hashref of the color ids (and metadata) available for every part.
sub intersection {
	my ($self) = @_;
	my @parts = values %{ $self->{parts} };
	return {} if !@parts;
	my %common = map { $_ => 1 } $self->_colors_for( $parts[0] );
	for my $part (@parts) {
		my %have = map { $_ => 1 } $self->_colors_for($part);
		%common = map { $_ => 1 } grep { $have{$_} } keys %common;
	}
	return \%common;
}

# For every color any part comes in: how many parts cover it and which parts
# are missing.
sub coverage {
	my ($self) = @_;
	my %union;
	my %meta;
	for my $part ( values %{ $self->{parts} } ) {
		for my $cid ( $self->_colors_for($part) ) {
			$union{$cid} = 1;
			$meta{$cid} //= $part->{colors}{$cid};
		}
	}
	my $total = $self->part_count;
	my %coverage;
	for my $cid ( sort { $a <=> $b } keys %union ) {
		my ( $count, @missing ) = ( 0, () );
		for my $num ( sort keys %{ $self->{parts} } ) {
			if ( grep { $_ == $cid } $self->_colors_for( $self->{parts}{$num} ) ) {
				$count++;
			}
			else { push @missing, $num }
		}
		$coverage{$cid} = {
			count   => $count,
			total   => $total,
			pct     => $total ? 100 * $count / $total : 0,
			missing => \@missing,
			color   => $meta{$cid},
		};
	}
	return \%coverage;
}

# Colors that do not cover every part, ranked by coverage, best first.
sub near_misses {
	my ( $self, $min_pct ) = @_;
	$min_pct //= 0;
	my $inter = $self->intersection;
	my $cov   = $self->coverage;
	my @near;
	for my $cid ( keys %{$cov} ) {
		next if $inter->{$cid};
		next if $cov->{$cid}{pct} < $min_pct;
		push @near, { %{ $cov->{$cid} }, color_id => $cid };
	}
	return [ sort {
		$b->{pct} <=> $a->{pct}
		|| $self->_cname( $a->{color_id}, $a->{color} )
		cmp $self->_cname( $b->{color_id}, $b->{color} )
	} @near ];
}

# Parts with the fewest available colors first: these constrain the palette.
sub bottlenecks {
	my ($self) = @_;
	my @parts;
	for my $num ( sort keys %{ $self->{parts} } ) {
		my $part = $self->{parts}{$num};
		push @parts, {
			part_num        => $num,
			name            => $part->{name},
			qty             => $part->{qty},
			available_colors => scalar $self->_colors_for($part),
		};
	}
	return [ sort {
		$a->{available_colors} <=> $b->{available_colors}
			|| $a->{part_num} cmp $b->{part_num}
	} @parts ];
}

# Data structure behind the JSON output.
sub summary_data {
	my ( $self, %args ) = @_;
	my $inter = $self->intersection;
	my %meta;
	for my $cid ( keys %{$inter} ) {
	PART: for my $num ( keys %{ $self->{parts} } ) {
			my $c = $self->{parts}{$num}{colors}{$cid};
			if ($c) { $meta{$cid} = $c; last PART }
		}
	}
	return {
		title       => $args{title},
		part_count  => $self->part_count,
		piece_count => $self->piece_count,
		monochrome  => [
			map { { id => $_, name => $meta{$_}{name}, num_sets => $meta{$_}{num_sets} } }
			sort {
				$self->_cname( $a, $meta{$a} ) cmp $self->_cname( $b, $meta{$b} )
			} keys %{$inter}
		],
		near_misses => [
			map {
				{   id      => $_->{color_id},
					name    => $self->_cname( $_->{color_id}, $_->{color} ),
					count   => $_->{count},
					total   => $_->{total},
					pct     => $_->{pct},
					missing => $_->{missing},
				}
			} @{ $self->near_misses( $args{min_coverage} ) }
		],
		bottlenecks => $self->bottlenecks,
	};
}

sub render_text {
	my ( $self, %args ) = @_;
	my $title = $args{title} // 'Parts list';
	my $out   = q{};
	$out .= "$title\n";
	$out .= sprintf "%d distinct parts, %d pieces\n\n",
		$self->part_count, $self->piece_count;

	# Monochrome section
	my $inter = $self->intersection;
	my %meta;
	for my $cid ( keys %{$inter} ) {
		for my $num ( keys %{ $self->{parts} } ) {
			my $c = $self->{parts}{$num}{colors}{$cid};
			if ($c) { $meta{$cid} = $c; last }
		}
	}
	my @mono = sort { $self->_cname( $a, $meta{$a} ) cmp $self->_cname( $b, $meta{$b} ) }
		keys %{$inter};
	$out .= sprintf "Monochrome: available for all %d parts\n", $self->part_count;
	$out .= @mono
		? '  ' . join( q{, }, map { $self->_cname( $_, $meta{$_} ) } @mono ) . "\n"
		: "  (none)\n";
	$out .= "\n";

	# Near miss section
	my $min_pct = $args{min_coverage} // 0;
	my $near    = $self->near_misses($min_pct);
	$out .= sprintf "Near misses (>= %d%% coverage)\n", $min_pct;
	if ( @{$near} ) {
		my $width = 0;
		for my $entry ( @{$near} ) {
			my $len = length $self->_cname( $entry->{color_id}, $entry->{color} );
			$width = $len if $len > $width;
		}
		$width++ if $width % 2;    # even padding keeps the output lint-clean
		for my $entry ( @{$near} ) {
			my $name = $self->_cname( $entry->{color_id}, $entry->{color} );
			$out .= sprintf "  %-*s  %d/%d parts\n", $width, $name,
				$entry->{count}, $entry->{total};
			$out .= sprintf "%s    missing: %s\n", q{ } x $width,
				join( q{, }, @{ $entry->{missing} } )
				if @{ $entry->{missing} };
		}
	}
	else { $out .= "  (none)\n" }
	$out .= "\n";

	# Bottleneck section
	my $bottlenecks = $self->bottlenecks;
	$out .= "Bottlenecks (fewest available colors first)\n";
	my $num_width = 0;
	for my $part ( @{$bottlenecks} ) {
		my $len = length $part->{part_num};
		$num_width = $len if $len > $num_width;
	}
	for my $part ( @{$bottlenecks} ) {
		$out .= sprintf "  %-*s  x%-3d %-30s %3d colors\n", $num_width,
			$part->{part_num}, $part->{qty} // 0,
			$part->{name} // q{}, $part->{available_colors};
	}
	return $out;
}

sub render_csv {
	my ($self) = @_;
	my $cov   = $self->coverage;
	my $inter = $self->intersection;
	my @lines = ( 'color,parts_available,parts_total,coverage_pct,missing_parts' );
	for my $cid ( sort keys %{$cov} ) {
		my $entry   = $cov->{$cid};
		my $missing = join q{;}, @{ $entry->{missing} };
		push @lines, sprintf '%s,%d,%d,%.1f,%s',
			$self->_cname( $cid, $entry->{color} ),
			$entry->{count}, $entry->{total}, $entry->{pct}, $missing;
	}
	return join( "\n", @lines ) . "\n";
}

1;

__END__

=head1 NAME

Lego::Compare - which colors is a set of parts available in?

=head1 SYNOPSIS

	use Lego::Compare;

	my $cmp = Lego::Compare->new(
		parts         => \%parts,
		exclude_trans => 1,
		min_sets      => 5,
	);
	my $colors = $cmp->intersection;    # monochrome options
	my $text   = $cmp->render_text( title => 'MOC-61370', min_coverage => 50 );

=head1 DESCRIPTION

Given a hashref of parts, each with the colors it is available in, compute
the answers that matter when recoloring a model: the colors every part
shares (L</intersection()>), per-color coverage across the parts
(L<near_misses()|/"near_misses($min_pct)">), and which parts constrain
the palette the most (L</bottlenecks()>).  All methods are pure; rendering
helpers return strings.

Options at construction: C<exclude_trans> drops transparent colors, and
C<min_sets> drops colors that appear in fewer than that many sets (a
rarity filter).

=head1 METHODS

=over 4

=item new(%args)

Construct with C<parts> (hashref of part_num => { name, qty, colors }),
plus the C<exclude_trans> and C<min_sets> filters.

=item intersection()

Hashref of color ids available for every part.

=item coverage()

Hashref of every seen color id to its part coverage and missing parts.

=item near_misses($min_pct)

Arrayref of non-intersection colors with coverage percentage of at least
C<$min_pct>, best coverage first.

=item bottlenecks()

Arrayref of parts sorted by available color count, fewest first.

=item summary_data(%args)

Structured summary (hashref) for JSON output; pass C<min_coverage>.

=item render_text(%args), render_csv()

Human and CSV reports; C<render_text> takes C<title> and C<min_coverage>.

=back

=head1 SEE ALSO

L<Lego::Rebrickable>, L<Lego::PartsList>

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

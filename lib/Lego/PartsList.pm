package Lego::PartsList;

# Where a "set of parts" comes from: a CSV file or a Rebrickable set number.
#
# A parts list is an arrayref of rows like:
#
#   { input_num => '3684', part_num => '3684',
#     name => 'Slope Brick 75 2 x 2 x 3', qty => 12, color => 'Lime' }
#
# input_num is what the user listed; part_num is the Rebrickable number,
# which resolve() may rewrite when only a variant differs (LDraw calls the
# solid-stud slope 3684c; Rebrickable only knows 3684).

use strict;
use warnings;

use Carp qw(croak);

our $VERSION = '0.01';

sub from_file {
	my ( $class, $path ) = @_;
	croak 'from_file: no path given' if !defined $path;
	open my $fh, '<:encoding(UTF-8)', $path
		or croak "cannot open parts file '$path': $!";
	my @rows;
	my $saw_header = 0;
	my $line_no    = 0;
	while ( my $line = <$fh> ) {
		$line_no++;
		$line =~ s/\r?\n\z//;
		next if $line =~ m{\A\s*\z} || $line =~ m{\A\s*#};
		my @fields = $class->parse_csv($line);
		if ( !$saw_header && lc( $fields[0] // q{} ) eq 'part_num' ) {
			$saw_header = 1;
			next;
		}
		croak "$path line $line_no: need part_num,name,qty[,color]"
			if @fields < 3;
		my ( $num, $name, $qty, $color )
			= map { defined $_ && length $_ ? $_ : undef } @fields[ 0 .. 3 ];
		push @rows, {
			input_num => $num,
			part_num  => $num,
			name      => $name // $num,
			qty       => $qty // 1,
			( defined $color ? ( color => $color ) : () ),
		};
	}
	close $fh;
	croak "no parts found in '$path'" if !@rows;
	return $class->aggregate( \@rows );
}

# Inventory of an official Rebrickable set, aggregated to one row per part
# number (spares included, quantities summed).
sub from_set {
	my ( $class, $api, $set_num ) = @_;
	my $rows = $api->set_parts($set_num) or croak
		"set '$set_num' not found (note: MOC inventories are not available "
		. 'to standard API keys; use --parts-file for MOCs, see '
		. 'https://github.com/fini-net/chicks-bricks/issues/2)';
	my %by_part;
	my @order;
	for my $row ( @{$rows} ) {
		my $part = $row->{part} or next;
		my $num  = $part->{part_num};
		if ( !exists $by_part{$num} ) {
			$by_part{$num} = {
				input_num   => $num,
				part_num    => $num,
				name        => $part->{name},
				qty         => 0,
				colors_used => {},
			};
			push @order, $num;
		}
		my $entry = $by_part{$num};
		$entry->{qty} += $row->{quantity} // 0;
		$entry->{colors_used}{ $row->{color}{id} } = $row->{color}{name}
			if ref $row->{color} eq 'HASH';
	}
	my @parts = @by_part{@order};
	for my $part (@parts) {
		my %used = %{ delete $part->{colors_used} };
		$part->{color} = join q{/}, sort values %used if %used;
	}
	return \@parts;
}

# Merge duplicate rows (same part number) by summing quantities.
sub aggregate {
	my ( $class, $rows ) = @_;
	my %by_part;
	my @order;
	for my $row ( @{$rows} ) {
		my $num = $row->{part_num};
		if ( !exists $by_part{$num} ) {
			$by_part{$num} = { %{$row} };
			$by_part{$num}{qty} = 0;
			push @order, $num;
		}
		$by_part{$num}{qty} += $row->{qty} // 1;
	}
	return [ @by_part{@order} ];
}

# Rewrite part_num in place to a number Rebrickable knows, trying
# variant-suffixed numbers for their base (3684c and 3684c01 both fall back
# to 3684).  Rows that cannot be resolved keep their original number; the
# caller reports them.
#
# Note: the part-colors endpoint answers unknown numbers (3684c) with an
# empty list rather than a 404, so "known" means defined AND non-empty.
sub resolve {
	my ( $class, $api, $parts ) = @_;
	for my $part ( @{$parts} ) {
		next if $class->_known( $api, $part->{part_num} );
		for my $variant ( $class->variants( $part->{part_num} ) ) {
			next if !$class->_known( $api, $variant );
			$part->{part_num} = $variant;
			last;
		}
	}
	return $parts;
}

sub _known {
	my ( $class, $api, $num ) = @_;
	my $colors = $api->part_colors($num);
	return defined $colors && @{$colors} ? 1 : 0;
}

# Variant numbers to try when the given number is unknown.  LDraw and
# BrickLink suffix a letter (sometimes with digits) to distinguish molds;
# Rebrickable sometimes keeps the suffix (3068b) and sometimes does not
# (3684).
sub variants {
	my ( $class, $num ) = @_;
	my @variants;
	push @variants, lc $num if lc $num ne $num;
	if ( $num =~ m{(?<base>\d+)(?<suffix>[A-Za-z]\d*)\z} ) {
		push @variants, $+{base};
	}
	return @variants;
}

# Minimal RFC 4180-ish CSV line parser: handles quoted fields containing
# commas and doubled quotes.  No embedded newlines; we parse line by line.
sub parse_csv {
	my ( $class, $line ) = @_;
	my @fields;
	my $field     = q{};
	my $in_quotes = 0;
	my $length    = length $line;
	for ( my $i = 0; $i < $length; $i++ ) {
		my $char = substr( $line, $i, 1 );
		if ($in_quotes) {
			if ( $char eq q{"} ) {
				if ( substr( $line, $i + 1, 1 ) eq q{"} ) {
					$field .= q{"};
					$i++;
				}
				else { $in_quotes = 0 }
			}
			else { $field .= $char }
		}
		elsif ( $char eq q{"} ) { $in_quotes = 1 }
		elsif ( $char eq q{,} ) { push @fields, $field; $field = q{} }
		else                    { $field .= $char }
	}
	push @fields, $field;
	return @fields;
}

1;

__END__

=head1 NAME

Lego::PartsList - load and normalize a list of LEGO parts

=head1 SYNOPSIS

	use Lego::PartsList;
	use Lego::Rebrickable;

	my $api   = Lego::Rebrickable->new( cache_dir => 'data/cache' );
	my $parts = Lego::PartsList->from_file('examples/business_card_holder.parts.csv');
	Lego::PartsList->resolve( $api, $parts );    # 3684c -> 3684, in place

=head1 DESCRIPTION

Turns a parts list from a CSV file or a Rebrickable set number into rows the
comparison tools can use, merging duplicates and resolving LDraw/BrickLink
variant part numbers to their Rebrickable equivalents where they differ.

=head1 METHODS

=over 4

=item from_file($path)

Read C<part_num,name,qty[,color]> rows from a CSV file.  A header row naming
C<part_num> is recognized and skipped, as are blank lines and C<#> comments.
Extra columns are ignored.

=item from_set($api, $set_num)

Fetch a set inventory via the API and aggregate it to one row per part.

=item aggregate($rows)

Merge rows with the same part number, summing quantities.

=item resolve($api, $parts)

In-place variant-number resolution: when Rebrickable does not know a part
number (its colors endpoint answers with an empty list), the LDraw/BrickLink
variant suffixes are stripped and the base number is tried (3684c becomes
3684).

=item parse_csv($line)

Split one CSV line into fields, honoring quoted fields.

=back

=cut

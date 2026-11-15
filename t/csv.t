#!/usr/bin/env perl
# CSV parsing and parts-file loading.

use strict;
use warnings;

use File::Temp ();
use Test::More;

use Lego::PartsList;

# parse_csv basics
is_deeply(
	[ Lego::PartsList->parse_csv('a,b,c') ],
	[ 'a', 'b', 'c' ],
	'plain fields',
);
is_deeply(
	[ Lego::PartsList->parse_csv(q{"hello, world",b}) ],
	[ 'hello, world', 'b' ],
	'quoted field with comma',
);
is_deeply(
	[ Lego::PartsList->parse_csv(q{"say ""hi""",b}) ],
	[ 'say "hi"', 'b' ],
	'doubled quotes inside quoted field',
);
is_deeply(
	[ Lego::PartsList->parse_csv('a,,c') ],
	[ 'a', '', 'c' ],
	'empty field',
);

# from_file against a temp file
my $tmp = File::Temp->new;
print {$tmp} <<'END_CSV';
# leading comment
part_num,name,qty,color
3958,Plate 6 x 6,2,Lime
3622,"Brick 1 x 3",2,Lime
4865b,Panel,
# trailing comment

87079,Tile 2 x 4,2
END_CSV
close $tmp;

my $parts = Lego::PartsList->from_file( $tmp->filename );
is( scalar @{$parts}, 4, 'four parts parsed' );
is( $parts->[0]{part_num}, '3958', 'first part number' );
is( $parts->[0]{qty},      2,      'quantity' );
is( $parts->[0]{color},    'Lime', 'color column' );
is( $parts->[2]{qty},      1,      'qty defaults to 1 when empty' );
ok( !exists $parts->[3]{color}, 'color column is optional' );
is( $parts->[3]{name}, 'Tile 2 x 4', 'name column' );

# header detection without a header row
my $tmp2 = File::Temp->new;
print {$tmp2} "3958,Plate,2\n";
close $tmp2;
my $no_header = Lego::PartsList->from_file( $tmp2->filename );
is( scalar @{$no_header}, 1, 'headerless file still parses' );

# duplicate part numbers merge
my $tmp3 = File::Temp->new;
print {$tmp3} "part_num,name,qty\n3010,Brick,2\n3010,Brick,3\n";
close $tmp3;
my $merged = Lego::PartsList->from_file( $tmp3->filename );
is( scalar @{$merged}, 1, 'duplicate part numbers merge' );
is( $merged->[0]{qty}, 5, 'merged quantity is the sum' );

# aggregate merges across lists too
my $agg = Lego::PartsList->aggregate(
	[   { part_num => 3010, name => 'Brick', qty => 1 },
		{ part_num => 3001, name => 'Brick', qty => 2 },
		{ part_num => 3010, name => 'Brick', qty => 4 },
	]
);
is( scalar @{$agg}, 2, 'aggregate keeps distinct parts' );
is( $agg->[0]{part_num}, '3010', 'aggregate order: first seen' );
is( $agg->[0]{qty},      5,      'aggregate sums quantities' );

# variant generation for part-number resolution
is_deeply( [ Lego::PartsList->variants('3684c') ],   ['3684'],  'letter suffix' );
is_deeply( [ Lego::PartsList->variants('3684c01') ], ['3684'],  'letter+digit suffix' );
is_deeply( [ Lego::PartsList->variants('4865B') ],   [ '4865b', '4865' ],
	'uppercase input tries lowercase first' );
is_deeply( [ Lego::PartsList->variants('3068b') ],   ['3068'],  'suffix variant offered' );
is_deeply( [ Lego::PartsList->variants('3958') ],    [],        'plain number has no variants' );

# error cases
my $tmp4 = File::Temp->new;
print {$tmp4} "part_num,name\n3010,Brick\n";
close $tmp4;
eval { Lego::PartsList->from_file( $tmp4->filename ) };
like( $@, qr/need part_num,name,qty/, 'row with too few columns dies' );

eval { Lego::PartsList->from_file('/nonexistent/parts.csv') };
like( $@, qr/cannot open/, 'missing file dies' );

my $tmp5 = File::Temp->new;
print {$tmp5} "# only comments here\n\n";
close $tmp5;
eval { Lego::PartsList->from_file( $tmp5->filename ) };
like( $@, qr/no parts found/, 'empty parts file dies' );

done_testing();

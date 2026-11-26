#!/usr/bin/env perl
# The AUTHOR / BUGS AND SUPPORT / LICENSE / TRADEMARKS POD sections are
# duplicated in every module and CLI, and silent drift there would mean
# files claiming different license terms, contacts, or trademark
# attribution.  Lock them all to one canonical block.  (Guard added after
# Claude review feedback on issue #12.)

use strict;
use warnings;
use utf8;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

use File::Spec ();
use Test::More;

# Everything that ships with a =cut-terminated POD block: the modules
# (globbed, so a new module is guarded the moment it lands) and all
# three CLIs, maintainer tool included.
my @files = (
	( glob File::Spec->catfile( 'lib', 'Lego', '*.pm' ) ),
	File::Spec->catfile( 'bin', 'part-colors' ),
	File::Spec->catfile( 'bin', 'brick-labels' ),
	File::Spec->catfile( 'bin', 'generate-rebrickable-fixtures' ),
);

cmp_ok( scalar @files, '>=', 9,
	'found the six modules and three CLIs (at least)' );

# Everything from the AUTHOR heading up to (not including) the closing
# =cut is the boilerplate under guard.
my %block;
for my $file (@files) {
	open my $fh, '<', $file or die "$file: $!\n";
	my $text = do { local $/; <$fh> };
	close $fh;
	( $block{$file} ) = $text =~ /(^=head1 AUTHOR\b.*?)^=cut/ms;
}

my $canonical = $block{ $files[0] };
defined $canonical or BAIL_OUT("no AUTHOR boilerplate found in $files[0]");

for my $heading ( 'AUTHOR', 'BUGS AND SUPPORT', 'LICENSE', 'TRADEMARKS' ) {
	like( $canonical, qr/^=head1 \Q$heading\E$/m,
		"canonical block has a $heading section" );
}
like( $canonical, qr/GNU General Public License, version 2/,
	'canonical block states GPL version 2' );
like( $canonical, qr/trademark of the LEGO Group of companies/,
	'canonical block acknowledges the LEGO trademark' );

for my $file (@files) {
	ok( defined $block{$file},
		"$file has the AUTHOR through LICENSE boilerplate" );
	is( $block{$file}, $canonical,
		"$file boilerplate matches the canonical block" );
}

done_testing();

#!/usr/bin/env perl
# The distro versions all its modules together: Makefile.PL reads the
# version from Lego::PartsList (VERSION_FROM), so a module drifting out
# of sync would ship under a version PAUSE indexes as a different
# release.  The module list is globbed, so a new module is guarded the
# moment it lands.  (Guard added after Claude review feedback on PR
# #19.)

use strict;
use warnings;
use utf8;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

use File::Spec ();
use Test::More;

my @files = glob File::Spec->catfile( 'lib', 'Lego', '*.pm' );
cmp_ok( scalar @files, '>=', 6, 'found the six modules (at least)' );

# Each module declares its version as a one-line literal; scrape it so
# the guard works without loading anything and stays free of the
# stringy-eval tricks that would trip perlcritic.
my %version;
for my $file (@files) {
	open my $fh, '<', $file or die "$file: $!\n";
	my $text = do { local $/; <$fh> };
	close $fh;
	( $version{$file} ) = $text =~ /^our\s+\$VERSION\s*=\s*['"]([^'"]+)['"]/m;
	ok( defined $version{$file}, "$file declares a \$VERSION" );
}

# Makefile.PL's VERSION_FROM source defines the distro version.
my $canonical = File::Spec->catfile( 'lib', 'Lego', 'PartsList.pm' );
defined $version{$canonical} or BAIL_OUT("no \$VERSION in $canonical");
my $distro = $version{$canonical};

for my $file (@files) {
	is( $version{$file}, $distro, "$file versions with the distro" );
}

done_testing();

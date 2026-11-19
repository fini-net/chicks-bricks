# Makefile.PL - Lego-Tools distribution scaffolding (issue #12, step 4:
# https://github.com/fini-net/chicks-bricks/issues/12).
#
# ExtUtils::MakeMaker on purpose: it has been core since the '90s,
# which matches this repo's core-modules-only ethos, and it is all a
# six-module, two-CLI distro needs.
#
# The distro ships all six Lego:: modules and both public CLIs
# (EXE_FILES), plus the maintainer tool in the tarball WITHOUT
# installing it: bin/generate-rebrickable-fixtures needs
# REBRICKABLE_API_KEY and the live API, so it is maintainer-only.
#
# ABSTRACT is set explicitly rather than via ABSTRACT_FROM: the natural
# source (Lego::PartsList's NAME line) only describes parts lists, but
# the distro also ships the color comparison and label coverage
# analysis.

use strict;
use warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
	NAME               => 'Lego::Tools',
	VERSION_FROM       => 'lib/Lego/PartsList.pm',
	ABSTRACT           => 'LEGO parts-list tools: Rebrickable color comparison and Brick Architect label coverage',
	AUTHOR             => 'Christopher Hicks <chicks@chicks.net>',
	LICENSE            => 'gpl_2',
	MIN_PERL_VERSION   => '5.020',
	EXE_FILES          => [
		'bin/part-colors',
		'bin/brick-labels',
	],
	# Everything below ships in the perl core on the minimum supported
	# perl, so none of it is a hard CPAN dependency; declaring it
	# anyway means a stripped-down perl (container images, distro
	# perl-base installs) resolves anything missing from CPAN instead
	# of failing at runtime.  This list mirrors the actual use lines in
	# lib/ and bin/ (added after review feedback on PR #19).
	PREREQ_PM         => {
		'Digest::SHA'           => 0,
		'Encode'                => 0,
		'File::Path'            => 0,
		'File::Spec'            => 0,
		'FindBin'               => 0,
		'Getopt::Long'          => 0,
		'HTTP::Tiny'            => 0,
		'IO::Uncompress::Unzip' => 0,
		'JSON::PP'              => 0,
		'List::Util'            => 0,
		'Pod::Usage'            => 0,
		'Scalar::Util'          => 0,
		'Time::HiRes'           => 0,
	},
	# Test::More ships with perl, but declaring it is standard practice
	# and mirrors the cpanfile's test_requires.
	TEST_REQUIRES      => {
		'Test::More' => 0,
	},
	META_MERGE         => {
		'meta-spec' => { version => 2 },
		# Optional at runtime: the tools detect the absence of an SSL
		# backend and exit with a message.  Declared as recommendations
		# so the metadata still advertises them (see also cpanfile,
		# which ships in the tarball).  EUMM has no native
		# WriteMakefile argument for this, hence META_MERGE prereqs.
		prereqs     => {
			runtime => {
				recommends => {
					'IO::Socket::SSL' => 0,
					'Net::SSLeay'     => 0,
				},
			},
		},
		resources   => {
			repository => {
				url  => 'https://github.com/fini-net/chicks-bricks.git',
				web  => 'https://github.com/fini-net/chicks-bricks',
				type => 'git',
			},
			bugtracker => {
				web => 'https://github.com/fini-net/chicks-bricks/issues',
			},
		},
	},
);

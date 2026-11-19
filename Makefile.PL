# Makefile.PL - Lego::Tools distribution scaffolding (issue #12 step 4).
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

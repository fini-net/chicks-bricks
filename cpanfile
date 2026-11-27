# cpanfile - declares what chicks-bricks needs to run.
#
# This project is core-modules-only: the only hard requirement is perl
# itself (>= 5.20). The recommends below cover the one soft spot - HTTPS
# fetching via HTTP::Tiny needs an SSL backend, and the tools detect its
# absence and exit with a message, so it stays a recommendation rather
# than a requirement. Everything else used (JSON::PP, Digest::SHA,
# IO::Compress, File::*, Getopt::Long, Pod::Usage, ...) ships with perl.
#
# This file also gives prompt tooling like starship something to detect
# the project as Perl by, since starship only scans the repo root.

requires 'perl', '5.020';

recommends 'IO::Socket::SSL';
recommends 'Net::SSLeay';

test_requires 'Test::More';

# Coverage tooling for the CI coverage job (.github/workflows/
# coverage.yml) and `just cover` - a develop-time concern only, so it
# lives in its own phase rather than next to the runtime recommends
# above.
on 'develop' => sub {
	recommends 'Devel::Cover';
	recommends 'Devel::Cover::Report::Clover';
};

package Lego::Constants;

# Shared constants for the Lego:: modules.  Keep this list tiny: only
# values genuinely used in more than one module belong here, so the
# modules cannot drift apart.

use strict;
use warnings;

use Exporter qw(import);

our @EXPORT_OK = qw($MOC_ISSUE_URL $SAFE_NUMBER);

# Rebrickable removed the MOC endpoints from API v3 on 2020-04-19
# ("too many sites stealing our MOC data") - they answer 403 for every
# key, so MOC parts lists must come from --parts-file instead.
our $MOC_ISSUE_URL = 'https://github.com/fini-net/chicks-bricks/issues/2';

# Part and set numbers are interpolated into request paths, so they must
# look like catalog numbers and not URL plumbing.  3684c01, 3068b, and
# 850425-1 all pass.
our $SAFE_NUMBER = qr{\A[\w.-]+\z};

1;

__END__

=head1 NAME

Lego::Constants - shared constants for the Lego:: modules

=head1 SYNOPSIS

	use Lego::Constants qw($MOC_ISSUE_URL $SAFE_NUMBER);

=head1 DESCRIPTION

Holds the few values shared between modules so they cannot drift apart:
the URL documenting the removed Rebrickable MOC endpoints, and the
pattern every part/set number must match before it is interpolated into a
request path.

=cut

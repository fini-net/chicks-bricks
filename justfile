# project justfile

# Pass recipe arguments as positional shell parameters ($1, $2, ...)
# instead of {{...}} text substitution, so bash quoting — not just's
# templater — owns argument handling (injection-safe; see #347)
set positional-arguments := true

import? '.just/compliance.just'
import? '.just/gh-process.just'
import? '.just/pr-hook.just'
import? '.just/shellcheck.just'
import? '.just/cue-verify.just'
import? '.just/claude.just'
import? '.just/copilot.just'
import? '.just/repo-toml.just'
import? '.just/template-sync.just'

# list recipes (default works without naming it)
[group('Utility')]
list:
    just --list
    @echo "{{GREEN}}Your justfile is waiting for more scripts and snippets{{NORMAL}}"

# run the perl test suite (live API tests skip without REBRICKABLE_API_KEY)
[group('Test')]
test:
    prove -lr t/

# build the CPAN tarball and prove it offline from a pristine extract
# (issue #12 step 4; ExtUtils::MakeMaker ships with perl)
[group('Test')]
disttest:
    perl Makefile.PL
    make manifest
    rm -f Lego-Tools-*.tar.gz
    make dist
    make disttest
    make realclean

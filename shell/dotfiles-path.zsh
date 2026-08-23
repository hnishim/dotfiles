# Shared PATH additions for interactive shells.
# This file is sourced from ~/.zprofile by textlint-setup.sh.

typeset -g DOTFILES_ROOT="${${(%):-%N}:A:h:h}"
export PATH="$DOTFILES_ROOT/bin:$PATH"

# The control node's tools: the Mac that runs make. Install or update them with
#   make tools        (brew bundle --file=Brewfile)
# CI pins its own versions (.github/requirements-ci.txt); Homebrew installs the
# current releases, so a local make check can run newer linters than CI does.
brew "ansible"
brew "ansible-lint"
brew "opentofu"
brew "uv"           # make tui, and the console UI's tests in make check
brew "jq"           # scripts/lab-ctl.sh, and the Makefile's SSH keys for OpenTofu
brew "shellcheck"
brew "yamllint"
brew "gnupg"        # scripts/kali-fetch.sh: checks Kali's signature
brew "sevenzip"     # scripts/kali-fetch.sh: 7zz extracts the image

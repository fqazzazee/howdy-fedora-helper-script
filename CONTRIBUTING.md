# Contributing

Thank you for your interest in contributing to the Howdy Fedora Helper Script!

## Ways to Contribute

### Report Issues

If you encounter a problem:

1. Run the diagnostic first: `sudo ./install-howdy.sh --diagnose`
2. Check the [FAQ](../../wiki/FAQ) for known issues
3. Search existing issues to avoid duplicates
4. Open a new issue with:
   - Your Fedora version (`cat /etc/fedora-release`)
   - Your GNOME version (`gnome-shell --version`)
   - Your laptop make/model
   - Full diagnostic output
   - Steps to reproduce

### Add Your Hardware

If the installer works on your laptop, add it to the [Tested Hardware](../../wiki/Tested-Hardware) wiki page.

### Submit Fixes

1. Fork the repository
2. Create a branch: `git checkout -b fix/description`
3. Make your changes
4. Test on your Fedora system
5. Submit a pull request

### Improve Documentation

Documentation improvements are always welcome:
- Fix typos or unclear instructions
- Add examples
- Expand troubleshooting sections
- Translate documentation

## Code Guidelines

### Shell Script Style

- Use `bash` with `set -euo pipefail`
- Use `[[ ]]` for conditionals (not `[ ]`)
- Quote variables: `"$variable"` not `$variable`
- Use meaningful function names
- Add comments for non-obvious logic
- Use the existing logging functions: `info()`, `success()`, `warn()`, `fail()`, `error()`

### SELinux Policy

The SELinux type enforcement policy lives in `selinux/howdy_pam.te`. If you need to extend or tighten it:

- Edit `selinux/howdy_pam.te` directly (not the heredoc in the script)
- Bump the module version number in the `module` declaration
- Document the scope of any new `allow` rules — the existing file has inline comments explaining why each permission is granted
- Test with `checkmodule -M -m -o howdy_pam.mod howdy_pam.te && semodule_package -o howdy_pam.pp -m howdy_pam.mod && sudo semodule -i howdy_pam.pp`

### Testing

Before submitting:

1. Run a fresh install on a clean Fedora system (VM is fine)
2. Test the diagnostic: `sudo ./install-howdy.sh --diagnose`
3. Test the auto-fix: `sudo ./install-howdy.sh --fix`
4. Test the uninstaller: `sudo ./install-howdy.sh --uninstall`
5. Verify face authentication works for GDM and sudo

### Commit Messages

Use clear, descriptive commit messages:

```
Good:
- Fix dlib symlink detection for Python 3.14
- Add SELinux policy for Fedora 44
- Update FAQ with new troubleshooting step

Bad:
- fix
- update
- changes
```

## Pull Request Process

1. Ensure your code follows the style guidelines
2. Update documentation if needed
3. Update CHANGELOG.md if adding features or fixes
4. Request review from maintainers
5. Address review feedback

## Questions?

Open an issue with the "question" label or start a discussion.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

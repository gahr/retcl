How to make a new release
====

1. update package version in retcl.tm
2. update package version in doc/retcl.man
3. regenerate the documentation
4. update package version expectation in test/001-pkg-version.test
5. rename the retcl-${VERSION}.tm symlink
6. commit these changes with a commit message "Release: retcl-${VERSION}"
7. tag this commit as ${VERSION} with a message of "retcl-${VERSION}"
8. push both the commit and the tag, edit the release notes on github

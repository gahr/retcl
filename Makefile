# vim: set ts=4:

TCLSH?=	tclsh8.7
REPO=	fossil info | grep ^repository | awk '{print $$2}'

all:
	@echo "Supported targets: docs, man, test, clean"

.PHONY: docs
docs: README.adoc
	asciidoctor -b xhtml5  -a generate_manpage=yes -a toc -d article -o docs/index.html README.adoc
	sed -i '' "1s|^|<div class='fossil-doc' data-title='retcl - Redis client library for Tcl'>\n|" docs/index.html

man: README.adoc
	asciidoctor -b manpage -a generate_manpage=yes -o retcl.n README.adoc

.PHONY: test
test:
	${TCLSH} test/all.tcl

clean:
	rm -f retcl.n

git:
	@if [ -e git-import ]; then \
	    echo "The 'git-import' directory already exists"; \
	    exit 1; \
	fi; \
	git init -b master git-import && cd git-import && \
	fossil export --git --rename-trunk master --repository `${REPO}` | \
	git fast-import && git reset --hard HEAD && \
	git remote add origin git@github.com:gahr/retcl.git && \
	git push -f origin master && \
	cd .. && rm -rf git-import


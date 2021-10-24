TCLSH?=	tclsh8.7

all:
	@echo "Supported targets: docs, man, test, clean"

.PHONY: docs
docs: README.adoc
	asciidoctor -b xhtml5  -a generate_manpage=yes -a toc -d article -o docs/index.html README.adoc

man: README.adoc
	asciidoctor -b manpage -a generate_manpage=yes -o retcl.n README.adoc

.PHONY: test
test:
	${TCLSH} test/all.tcl

clean:
	rm -f retcl.n

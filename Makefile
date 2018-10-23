TCLSH?=	tclsh8.6

all:
	@echo "Supported targets: doc, site, test, clean"

doc: README.adoc
	asciidoctor -b manpage -a generate_manpage=yes -o retcl.n README.adoc

site:
	asciidoctor -b xhtml5  -a generate_manpage=yes -a toc -d article -o www/index.html README.adoc

.PHONY: test
test:
	${TCLSH} test/all.tcl

clean:
	rm -f retcl.n

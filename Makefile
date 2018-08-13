TCLSH?=	tclsh8.6

.PHONY: doc test

all: doc test

doc: doc/retcl.n doc/retcl.html

doc/retcl.n: doc/retcl.adoc README.adoc
	asciidoctor -b manpage -o doc/retcl.n doc/retcl.adoc

doc/retcl.html: doc/retcl.adoc README.adoc
	asciidoctor -b xhtml5 -o doc/retcl.html doc/retcl.adoc

test:
	${TCLSH} test/all.tcl

clean:
	rm -f doc/retcl.n doc/retcl.html

TCLSH?=	tclsh8.6

.PHONY: doc test

all: doc test

doc: retcl.n retcl.html

retcl.n: retcl.adoc
	asciidoctor -b manpage -o retcl.n retcl.adoc

retcl.html: retcl.adoc
	asciidoctor -b xhtml5 -o retcl.html retcl.adoc

test:
	${TCLSH} test/all.tcl

clean:
	rm -f retcl.n retcl.html

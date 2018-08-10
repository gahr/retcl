TCLSH?=	tclsh8.6

.PHONY: doc test

all: doc test

doc: retcl.n retcl.html

retcl.n: README.adoc
	asciidoctor -b manpage -o retcl.n README.adoc

retcl.html: README.adoc
	asciidoctor -b xhtml5 -o retcl.html README.adoc

test:
	${TCLSH} test/all.tcl

clean:
	rm -f retcl.n retcl.html

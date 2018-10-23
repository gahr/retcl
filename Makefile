TCLSH?=	tclsh8.6

all:
	@echo "Supported targets: doc, test, clean"

doc: README.adoc
	asciidoctor -b manpage -a generate_manpage=yes -o retcl.n README.adoc
	asciidoctor -b xhtml5  -a generate_manpage=yes -a toc -d article -o retcl.html README.adoc

test:
	${TCLSH} test/all.tcl

clean:
	rm -f retcl.n retcl.html

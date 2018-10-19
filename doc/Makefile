ARTIFACTS=	doc/retcl.n doc/retcl.html

doc-all: ${ARTIFACTS}

doc-clean:
	rm -f ${ARTIFACTS}

doc/retcl.n: doc/retcl.adoc README.adoc
	asciidoctor -b manpage -o doc/retcl.n doc/retcl.adoc

doc/retcl.html: doc/retcl.adoc README.adoc
	asciidoctor -a toc -d article -b xhtml5 -o doc/retcl.html doc/retcl.adoc

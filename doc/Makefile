all: man html

man: retcl.man
	dtplite -o retcl.n nroff retcl.man

html: retcl.man
	dtplite -o retcl.html -style docs.css html retcl.man

clean:
	rm retcl.n retcl.html


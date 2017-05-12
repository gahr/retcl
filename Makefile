TCLSH?=	tclsh8.6

.PHONY: doc test

all: doc test

doc:
	${MAKE} -C doc

test:
	${TCLSH} test/all.tcl

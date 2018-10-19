TCLSH?=	tclsh8.6

SUBS=	test doc

all: ${SUBS:S/$$/-all/}

clean: ${SUBS:S/$$/-clean/}

.for f in ${SUBS}
.include "${f}/Makefile"
.endfor

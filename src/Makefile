prefix := $(DESTDIR)

INST_SCRIPTS := \
    upgrade-ses.sh

.PHONY: install
install:
	set -x ; \
	mkdir -p $(prefix)/usr/bin
	for f in $(INST_SCRIPTS) ; do \
		install -m 0755 -D $$f $(prefix)/usr/bin ; \
	done

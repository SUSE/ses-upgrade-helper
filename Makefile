prefix := $(DESTDIR)/

INST_SCRIPTS := \
    upgrade-to-ses3.sh

.PHONY: install
install:
	mkdir -p $(prefix)
	for f in $(INST_SCRIPTS) ; do \
		echo $$f ; \
		install -m 0755 -D src/$$f $(prefix)/usr/bin ; \
	done

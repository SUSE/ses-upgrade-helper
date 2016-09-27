prefix := $(DESTDIR)

MAN_PAGES := \
    upgrade-ses.sh.8

.PHONY: install
install:
	set -x ; \
	mkdir -p $(prefix)/usr/share/man/man8
	for f in $(MAN_PAGES) ; do \
		install -m 0644 -D $$f $(prefix)/usr/share/man/man8 ; \
	done

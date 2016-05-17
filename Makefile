prefix := $(DESTDIR)/

INST_FILES := \
    AUTHORS \
    LICENSE \
    README

INST_SCRIPTS := \
    src/upgrade-to-ses3.sh

.PHONY: install
install:
	mkdir -p $(prefix)
	for f in $(INST_FILES) ; do \
		install -m 0644 -D $$f $(prefix)/usr/share/ses-upgrade-helper ; \
	done
	for f in $(INST_SCRIPTS) ; do \
		install -m 0755 -D $$f $(prefix)/usr/bin ; \
	done

# Build iMerge from this folder and install it to ~/Applications.
.PHONY: install run

install:
	./install.sh

run:
	open "$(HOME)/Applications/iMerge.app"

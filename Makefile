SHELL = /bin/sh
NAME = zfs-backup
VERSION = 0.4
CP ?= cp
CHMOD ?= chmod
PREFIX ?= /usr/local
WHICH ?= which

all: clean install

install:
	$(CP) ./zfs-backup.sh $(PREFIX)/bin/zfs-backup
	$(CHMOD) +x $(PREFIX)/bin/zfs-backup
	$(WHICH) zfs-backup

clean:
	rm -f $(PREFIX)/bin/zfs-backup
all:

install:
	install -d $(DESTDIR)$(PREFIX)/etc/default
	install example.cfg $(DESTDIR)$(PREFIX)/etc/default/zfs-backup
	install -d $(DESTDIR)$(PREFIX)/etc/cron.hourly
	install zfs-backup.cron.hourly $(DESTDIR)$(PREFIX)/etc/cron.hourly/zfs-backup
	install -d $(DESTDIR)$(PREFIX)/sbin
	install zfs-backup.sh $(DESTDIR)$(PREFIX)/sbin/zfs-backup

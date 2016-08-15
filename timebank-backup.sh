#!/bin/sh

#  Copyright (C) 2016 Open Lab Athens.
#
#  This program is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
#  @license GPL-3.0+ <http://spdx.org/licenses/GPL-3.0+>
#
#
#  Changes
#
#  15-8-2016: Rowan Thorpe <rowan@rowanthorpe.com>: Original commit

# To be run from cron.daily

set -e

test 0 -eq $(id -u) || { printf 'Run this as root\n' >&2; exit 1; }

verbose=0
! test 'x-v' = "x${1}" || verbose=1

backupdir="$(cd; mktemp -d "${TMPDIR:-/tmp}/timebank-backup-$(date +%Y%m%d)-XXXXX")"
trap '! test -d "${backupdir}" || rm -fr "${backupdir}"' EXIT
backupdir_name="$(basename "${backupdir}")"
backupdir_parent="$(dirname "${backupdir}")"

cd "${backupdir}"
sudo -u postgres -i pg_dump --create --clean --if-exists --quote-all-identifiers --serializable-deferrable timebank >"db.sql"
mkdir -p etc
cp -axH /etc/freeswitch etc/freeswitch
mkdir -p usr/local/bin
cp -axH /usr/local/bin/tts_cache usr/local/bin/tts_cache
mkdir -p usr/local/etc
cp -axH /usr/local/etc/nginx usr/local/etc/nginx
mkdir -p usr/local/share/freeswitch/scripts
cp -axH /usr/local/share/freeswitch/scripts/lua usr/local/share/freeswitch/scripts/lua
mkdir -p var/lib/timebank
cp -axH /var/lib/timebank/ var/lib/timebank
chown -R root:root .
cd ..

tar --create --xz --file "${backupdir_name}.tar.xz" "${backupdir_name}"
rm -fr "${backupdir_name}"

mv "${backupdir_name}.tar.xz" ~/timebank/backups/
find ~/timebank/backups -type f -mtime +30 -delete
test 0 -eq ${verbose} || printf 'Backup completed to "%s"\n' "${backupdir}.tar.xz" >&2

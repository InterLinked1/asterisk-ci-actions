#!/usr/bin/env bash
CIDIR=$(dirname $(readlink -fn $0))
OUTPUT_DIR=/tmp/asterisk_ci/

source $CIDIR/ci.functions

if [ "${OUTPUT_DIR: -1}" != "/" ] ; then
	OUTPUT_DIR+=/
fi

ASTETCDIR=$DESTDIR/etc/asterisk

asterisk_corefile_glob() {
	local pattern=$(/sbin/sysctl -n kernel.core_pattern)

	# If core_pattern is a pipe there isn't much we can do
	if [[ ${pattern:0:1} == "|" ]] ; then
		echo "core*"
	else
		echo "${pattern%%%*}*"
	fi
}

run_tests_socket() {
	sudo $ASTERISK ${USER_GROUP:+-U ${USER_GROUP%%:*} -G ${USER_GROUP##*:}} -gn -C $CONFFILE
	for n in {1..5} ; do
		sleep 3
		$ASTERISK -rx "core waitfullybooted" -C $CONFFILE && break
	done
	sleep 1
	$ASTERISK -rx "core show settings" -C $CONFFILE

	begin_group "Running Unit Tests"
	if [ x"${UNITTEST_COMMAND}" != x ] ; then
		IFS=';'
		for test in ${UNITTEST_COMMAND} ; do
			$ASTERISK -rx "$test" -C $CONFFILE
		done
		unset IFS
	else
		$ASTERISK -rx "test execute all" -C $CONFFILE
	fi
	end_group

	$ASTERISK -rx "test show results failed" -C $CONFFILE
	$ASTERISK -rx "test generate results xml $OUTPUTFILE" -C $CONFFILE
	$ASTERISK -rx "core stop now" -C $CONFFILE
	xmlstarlet sel -t -v "//failure" $OUTPUTFILE && return 1
	return 0
}

# If DESTDIR is used to install and run asterisk from non standard locations,
# the directory entries in asterisk.conf need to be munged to prepend DESTDIR.
ALTERED=$(head -10 "$ASTETCDIR/asterisk.conf" | grep -q "DESTDIR" && echo yes)
if [ x"$ALTERED" = x ] ; then
	# In the section that starts with [directories and ends with a blank line,
	# replace "=> " with "=> ${DESTDIR}"
	sed -i -r -e "/^\[directories/,/^$/ s@=>\s+@=> ${DESTDIR}@" "$ASTETCDIR/asterisk.conf"
fi

cat <<-EOF > "$ASTETCDIR/logger.conf"
	[logfiles]
	full => notice,warning,error,debug,verbose
	console => notice,warning,error
EOF

echo "[default]" > "$ASTETCDIR/extensions.conf"

cat <<-EOF > "$ASTETCDIR/manager.conf"
	[general]
	enabled=yes
	bindaddr=127.0.0.1
	port=5038

	[test]
	secret=test
	read = system,call,log,verbose,agent,user,config,dtmf,reporting,cdr,dialplan
	write = system,call,agent,user,config,command,reporting,originate
EOF

cat <<-EOF > "$ASTETCDIR/http.conf"
	[general]
	enabled=yes
	bindaddr=127.0.0.1
	bindport=8088
EOF

cat <<-EOF > "$ASTETCDIR/modules.conf"
	[modules]
	autoload=yes
	noload=res_mwi_external.so
	noload=res_mwi_external_ami.so
	noload=res_ari_mailboxes.so
	noload=res_stasis_mailbox.so
EOF

cat <<-EOF >> "$ASTETCDIR/sorcery.conf"
	[res_pjsip_pubsub]
	resource_list=memory
EOF

ASTERISK="$DESTDIR/usr/sbin/asterisk"
CONFFILE=$ASTETCDIR/asterisk.conf
OUTPUTFILE=${OUTPUT_XML:-${OUTPUT_DIR}/unittests-results.xml}
EXPECT="$(which expect 2>/dev/null || : )"

[ x"$USER_GROUP" != x ] && sudo chown -R $USER_GROUP $OUTPUT_DIR

rm -rf $ASTETCDIR/extensions.{ael,lua} || :

TESTRC=0

run_tests_socket || TESTRC=1

# Cleanup "just in case"
sudo killall -qe -ABRT $ASTERISK

runner rsync -vaH $DESTDIR/var/log/asterisk/. $OUTPUT_DIR

[ x"$USER_GROUP" != x ] && sudo chown -R $USER_GROUP $OUTPUT_DIR

for core in $(asterisk_corefile_glob)
do
	if [ -f "$core" ] && [ "${core##*.}" != "txt" ]
	then
		echo "*** Found a core file ($core) after running unit tests ***"
		set -x
		sudo $DESTDIR/var/lib/asterisk/scripts/ast_coredumper --outputdir=$OUTPUT_DIR --no-default-search $core
		TESTRC=1
	fi
done

exit $TESTRC

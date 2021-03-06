#!/bin/sh
#
# More or less a copy of jenkins_deploy_cf.sh, but with the CF bits removed - this is a temporary solution until CF is up
set +x
set -e

# Ensure we have a sensible umask
umask 022

FATAL_COLOUR='\e[1;31m'
INFO_COLOUR='\e[1;36m'
NONE_COLOUR='\e[0m'

FATAL(){
	COLOUR FATAL
	echo "FATAL $@"
	COLOUR NONE

	exit 1
}

INFO(){
	COLOUR INFO
	echo "INFO $@"
	COLOUR NONE
}

COLOUR(){
	echo "$TERM" | grep -qE "^(xterm|rxvt)(-256color)?$" || return 0

	eval colour="\$${1}_COLOUR"

	echo -ne "$colour"
}


ROOT_USER="${ROOT_USER:-root}"
ROOT_GROUP="${ROOT_USER:-wheel}"

JENKINS_USER="${JENKINS_USER:-jenkins}"
JENKINS_GROUP="${JENKINS_GROUP:-jenkins}"

[ x"$USER" != x"$ROOT_USER" ] && FATAL This script MUST be run as $ROOT_USER

LOG_ROTATE_COUNT='10'
LOG_ROTATE_SIZE='10m'
LOG_ROTATE_FREQUENCY='daily'
# Fonts & fontconfig are required for AWT
BASE_PACKAGES='git java-1.8.0-openjdk-headless httpd dejavu-sans-fonts fontconfig unzip'
SSH_KEYSCAN_TIMEOUT='10'

JENKINS_APPNAME="${JENKINS_APPNAME:-jenkins}"
JENKINS_RELEASE_TYPE="${JENKINS_RELEASE_TYPE:-STABLE}"

JENKINS_STABLE_WAR_URL="${JENKINS_STABLE_WAR_URL:-http://mirrors.jenkins-ci.org/war-stable/latest/jenkins.war}"
JENKINS_LATEST_WAR_URL="${JENKINS_LATEST_WAR_URL:-http://mirrors.jenkins-ci.org/war/latest/jenkins.war}"

# Jenkins will not start without this plugin
DEFAULT_PLUGINS="https://updates.jenkins-ci.org/latest/matrix-auth.hpi"

# Parse options
for i in `seq 1 $#`; do
	[ -z "$1" ] && break

	case "$1" in
		-n|--name)
			JENKINS_APPNAME="$2"
			shift 2
			;;
		-r|--release-type)
			JENKINS_RELEASE_TYPE="$2"
			shift 2
			;;
		-c|--config-repo)
			JENKINS_CONFIG_NEW_REPO="$2"
			shift 2
			;;
		--deploy-config-repo)
			DEPLOY_JENKINS_CONFIG_NEW_REPO="$2"
			shift 2
			;;
		-K|--ssh-keyscan-host)
			[ -n "$SSH_KEYSCAN_HOSTS" ] && SSH_KEYSCAN_HOSTS="$SSH_KEYSCAN_HOSTS $2" || SSH_KEYSCAN_HOSTS="$2"
			shift 2
			;;
		-C|--config-seed-repo)
			JENKINS_CONFIG_SEED_REPO="$2"
			shift 2
			;;
		--deploy-config-seed-repo)
			DEPLOY_JENKINS_CONFIG_SEED_REPO="$2"
			shift 2
			;;
		-S|--scripts-repo)
			JENKINS_SCRIPTS_REPO="$2"
			shift 2
			;;
		--scripts-repo)
			DEPLOY_JENKINS_SCRIPTS_REPO="$2"
			shift 2
			;;
		-F|--fix-firewall)
			FIX_FIREWALL=1
			shift
			;;
		-P|--plugins)
			# comma separated list of plugins to preload
			PLUGINS="$DEFAULT_PLUGINS,$2"
			shift 2
			;;
		*)
			FATAL "Unknown option $1"
			;;
	esac
done

case "$JENKINS_RELEASE_TYPE" in
	[Ll][Aa][Tt][Ee][Ss][Tt])
		JENKINS_WAR_URL="$JENKINS_LATEST_WAR_URL"
		;;

	[Ss][Tt][Aa][Bb][Ll][Ee])
		JENKINS_WAR_URL="$JENKINS_STABLE_WAR_URL"
		;;
	*)
		echo "Unknown Jenkins type: $JENKINS_RELEASE_TYPE"
		echo "Valid types: latest or stable"

		exit 1
esac

INSTALL_BASE_DIR="${INSTALL_BASE_DIR:-/opt}"
DEPLOYMENT_DIR="$INSTALL_BASE_DIR/$JENKINS_APPNAME"

if [ -z "$JENKINS_CONFIG_SEED_REPO" ]; then
	FATAL No JENKINS_CONFIG_SEED_REPO provided
fi

if [ -z "$JENKINS_SCRIPTS_REPO" ]; then
	FATAL No JENKINS_SCRIPTS_REPO provided
fi

[ -d "$DEPLOYMENT_DIR" ] && FATAL Deployment "$DEPLOYMENT_DIR" already exists, please remove


INFO "Checking if all required packages are installed - this may take a while"
for _i in $BASE_PACKAGES; do
	if ! rpm --quiet -q "$_i"; then
		INFO . Installing $_i
		yum install -q -y "$_i"
	fi
done

INFO Determining SELinux status
sestatus 2>&1 >/dev/null && SELINUX_ENABLED=true

INFO "Checking if we need to add the '$JENKINS_USER' user"
if ! id $JENKINS_USER 2>&1 >/dev/null; then
	INFO Adding $JENKINS_USER
	useradd -d "$DEPLOYMENT_DIR" -r -s /sbin/nologin "$JENKINS_USER"
fi

INFO "Creating $DEPLOYMENT_DIR layout"
mkdir -p "$DEPLOYMENT_DIR"/{bin,config,.ssh,.git} "/var/log/$JENKINS_APPNAME"

INFO Creating required directories
[ -d ~/.ssh ] || mkdir -p 0700 ~/.ssh

# Suck in the SSH keys for our Git repos - we also add it to ~/.ssh/known_hosts to silence
# the initial clone as this is done as the current user
INFO "Attempting to add SSH keys to $DEPLOYMENT_DIR/.ssh/known_hosts & ~/.ssh/known_hosts"
for i in "$JENKINS_CONFIG_REPO" "$JENKINS_CONFIG_SEED_REPO" "$JENKINS_SCRIPTS_REPO"; do
	# We only want to scan a host if we are connecting via SSH
	echo $i | grep -Eq '^((https?|file|git)://|~?/)' && continue

	# Silence ssh-keyscan
	echo $i | sed -re 's,^[a-z]+://([^@]+@)([a-z0-9\.-]+)([:/].*)?$,\2,g' | \
		( xargs ssh-keyscan -T $SSH_KEYSCAN_TIMEOUT ) 2>/dev/null | tee -a ~/.ssh/known_hosts >>"$DEPLOYMENT_DIR/.ssh/known_hosts"
done


# ... and any extra keys
for i in $SSH_KEYSCAN_HOSTS; do
	INFO "Adding additional $i host to $DEPLOYMENT_DIR/.ssh/known_hosts"
	ssh-keyscan -T $SSH_KEYSCAN_TIMEOUT $i 2>/dev/null

done | sort -u | tee -a ~/.ssh/known_hosts >>"$DEPLOYMENT_DIR/.ssh/known_hosts"

INFO Fixing any duplicate known_hosts entries
for _d in ~/.ssh/known_hosts "$DEPLOYMENT_DIR/.ssh/known_hosts"; do
	FIX_DUPLICATES="`mktemp /tmp/SSH.XXXX`"

	sort -u "$DEPLOYMENT_DIR/.ssh/known_hosts" >"$FIX_DUPLICATES"

	if ! diff -q "$FIX_DUPLICATES" ~/.ssh/known_hosts 2>&1 >/dev/null; then
		INFO Removing duplicates
		mv -f "$FIX_DUPLICATES" ~/.ssh/known_hosts
	fi

	[ -f "$FIX_DUPLICATES" ] && rm -rf "$FIX_DUPLICATES"
done

INFO "Ensuring we have the latest Jenkins $JENKINS_RELEASE_TYPE release"
[ -f "jenkins-$JENKINS_RELEASE_TYPE.war" ] && CURL_OPT="-z jenkins-$JENKINS_RELEASE_TYPE.war"
if ! curl --progress-bar -L $CURL_OPT -o jenkins-$JENKINS_RELEASE_TYPE.war "$JENKINS_WAR_URL"; then
	[ -f "jenkins-$JENKINS_RELEASE_TYPE.war" ] && rm -f jenkins-$JENKINS_RELEASE_TYPE.war

	FATAL "Downloading $JENKINS_WAR_URL failed"
fi

INFO Installing Jenkins WAR file
cp "jenkins-$JENKINS_RELEASE_TYPE.war" "$DEPLOYMENT_DIR"

cd "$DEPLOYMENT_DIR"

INFO "Cloning ${DEPLOY_JENKINS_CONFIG_SEED_REPO:-$JENKINS_CONFIG_SEED_REPO}"
git clone -q "${DEPLOY_JENKINS_CONFIG_SEED_REPO:-$JENKINS_CONFIG_SEED_REPO}" -b master jenkins_home

if ! [ x"$DEPLOY_JENKINS_CONFIG_SEED_REPO" = x"$JENKINS_CONFIG_SEED_REPO" ]; then
	INFO 'Fixing seed repo origin'
	cd jenkins_home

	git remote set-url origin "$JENKINS_CONFIG_SEED_REPO"

	cd - 2>&1 >/dev/null
fi

if [ -n "$JENKINS_CONFIG_NEW_REPO" ]; then
	cd jenkins_home

	INFO Renaming origin repository as seed repository
	git remote rename origin seed

	INFO Adding new origin repository
	git remote add origin ${DEPLOY_JENKINS_CONFIG_NEW_REPO:-$JENKINS_CONFIG_NEW_REPO}

	INFO Pushing configuration to new repository
	git push -q origin master || FATAL "Unable to push to ${DEPLOY_JENKINS_CONFIG_NEW_REPO:-$JENKINS_CONFIG_NEW_REPO} - does the repository exist and/or do permissions allow pushing?"

	if ! [ x"$DEPLOY_JENKINS_CONFIG_NEW_REPO" = x"$JENKINS_CONFIG_NEW_REPO" ]; then
		INFO 'Fixing config repo origin'
		git remote set-url origin "$JENKINS_CONFIG_NEW_REPO"
	fi

	cd - 2>&1 >/dev/null
fi

cd bin

INFO Extracting Jenkins CLI
unzip -qqj "$DEPLOYMENT_DIR/jenkins-$JENKINS_RELEASE_TYPE.war" WEB-INF/jenkins-cli.jar

cd - 2>&1 >/dev/null

# Using submodules is painful, as the submodule is a point-in-time checkout, unless its manually updated
# and then the parent repo has the change committed
INFO "Cloning ${DEPLOY_JENKINS_SCRIPTS_REPO:-$JENKINS_SCRIPTS_REPO}"
git clone -q "${DEPLOY_JENKINS_SCRIPTS_REPO:-$JENKINS_SCRIPTS_REPO}" -b master jenkins_scripts

if ! [ x"$DEPLOY_JENKINS_SCRIPTS_REPO" = x"$JENKINS_SCRIPTS_REPO" ]; then
	cd jenkins_scripts

	INFO 'Fixing scripts repo origin'
	git remote set-url origin "$JENKINS_SCRIPTS_REPO"

	cd - 2>&1 >/dev/null
fi

INFO "Creating $JENKINS_APPNAME configuration"
cat >"$DEPLOYMENT_DIR/config/$JENKINS_APPNAME.config" <<EOF
export JENKINS_HOME="$DEPLOYMENT_DIR/jenkins_home"
export SCRIPTS_DIR="$DEPLOYMENT_DIR/jenkins_scripts"
export JENKINS_CLI_JAR="$DEPLOYMENT_DIR/bin/jenkins-cli.jar"
export JENKINS_LOCATION="localhost:8080"
EOF

INFO "Checking if we need to set a proxy"
if [ -f /etc/wgetrc ] && grep '^http_proxy *= *' /etc/wgetrc; then
	sed -re 's/^http_proxy *= *(.*) *$/export http_proxy='"'"'\1'"'"'/g' /etc/wgetrc >>"$DEPLOYMENT_DIR/config/$JENKINS_APPNAME.config"
fi

INFO Creating startup script
cat>>"$DEPLOYMENT_DIR/bin/$JENKINS_APPNAME-startup.sh" <<EOF
#!/bin/sh

set -e

if [ x"$JENKINS_USER" != x"\$USER" ]; then
	echo FATAL This startup script MUST be run as $JENKINS_USER

	exit 1
fi

[ -f "/etc/sysconfig/$JENKINS_APPNAME" ] && . /etc/sysconfig/$JENKINS_APPNAME

[ -f "/var/log/$JENKINS_APPNAME/$JENKINS_APPNAME.log" ] && gzip -c "/var/log/$JENKINS_APPNAME/$JENKINS_APPNAME.log" >"/var/log/$JENKINS_APPNAME/$JENKINS_APPNAME.log.previous.gz"

java -Djava.awt.headless=true -jar "$DEPLOYMENT_DIR/jenkins-$JENKINS_RELEASE_TYPE.war" --httpListenAddress=127.0.0.1 >/var/log/$JENKINS_APPNAME/$JENKINS_APPNAME.log 2>&1
EOF

INFO Creating httpd reverse proxy setup
cat >/etc/httpd/conf.d/$JENKINS_APPNAME-proxy.conf <<EOF
ProxyPass         "/" "http://127.0.0.1:8080/"
ProxyPassReverse  "/" "http://127.0.0.1:8080/"
EOF

INFO "Creating $JENKINS_APPNAME systemd service"
cat >"$DEPLOYMENT_DIR/config/$JENKINS_APPNAME.service" <<EOF
[Unit]
Description=$JENKINS_APPNAME - Jenkins CI

[Service]
Type=simple
GuessMainPID=yes
ExecStart=$DEPLOYMENT_DIR/bin/$JENKINS_APPNAME-startup.sh
User=$JENKINS_USER

[Install]
WantedBy=multi-user.target
EOF

INFO Generating logrotate config
cat >"$DEPLOYMENT_DIR/config/$JENKINS_APPNAME.rotate" <<EOF
# Logrotate for $JENKINS_APPNAME

/var/log/$JENKINS_APPNAME/$JENKINS_APPNAME.log {
        missingok
        compress
        copytruncate
        $LOG_ROTATE_FREQUENCY
        $LOG_ROTATE_COUNT
        $LOG_ROTATE_SIZE
}
EOF

# Check if there is an existing service
if [ -f "/usr/lib/systemd/system/$JENKINS_APPNAME.service" ]; then
	# ... and stop it
	INFO "Ensuring any existing $JENKINS_APPNAME.service is not running"
	systemctl -q status $JENKINS_APPNAME.service && systemctl -q stop $JENKINS_APPNAME.service

	RELOAD_SYSTEMD=1
fi

INFO Generating SSH keys
ssh-keygen -qt rsa -f "$DEPLOYMENT_DIR/.ssh/id_rsa" -N '' -C "$JENKINS_APPNAME"

INFO Installing service
cp --no-preserve=mode -f "$DEPLOYMENT_DIR/config/$JENKINS_APPNAME.service" "/usr/lib/systemd/system/$JENKINS_APPNAME.service"

if [ -n "$RELOAD_SYSTEMD" ]; then
	INFO "Reloading systemd due to pre-existing $JENKINS_APPNAME.service"
	systemctl -q daemon-reload
fi

INFO Installing config
cp --no-preserve=mode -f "$DEPLOYMENT_DIR/config/$JENKINS_APPNAME.config" "/etc/sysconfig/$JENKINS_APPNAME"

INFO Install logrotate config
cp --no-preserve=mode -f "$DEPLOYMENT_DIR/config/$JENKINS_APPNAME.rotate" /etc/logrotate.d

INFO Ensuring we have the correct ownership
chown -R "$ROOT_USER:$ROOT_GROUP" "$DEPLOYMENT_DIR"
chown -R "$JENKINS_USER:$JENKINS_GROUP" "$DEPLOYMENT_DIR/.ssh" "$DEPLOYMENT_DIR/.git" "$DEPLOYMENT_DIR/jenkins_home" "$DEPLOYMENT_DIR/jenkins_scripts"
chown -R "$JENKINS_USER:$JENKINS_GROUP" /var/log/$JENKINS_APPNAME

INFO Ensuring installation has the correct permissions
chmod 0700 "$DEPLOYMENT_DIR/.ssh"
chmod 0600 "$DEPLOYMENT_DIR/.ssh/id"*

if [ -n "$SELINUX_ENABLED" ]; then
	INFO Fixing SELinux permissions
	chcon --reference=/etc/sysconfig/network "/etc/sysconfig/$JENKINS_APPNAME"
	chcon --reference=/usr/lib/systemd/system/system.slice "/usr/lib/systemd/system/$JENKINS_APPNAME.service"

	INFO Enabling SELinux reverse proxy permissions
	setsebool -P httpd_can_network_connect 1
fi

INFO Setting up Jenkins to install required plugins
cd $DEPLOYMENT_DIR/jenkins_home
cp _init.groovy init.groovy
mv config.xml _config.xml

INFO 'Installing initial plugin(s)'
OLDIFS="$IFS"
IFS=,
[ -d "$DEPLOYMENT_DIR/jenkins_home/plugins" ] || mkdir -p "$DEPLOYMENT_DIR/jenkins_home/plugins"
cd "$DEPLOYMENT_DIR/jenkins_home/plugins"

for p in ${PLUGINS:-$DEFAULT_PLUGINS}; do
	INFO "Downloading $p"

	curl -O "$p"
done
cd -
IFS="$OLDIFS"

INFO "Enabling and starting our services - Jenkins will install required plugins and restart a few times, so this may take a while"
chmod 0755 "$DEPLOYMENT_DIR/bin/$JENKINS_APPNAME-startup.sh"
systemctl enable $JENKINS_APPNAME.service
systemctl enable httpd
systemctl start $JENKINS_APPNAME.service
systemctl start httpd

if [ -n "$FIX_FIREWALL" ]; then
	INFO Permitting access to HTTP
	firewall-cmd --add-service=http --permanent

	INFO Reloading firewall
	firewall-cmd --reload
fi

INFO
INFO Jenkins should be available shortly
INFO
INFO Please wait whilst things startup...
INFO
INFO "Whilst things are starting up you can add Jenkins public key to the Git repo(s)"
INFO
INFO SSH public key:
cat "$DEPLOYMENT_DIR/.ssh/id_rsa.pub"
INFO
INFO "Jenkins is available on the following URL(s):"
INFO
ip addr list | awk '/inet / && !/127.0.0.1/{gsub("/24",""); printf("http://%s\n",$2)}'
INFO

#!/bin/bash
#
# Install the Jenkins JNLP slave LaunchDaemon on OS X

set -u

JENKINS_USER=${JENKINS_USER:-"jenkins"}
JENKINS_HOME=${JENKINS_HOME:-"/var/lib/${JENKINS_USER}"}
JENKINS_CONF=${JENKINS_HOME}/Library/Preferences/org.jenkins-ci.slave.jnlp.conf
MASTER_NAME=""							# set default to jenkins later
MASTER_USER=""							# set default to `whoami` later
MASTER=""
MASTER_PORT=""
MASTER_CERT=""
MASTER_CA=""
SLAVE_NODE=""
SLAVE_TOKEN=""
DEV_PROFILE=""
JAVA_ARGS=${JAVA_ARGS:-""}

function create_user() {
	# see if user exists
	if dscl /Local/Default list /Users | grep -q ${JENKINS_USER} ; then
		echo "Using pre-existing service account ${JENKINS_USER}"
		JENKINS_HOME=`dscl /Local/Default read /Users/Jenkins NFSHomeDirectory | awk '{print $2}'`
		return 0
	fi
	echo "Creating service account ${JENKINS_USER}..."
	# create jenkins group
	NEXT_GID=$((`dscl /Local/Default list /Groups gid | awk '{ print $2 }' | sort -n | grep -v ^[5-9] | tail -n1` + 1))
	sudo dscl /Local/Default create /Groups/${JENKINS_USER}
	sudo dscl /Local/Default create /Groups/${JENKINS_USER} PrimaryGroupID $NEXT_GID
	sudo dscl /Local/Default create /Groups/${JENKINS_USER} Password \*
	sudo dscl /Local/Default create /Groups/${JENKINS_USER} RealName 'Jenkins Node Service'
	# create jenkins user
	NEXT_UID=$((`dscl /Local/Default list /Users uid | awk '{ print $2 }' | sort -n | grep -v ^[5-9] | tail -n1` + 1))
	sudo dscl /Local/Default create /Users/${JENKINS_USER}
	sudo dscl /Local/Default create /Users/${JENKINS_USER} UniqueID $NEXT_UID
	sudo dscl /Local/Default create /Users/${JENKINS_USER} PrimaryGroupID $NEXT_GID
	sudo dscl /Local/Default create /Users/${JENKINS_USER} UserShell /bin/bash
	sudo dscl /Local/Default create /Users/${JENKINS_USER} NFSHomeDirectory ${JENKINS_HOME}
	sudo dscl /Local/Default create /Users/${JENKINS_USER} Password \*
	sudo dscl /Local/Default create /Users/${JENKINS_USER} RealName 'Jenkins Node Service'
	sudo dseditgroup -o edit -a ${JENKINS_USER} -t user ${JENKINS_USER}
}

function install_files() {
	return 0 # prevent actual installation
	# download the LaunchDaemon
	sudo curl --url https://raw.github.com/gist/4136130/d3c9d7275ce78e050d8594037a2d509652a766e5/org.jenkins-ci.slave.jnlp.plist -o /Library/LaunchDaemons/org.jenkins-ci.slave.jnlp.plist
	# create the jenkins home dir
	sudo mkdir ${JENKINS_HOME}
	# download the jenkins JNLP slave script
	sudo curl --url https://raw.github.com/gist/4136130/2553c4cec9bc7ed5557359a22c6c1b61028afa40/slave.jnlp.sh -o ${JENKINS_HOME}/slave.jnlp.sh
	sudo chmod 755 ${JENKINS_HOME}/slave.jnlp.sh
	# jenkins should own jenkin's home directory
	sudo chown -R ${JENKINS_USER}:wheel ${JENKINS_HOME}
	# create a logging space
	if [ ! -d /var/log/${JENKINS_USER} ] ; then
		sudo mkdir /var/log/${JENIKINS_USER}
		sudo chown ${JENKINS_USER}:wheel /var/log/${JENKINS_USER}
	fi
}

function process_args {
	if [ -f ${JENKINS_CONF} ]; then
		sudo chmod 666 ${JENKINS_CONF}
		source ${JENKINS_CONF}
		sudo chmod 400 ${JENKINS_CONF}
	fi
	while [ $# -gt 0 ]; do
		case $1 in
			--node=*) SLAVE_NODE=${1#*=} ;;
			--user=*) MASTER_USER=${1#*=} ;;
			--master=*) MASTER=${1#*=} ;;
			--jnlp-port=*) MASTER_PORT=${1#*=} ;;
			--master-cert=*) MASTER_CERT=${1#*=} ;;
			--master-ca=*) MASTER_CA=${1#*=} ;;
			--profile=*) DEV_PROFILE=${1#*=} ;;
			--java-args=*) JAVA_ARGS=${1#*=} ;;
		esac
		shift
	done
}

function configure_daemon {
	if [ -z $MASTER ]; then
		MASTER=${MASTER:-"http://jenkins"}
		echo
		read -p "URL for Jenkins master [$MASTER]: " RESPONSE
		MASTER=${RESPONSE:-$MASTER}
	fi
	while ! curl --location --url ${MASTER}/jnlpJars/slave.jar --silent --fail --output ${TMPDIR}/$$.slave.jar ; do
		echo "Unable to connect to Jenkins at ${MASTER}"
		read -p "URL for Jenkins master: " MASTER
	done
	MASTER_NAME=`echo $MASTER | cut -d':' -f2 | cut -d'.' -f1 | cut -d'/' -f3`
	PROTOCOL=`echo $MASTER | cut -d':' -f1`
	[ "$PROTOCOL" != "$MASTER" ] || PROTOCOL="http"
	if [ -z $SLAVE_NODE ]; then
		SLAVE_NODE=${SLAVE_NODE:-`hostname -s | tr '[:upper:]' '[:lower:]'`}
		echo
		read -p "Name of this slave on ${MASTER_NAME} [$SLAVE_NODE]: " RESPONSE
		SLAVE_NODE=${RESPONSE:-$SLAVE_NODE}
	fi
	if [ -z $MASTER_USER ]; then
		[ "${JENKINS_USER}" != "jenkins" ] && MASTER_USER=${JENKINS_USER} || MASTER_USER=`whoami`
		echo
		read -p "Account that ${SLAVE_NODE} connects to ${MASTER_NAME} as [${MASTER_USER}]: " RESPONSE
		MASTER_USER=${RESPONSE:-$MASTER_USER}
	fi
	echo
	echo "${MASTER_USER}'s API token is required to authenticate a JNLP slave."
	echo "The API token is listed at ${MASTER}/user/${MASTER_USER}/configure"
	read -p "API token for ${MASTER_USER}: " SLAVE_TOKEN
	while ! curl --url ${MASTER}/user/${MASTER_USER} --user ${MASTER_USER}:${SLAVE_TOKEN} --silent --head --fail --output /dev/null ; do
		echo "Unable to authenticate ${MASTER_USER} with this token"
		read -p "API token for ${MASTER_USER}: " SLAVE_TOKEN
	done
	if [ "$PROTOCOL" == "https" ]; then
		if java -jar ${TMPDIR}/$$.slave.jar -jnlpUrl ${MASTER}/computer/${SLAVE_NODE}/slave-agent.jnlp -jnlpCredentials ${MASTER_USER}:${SLAVE_TOKEN} 2>&1 | grep -q '\-noCertificateCheck' ; then
			if [[ -z $MASTER_CERT && -z $MASTER_CA ]]; then
				echo
				echo "The certificate for ${MASTER_NAME} is not trusted by java"
				read -p "Does ${MASTER_NAME} have a self-signed certificate? (yes/no) [yes]? " CONFIRM
				CONFIRM=${CONFIRM:-"yes"}
				if [[ "${CONFIRM}" =~ ^[Yy] ]] ; then
					true # until I figure out what to do here
				fi
			fi
		fi
		# TODO: test for MASTER_CERT
		# if not MASTER_CERT, ask if $MASTER_NAME uses self-signed cert
		# if "yes", ask for path to public key
		# if "no", ask if JAVA includes CA
	fi
}

function write_config {
	if [ -f ${JENKINS_CONF} ]; then
		sudo chmod 666 ${JENKINS_CONF}
	fi
	:> ${JENKINS_CONF}
	echo "JENKINS_SLAVE=${SLAVE_NODE}" >> ${JENKINS_CONF}
	echo "JENKINS_MASTER=${MASTER}" >> ${JENKINS_CONF}
	echo "JENKINS_PORT=${MASTER_PORT}" >> ${JENKINS_CONF}
	echo "JENKINS_USER=${MASTER_USER}" >> ${JENKINS_CONF}
	echo "JAVA_ARGS=${JAVA_ARGS}" >> ${JENKINS_CONF}
	sudo chown ${JENKINS_USER}:${JENKINS_USER} ${JENKINS_CONF}
	sudo chmod 400 ${JENKINS_CONF}
}
	
echo "
        _          _   _              _ _  _ _    ___   ___ _              
     _ | |___ _ _ | |_(_)_ _  ___  _ | | \| | |  | _ \ / __| |__ ___ _____ 
    | || / -_) ' \| / / | ' \(_-< | || | .\` | |__|  _/ \__ \ / _\` \ V / -_)
     \__/\___|_||_|_\_\_|_||_/__/  \__/|_|\_|____|_|   |___/_\__,_|\_/\___|

This script will download, install, and configure a Jenkins JNLP Slave on OS X.

You must be an administrator on the system you are installing the Slave on,
since this installer will add a user to the system and then configure the slave
as that user.

During the configuration, you will be prompted for nessessary information. The
suggested or default response will be in brackets [].
"
read -p "Continue (yes/no) [yes]? " CONFIRM

CONFIRM=${CONFIRM:-"yes"}
if [[ "${CONFIRM}" =~ ^[Yy] ]] ; then
	create_user
	process_args $@
	exit 0 # abort for now
	echo "Installing files..."
	install_files
	echo "Configuring daemon..."
	configure_daemon
	write_config
else
	echo
	exit 0
fi
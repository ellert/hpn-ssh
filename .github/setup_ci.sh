#!/bin/sh

PACKAGES=""

 . .github/configs $@

case "`./config.guess`" in
*cygwin)
	PACKAGER=setup
	echo Setting CYGWIN system environment variable.
	setx CYGWIN "binmode"
	echo Removing extended ACLs so umask works as expected.
	setfacl -b . regress
	PACKAGES="$PACKAGES,autoconf,automake,cygwin-devel,gcc-core"
	PACKAGES="$PACKAGES,make,openssl-devel,zlib-devel"
	;;
*-darwin*)
	PACKAGER=brew
	brew install automake
	exit 0
	;;
*)
	PACKAGER=apt
esac

TARGETS=$@

INSTALL_FIDO_PPA="no"
#COPY_PAM_MODULE="no"
export DEBIAN_FRONTEND=noninteractive

#echo "Setting up for '$TARGETS'"

set -ex

if [ -x "`which lsb_release 2>&1`" ]; then
	lsb_release -a
fi

# Ubuntu 22.04 defaults to private home dirs which prevent the
# agent-getpeerid test from running ssh-add as nobody.  See
# https://github.com/actions/runner-images/issues/6106
if [ ! -z "$SUDO" ] && ! "$SUDO" -u nobody test -x ~; then
	echo ~ is not executable by nobody, adding perms.
	chmod go+x ~
fi

if [ "${TARGETS}" = "kitchensink" ]; then
	TARGETS="krb5 libedit pam sk selinux"
fi

for flag in $CONFIGFLAGS; do
    case "$flag" in
    --with-pam)		TARGETS="${TARGETS} pam" ;;
    --with-libedit)	TARGETS="${TARGETS} libedit" ;;
    esac
done

for TARGET in $TARGETS; do
    case $TARGET in
    default|without-openssl|without-zlib|c89)
        # nothing to do
        ;;
    clang-sanitize*)
        PACKAGES="$PACKAGES clang-12"
        ;;
    cygwin-release)
        PACKAGES="$PACKAGES libcrypt-devel libfido2-devel libkrb5-devel"
        ;;
    gcc-sanitize*)
        ;;
    clang-*|gcc-*)
        compiler=$(echo $TARGET | sed 's/-Werror//')
        PACKAGES="$PACKAGES $compiler"
        ;;
    krb5)
        PACKAGES="$PACKAGES libkrb5-dev"
	;;
    heimdal)
        PACKAGES="$PACKAGES heimdal-dev"
        ;;
    libedit)
	case "$PACKAGER" in
	setup)	PACKAGES="$PACKAGES libedit-devel" ;;
	apt)	PACKAGES="$PACKAGES libedit-dev" ;;
	esac
        ;;
    *pam)
#	COPY_PAM_MODULE="yes"
        PACKAGES="$PACKAGES libpam0g-dev"
        ;;
    sk)
        INSTALL_FIDO_PPA="yes"
        PACKAGES="$PACKAGES libfido2-dev libu2f-host-dev libcbor-dev"
        ;;
    selinux)
        PACKAGES="$PACKAGES libselinux1-dev selinux-policy-dev"
        ;;
    hardenedmalloc)
        INSTALL_HARDENED_MALLOC=yes
        ;;
    musl)
	PACKAGES="$PACKAGES musl-tools"
	;;
    tcmalloc)
        PACKAGES="$PACKAGES libgoogle-perftools-dev"
        ;;
    openssl-noec)
	INSTALL_OPENSSL=OpenSSL_1_1_1k
	SSLCONFOPTS="no-ec"
	;;
    openssl-*)
        INSTALL_OPENSSL=$(echo ${TARGET} | cut -f2 -d-)
        case ${INSTALL_OPENSSL} in
          1.1.1_stable)	INSTALL_OPENSSL="OpenSSL_1_1_1-stable" ;;
          1.*)	INSTALL_OPENSSL="OpenSSL_$(echo ${INSTALL_OPENSSL} | tr . _)" ;;
          3.*)	INSTALL_OPENSSL="openssl-${INSTALL_OPENSSL}" ;;
        esac
        PACKAGES="${PACKAGES} putty-tools"
       ;;
    libressl-*)
        INSTALL_LIBRESSL=$(echo ${TARGET} | cut -f2 -d-)
        case ${INSTALL_LIBRESSL} in
          master) ;;
          *) INSTALL_LIBRESSL="$(echo ${TARGET} | cut -f2 -d-)" ;;
        esac
        PACKAGES="${PACKAGES} putty-tools"
       ;;
    valgrind*)
       PACKAGES="$PACKAGES valgrind"
       ;;
    *) echo "Invalid option '${TARGET}'"
        exit 1
        ;;
    esac
done

if [ "yes" = "$INSTALL_FIDO_PPA" ]; then
    sudo apt update -qq
    sudo apt install -qy software-properties-common
    sudo apt-add-repository -y ppa:yubico/stable
fi

#need to copy the pam modules for sshd to hpnsshd on
#macos with pam.
#if [ "yes" = "$COPY_PAM_MODULE" ]; then
#    if [ `uname` = "Darwin" }; then
#	sudo cp /etc/pam.d/sshd /etc/pam.d/hpnsshd
#    fi
#fi

tries=3
while [ ! -z "$PACKAGES" ] && [ "$tries" -gt "0" ]; do
    case "$PACKAGER" in
    apt)
	sudo apt update -qq
	if sudo apt install -qy $PACKAGES; then
		PACKAGES=""
	fi
	;;
    setup)
	if /cygdrive/c/setup.exe -q -P `echo "$PACKAGES" | tr ' ' ,`; then
		PACKAGES=""
	fi
	;;
    esac
    if [ ! -z "$PACKAGES" ]; then
	sleep 90
    fi
    tries=$(($tries - 1))
done
if [ ! -z "$PACKAGES" ]; then
	echo "Package installation failed."
	exit 1
fi

if [ "${INSTALL_HARDENED_MALLOC}" = "yes" ]; then
    (cd ${HOME} &&
     git clone https://github.com/GrapheneOS/hardened_malloc.git &&
     cd ${HOME}/hardened_malloc &&
     make -j2 && sudo cp out/libhardened_malloc.so /usr/lib/)
fi

if [ ! -z "${INSTALL_OPENSSL}" ]; then
    (cd ${HOME} &&
     git clone https://github.com/openssl/openssl.git &&
     cd ${HOME}/openssl &&
     git checkout ${INSTALL_OPENSSL} &&
     ./config no-threads shared ${SSLCONFOPTS} \
         --prefix=/opt/openssl &&
     make && sudo make install_sw)
fi

if [ ! -z "${INSTALL_LIBRESSL}" ]; then
    if [ "${INSTALL_LIBRESSL}" = "master" ]; then
        (mkdir -p ${HOME}/libressl && cd ${HOME}/libressl &&
         git clone https://github.com/libressl-portable/portable.git &&
         cd ${HOME}/libressl/portable &&
         git checkout ${INSTALL_LIBRESSL} &&
         sh update.sh && sh autogen.sh &&
         ./configure --prefix=/opt/libressl &&
         make -j2 && sudo make install)
    else
        LIBRESSL_URLBASE=https://cdn.openbsd.org/pub/OpenBSD/LibreSSL
        (cd ${HOME} &&
         wget ${LIBRESSL_URLBASE}/libressl-${INSTALL_LIBRESSL}.tar.gz &&
         tar xfz libressl-${INSTALL_LIBRESSL}.tar.gz &&
         cd libressl-${INSTALL_LIBRESSL} &&
         ./configure --prefix=/opt/libressl && make -j2 && sudo make install)
    fi
fi

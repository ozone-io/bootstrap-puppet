#!/bin/sh

# 	Copyright 2014 Werner Buck
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

set -e

#default variables
PUPPET_DEFAULT_INSTALL_SCRIPT="https://raw.githubusercontent.com/wernerb/puppet-install-shell/master/install_puppet.sh"
PUPPET_DEFAULT_HIERA_YAML=":backends:
  - json
:json:
  :datadir: /etc/puppet/hiera
:hierarchy:
  - common"

PUPPET_DEFAULT_HIERA_DATA_COMMON="{
	\"classes\": []
}"

PUPPET_DEFAULT_SITE_PP="hiera_include('classes')"

#set default variables
PUPPET_INSTALL_SCRIPT=${PUPPET_INSTALL_SCRIPT:-"$PUPPET_DEFAULT_INSTALL_SCRIPT"}
PUPPET_HIERA_YAML=${PUPPET_HIERA_YAML:-"$PUPPET_DEFAULT_HIERA_YAML"}
PUPPET_HIERA_DATA_COMMON=${PUPPET_HIERA_DATA_COMMON:-"$PUPPET_DEFAULT_HIERA_DATA_COMMON"}
PUPPET_SITE_PP=${PUPPET_SITE_PP:-"$PUPPET_DEFAULT_SITE_PP"}

# Set up colours
if tty -s;then
    RED=${RED:-$(tput setaf 1)}
    GREEN=${GREEN:-$(tput setaf 2)}
    YLW=${YLW:-$(tput setaf 3)}
    BLUE=${BLUE:-$(tput setaf 4)}
    RESET=${RESET:-$(tput sgr0)}
else
    RED=
    GREEN=
    YLW=
    BLUE=
    RESET=
fi

# Timestamp
now () {
    date +'%H:%M:%S %z'
}

# Logging functions instead of echo
log () {
    echo "${BLUE}`now`${RESET} ${1}"
}

info () {
    log "${GREEN}INFO${RESET}: ${1}"
}

warn () {
    log "${YLW}WARN${RESET}: ${1}"
}

critical () {
    log "${RED}CRIT${RESET}: ${1}"
}

# Check whether a command exists - returns 0 if it does, 1 if it does not
exists() {
  if command -v $1 >/dev/null 2>&1
  then
    return 0
  else
    return 1
  fi
}

# Retrieve Platform and Platform Version
if test -f "/etc/lsb-release" && grep -q DISTRIB_ID /etc/lsb-release; then
  platform=`grep DISTRIB_ID /etc/lsb-release | cut -d "=" -f 2 | tr '[A-Z]' '[a-z]'`
  platform_version=`grep DISTRIB_RELEASE /etc/lsb-release | cut -d "=" -f 2`
elif test -f "/etc/debian_version"; then
  platform="debian"
  platform_version=`cat /etc/debian_version`
elif test -f "/etc/redhat-release"; then
  platform=`sed 's/^\(.\+\) release.*/\1/' /etc/redhat-release | tr '[A-Z]' '[a-z]'`
  platform_version=`sed 's/^.\+ release \([.0-9]\+\).*/\1/' /etc/redhat-release`
elif test -f "/etc/system-release"; then
  platform=`sed 's/^\(.\+\) release.\+/\1/' /etc/system-release | tr '[A-Z]' '[a-z]'`
  platform_version=`sed 's/^.\+ release \([.0-9]\+\).*/\1/' /etc/system-release | tr '[A-Z]' '[a-z]'`
elif test -f "/etc/release"; then
  platform="solaris2"
  machine=`/usr/bin/uname -p`
  platform_version=`/usr/bin/uname -r`
elif test -f "/etc/SuSE-release"; then
  if grep -q 'Enterprise' /etc/SuSE-release;
  then
      platform="sles"
      platform_version=`awk '/^VERSION/ {V = $3}; /^PATCHLEVEL/ {P = $3}; END {print V "." P}' /etc/SuSE-release`
  else
      platform="suse"
      platform_version=`awk '/^VERSION =/ { print $3 }' /etc/SuSE-release`
  fi
elif test "x$os" = "xFreeBSD"; then
  platform="freebsd"
  platform_version=`uname -r | sed 's/-.*//'`
elif test "x$os" = "xAIX"; then
  platform="aix"
  platform_version=`uname -v`
  machine="ppc"
fi

# Mangle $platform_version to pull the correct build
# for various platforms
major_version=`echo $platform_version | cut -d. -f1`
case $platform in
  "el")
    platform_version=$major_version
    ;;
  "debian")
    case $major_version in
      "5") platform_version="6";;
      "6") platform_version="6";;
      "7") platform_version="6";;
    esac
    ;;
  "freebsd")
    platform_version=$major_version
    ;;
  "sles")
    platform_version=$major_version
    ;;
  "suse")
    platform_version=$major_version
    ;;
esac

if test "x$platform_version" = "x"; then
  critical "Unable to determine platform version!"
  report_bug
  exit 1
fi

if test "x$platform" = "xsolaris2"; then
  # hack up the path on Solaris to find wget
  PATH=/usr/sfw/bin:$PATH
  export PATH
fi

checksum_mismatch() {
  critical "Package checksum mismatch!"
  report_bug
  exit 1
}

if test "x$platform" = "x"; then
  critical "Unable to determine platform version!"
  report_bug
  exit 1
fi

if test "x$TMPDIR" = "x"; then
  tmp="/tmp"
else
  tmp=$TMPDIR
fi

# Random function since not all shells have $RANDOM
random () {
    hexdump -n 2 -e '/2 "%u"' /dev/urandom
}

# do_wget URL FILENAME
do_wget() {
  info "Trying wget..."
  wget -O "$2" "$1" 2>$tmp_stderr
  rc=$?

  # check for 404
  grep "ERROR 404" $tmp_stderr 2>&1 >/dev/null
  if test $? -eq 0; then
    critical "ERROR 404"
    unable_to_retrieve_package
  fi

  # check for bad return status or empty output
  if test $rc -ne 0 || test ! -s "$2"; then
    capture_tmp_stderr "wget"
    return 1
  fi

  return 0
}

# do_curl URL FILENAME
do_curl() {
  info "Trying curl..."
  curl -sL -D $tmp_stderr "$1" > "$2"
  rc=$?
  # check for 404
  grep "404 Not Found" $tmp_stderr 2>&1 >/dev/null
  if test $? -eq 0; then
    critical "ERROR 404"
    unable_to_retrieve_package
  fi

  # check for bad return status or empty output
  if test $rc -ne 0 || test ! -s "$2"; then
    capture_tmp_stderr "curl"
    return 1
  fi

  return 0
}

# do_fetch URL FILENAME
do_fetch() {
  info "Trying fetch..."
  fetch -o "$2" "$1" 2>$tmp_stderr
  # check for bad return status
  test $? -ne 0 && return 1
  return 0
}

# do_perl URL FILENAME
do_perl() {
  info "Trying perl..."
  perl -e 'use LWP::Simple; getprint($ARGV[0]);' "$1" > "$2" 2>$tmp_stderr
  rc=$?
  # check for 404
  grep "404 Not Found" $tmp_stderr 2>&1 >/dev/null
  if test $? -eq 0; then
    critical "ERROR 404"
    unable_to_retrieve_package
  fi

  # check for bad return status or empty output
  if test $rc -ne 0 || test ! -s "$2"; then
    capture_tmp_stderr "perl"
    return 1
  fi

  return 0
}

# do_python URL FILENAME
do_python() {
  info "Trying python..."
  python -c "import sys,urllib2 ; sys.stdout.write(urllib2.urlopen(sys.argv[1]).read())" "$1" > "$2" 2>$tmp_stderr
  rc=$?
  # check for 404
  grep "HTTP Error 404" $tmp_stderr 2>&1 >/dev/null
  if test $? -eq 0; then
    critical "ERROR 404"
    unable_to_retrieve_package
  fi

  # check for bad return status or empty output
  if test $rc -ne 0 || test ! -s "$2"; then
    capture_tmp_stderr "python"
    return 1
  fi
  return 0
}

do_checksum() {
  if exists sha256sum; then
    checksum=`sha256sum $1 | awk '{ print $1 }'`
    if test "x$checksum" != "x$2"; then
      checksum_mismatch
    else
      info "Checksum compare with sha256sum succeeded."
    fi
  elif exists shasum; then
    checksum=`shasum -a 256 $1 | awk '{ print $1 }'`
    if test "x$checksum" != "x$2"; then
      checksum_mismatch
    else
      info "Checksum compare with shasum succeeded."
    fi
  elif exists md5sum; then
    checksum=`md5sum $1 | awk '{ print $1 }'`
    if test "x$checksum" != "x$3"; then
      checksum_mismatch
    else
      info "Checksum compare with md5sum succeeded."
    fi
  elif exists md5; then
    checksum=`md5 $1 | awk '{ print $4 }'`
    if test "x$checksum" != "x$3"; then
      checksum_mismatch
    else
      info "Checksum compare with md5 succeeded."
    fi
  else
    warn "Could not find a valid checksum program, pre-install shasum, md5sum or md5 in your O/S image to get valdation..."
  fi
}

checksum_mismatch() {
  critical "checksum mismatch!"
  report_bug
  exit 1
}

# do_download URL FILENAME
do_download() {
  info "Downloading $1"
  info "  to file $2"

  # we try all of these until we get success.
  # perl, in particular may be present but LWP::Simple may not be installed

  if exists wget; then
    do_wget $1 $2 && return 0
  fi

  if exists curl; then
    do_curl $1 $2 && return 0
  fi

  if exists fetch; then
    do_fetch $1 $2 && return 0
  fi

  if exists perl; then
    do_perl $1 $2 && return 0
  fi

  if exists python; then
    do_python $1 $2 && return 0
  fi

  critical "Could not download file. No download methods available."
}

# Helper bug-reporting text
report_bug() {
  critical "Please file a bug report at https://github.com/ozone-io/bootstrap-puppet"
  critical ""
  critical "Version: $version"
  critical "Platform: $platform"
  critical "Platform Version: $platform_version"
  critical "Machine: $machine"
  critical "OS: $os"
  critical ""
  critical "Please detail your operating system type, version and any other relevant details"
}


#set temp stuff
tmp_dir="$tmp/install.sh.$$.`random`"
(umask 077 && mkdir $tmp_dir) || exit 1

tmp_stderr="$tmp/stderr.$$.`random`"

capture_tmp_stderr() {
  # spool up tmp_stderr from all the commands we called
  if test -f $tmp_stderr; then
    output=`cat ${tmp_stderr}`
    stderr_results="${stderr_results}\nSTDERR from $1:\n\n$output\n"
  fi
}

trap "rm -f $tmp_stderr; rm -rf $tmp_dir; exit $1" 1 2 15

#start main script logic

info "-- start script $0"
info "-- detected os details:"
info ""
info "Version: $version"
info "Platform: $platform"
info "Platform Version: $platform_version"
info "Machine: $machine"
info "OS: $os"
info ""

info "-- download puppet install script to $tmpdir/puppet-install.sh"
do_download "$PUPPET_INSTALL_SCRIPT" "$tmp_dir/puppet-install.sh" 
info "-- run puppet install script sh $tmp_dir/puppet-install.sh"
sh "$tmp_dir/puppet-install.sh"
info "-- finished puppet install script"
info "-- checking if puppet forge modules need to be installed."
if [ ! "x$PUPPET_FORGE_MODULES" = "x" ]; then
	info "-- puppet forge modules found"
	#delete all modules if present. puppet module install cannot replace modules automatically without forgetting dependencies
	warn "-- removing all modules in /etc/puppet/modules/"
	rm -rf /etc/puppet/modules/*
	OLDIFS=$IFS
	IFS='
	'
	for p in $PUPPET_FORGE_MODULES; do
	    info "---- downloading and installing puppet forge module $p"
	    puppet module install "$p"
	done
	IFS=$OLDIFS
	info "-- finished installation puppet modules"
else 
	warn "-- no puppet forge modules defined"
fi

info "-- checking if tarred modules need to be installed."
if [ ! "x$PUPPET_MODULES" = "x" ]; then
	info "-- tarred modules found"
	OLDIFS=$IFS
	IFS='
	'
	for p in $PUPPET_MODULES; do
		folder=$(echo "$p" | cut -d ';' -f1)
		url=$(echo "$p" | cut -d ';' -f2)
		tarfolder=$(echo "$p" | cut -d ';' -f3)
		if [ ! "x$folder" = "x" ] && [ ! "x$url" = "x" ]; then
			mkdir -p "$tmp_dir/$folder"
	    	info "---- downloading and installing puppet module $folder at $url on path $tarfolder"
	    	do_download "$url" "$tmp_dir/$folder.tar.gz"
	    	info "---- deleting old module if it exists"
	    	rm -rf "/etc/puppet/modules/$folder"
	    	info "---- untarring archive $tmp_dir/$folder.tar.gz to $tmp_dir/$folder"
	    	tar -zxf "$tmp_dir/$folder.tar.gz" -C "$tmp_dir/$folder"
	    	info "---- moving $tmp_dir/$folder""$tarfolder to /etc/puppet/modules/$folder"
	    	mv -f "$tmp_dir/$folder""$tarfolder" "/etc/puppet/modules/$folder"
		else 
			warn "---- $p has been incorrectly passed. skipping"
		fi
	done
	IFS=$OLDIFS
else 
	warn "-- no tarred modules defined"
fi

info "-- filling puppet data in /etc/hiera.yaml /etc/puppet/hiera/common.csv and /etc/puppet/manifests/site.pp"
echo "$PUPPET_HIERA_YAML" > /etc/hiera.yaml
ln -f -s /etc/hiera.yaml /etc/puppet/hiera.yaml
mkdir -p /etc/puppet/hiera
echo "$PUPPET_HIERA_DATA_COMMON" > /etc/puppet/hiera/common.json
mkdir -p /etc/puppet/manifests
echo "$PUPPET_SITE_PP" > /etc/puppet/manifests/site.pp

info "-- run puppet apply --verbose --modulepath=/etc/puppet/modules /etc/puppet/manifests/site.pp"
puppet apply --verbose --modulepath=/etc/puppet/modules /etc/puppet/manifests/site.pp
info "-- finished puppet apply run"

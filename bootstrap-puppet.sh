#!/bin/sh

#   Copyright 2014 Werner Buck
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


###########################################################################################
#
# Ozone.io's provisioner for puppet masterless
#
# Features:
# * Installs puppet, downloads puppet modules, runs puppet solo. Each stage can be run individually.
# * Easily configurable due to the use of environment variables. * See test
# * Runs on every unix distro BSD/Unix alike due to POSIX and /bin/sh compatibility. 
#     A lot of distro's have been tested using vagrant. (See Vagrantfile)
#
# Credit:
# * Helper functions are from Chef Omnitruck installer at opscode!
# 
############################################################################################

#drop out at every error. //TODO: Use trap
set -e

#default options
PUPPET_DEFAULT_ALWAYS_INSTALL_PUPPET="false"
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
PUPPET_INSTALL_SCRIPT_ARGS=${PUPPET_INSTALL_SCRIPT_ARGS:-$PUPPET_DEFAULT_INSTALL_SCRIPT_ARGS}
PUPPET_ALWAYS_INSTALL_PUPPET=${PUPPET_ALWAYS_INSTALL_PUPPET:-$PUPPET_DEFAULT_ALWAYS_INSTALL_PUPPET}
PUPPET_INSTALL_SCRIPT=${PUPPET_INSTALL_SCRIPT:-"$PUPPET_DEFAULT_INSTALL_SCRIPT"}
PUPPET_HIERA_YAML=${PUPPET_HIERA_YAML:-"$PUPPET_DEFAULT_HIERA_YAML"}
PUPPET_HIERA_DATA_COMMON=${PUPPET_HIERA_DATA_COMMON:-"$PUPPET_DEFAULT_HIERA_DATA_COMMON"}
PUPPET_SITE_PP=${PUPPET_SITE_PP:-"$PUPPET_DEFAULT_SITE_PP"}

###########################################################################################
# helper functions. Skip to end.
###########################################################################################

# Timestamp
now () {
    date +'%H:%M:%S %z'
}

# Logging functions instead of echo
log () {
    echo "`now` ${1}"
}

info () {
    log "INFO: ${1}"
}

warn () {
    log "WARN$: ${1}"
}

critical () {
    log "CRIT: ${1}"
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
  curl -1 -sL -D $tmp_stderr "$1" > "$2"
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

###########################################################################################
# Start of main logic
###########################################################################################

#############
# Install Stage: Installs puppet
# * Is a bootstrapping stage: Only installs essentials, does not configure.
#############
install_stage() {
  info "-- start install stage"

  info "-- installling puppet"
  if [ "x$PUPPET_ALWAYS_INSTALL_PUPPET" = "xtrue" ] || ! puppet --version >/dev/null 2>&1; then
    info "-- pppet not detected or installation is forced"
    info "-- download puppet install script to $tmp_dir/puppet-install.sh"
    do_download "$PUPPET_INSTALL_SCRIPT" "$tmp_dir/puppet-install.sh" 
    info "-- run puppet install script sh $tmp_dir/puppet-install.sh $PUPPET_INSTALL_SCRIPT_ARGS"
    sh "$tmp_dir/puppet-install.sh" "$PUPPET_INSTALL_SCRIPT_ARGS"
    info "-- finished puppet install script"
  else 
    info "-- puppet found. skipping puppet installation"
  fi

  info "-- finished install stage"
}


#############
# Configure Stage: Downloads Puppet Forge/Tar modules, installs them. Also (re)sets configuration files.
#############

configure_stage() {
  info "-- start configure stage"

  info "-- writing file /etc/hiera.yaml"
  echo "$PUPPET_HIERA_YAML" > /etc/hiera.yaml
  info "-- finished writing to /etc/hiera.yaml"

  info "-- creating symbolic link from /etc/hiera.yaml to /etc/puppet/hiera.yaml"
  ln -f -s /etc/hiera.yaml /etc/puppet/hiera.yaml
  info "-- finished symbolic link creation /etc/hiera.yaml"

  info "-- writing file /etc/puppet/hiera/common.json"
  mkdir -p /etc/puppet/hiera
  echo "$PUPPET_HIERA_DATA_COMMON" > /etc/puppet/hiera/common.json
  info "-- finished writing to /etc/puppet/hiera/common.json"

  info "-- writing file /etc/puppet/manifests/site.pp"
  mkdir -p /etc/puppet/manifests
  echo "$PUPPET_SITE_PP" > /etc/puppet/manifests/site.pp
  info "-- finished writing to /etc/puppet/hiera/site.pp"
  
  #Download/replace puppet forge modules
  info "-- checking if puppet forge module(s) need to be downloaded and installed."
  if ! test "x$PUPPET_FORGE_MODULES" = "x"; then
    info "-- puppet forge module(s) found"
    #Delete all modules if present. 
    #Puppet module install cannot replace modules automatically without forgetting dependencies.
    warn "-- removing all modules in /etc/puppet/modules/"
    rm -rf /etc/puppet/modules/*
    OLDIFS=$IFS
    IFS='
'
    for p in $PUPPET_FORGE_MODULES; do
        info "---- downloading and installing puppet forge module $p"
        puppet module install "$p"
        info "---- installed puppet forge module $p"
    done
    IFS=$OLDIFS
    info "-- finished installation puppet module(s)"
  else 
    warn "-- no puppet forge modules. not downloading."
  fi

  #Download/replcace puppet tarred modules
  #Format is "namemodule;https://whatever/urlofmodule.tar.gz;pathintartomodule"
  #pathintartomodule is optional.
  info "-- checking if puppet tarred modules need to be downloaded and installed."
  if ! test "x$PUPPET_MODULES" = "x"; then
    info "-- tarred modules found"
    OLDIFS=$IFS
    IFS='
'
    for p in $PUPPET_MODULES; do
      modulefolder=$(echo "$p" | cut -d ';' -f1)
      moduleurl=$(echo "$p" | cut -d ';' -f2)
      moduletarfolder=$(echo "$p" | cut -d ';' -f3)
      if [ ! "x$modulefolder" = "x" ] && [ ! "x$moduleurl" = "x" ]; then
        mkdir -p "$tmp_dir/$modulefolder"
        info "---- downloading and installing puppet module $modulefolder at $moduleurl on path $moduletarfolder"
        do_download "$moduleurl" "$tmp_dir/$modulefolder.tar.gz"
        info "---- deleting old module if it exists"
        rm -rf "/etc/puppet/modules/$modulefolder"
        info "---- untarring archive $tmp_dir/$modulefolder.tar.gz to $tmp_dir/$modulefolder"
        tar -zxf "$tmp_dir/$modulefolder.tar.gz" -C "$tmp_dir/$modulefolder"
        info "---- moving $tmp_dir/$modulefolder""$moduletarfolder to /etc/puppet/modules/$modulefolder"
        mv -f "$tmp_dir/$modulefolder""$moduletarfolder" "/etc/puppet/modules/$modulefolder"
      else 
        critical "---- $p has been incorrectly passed."
      fi
    done
    IFS=$OLDIFS
  else 
    warn "-- no tarred modules provided. not installing modules."
  fi

  info "-- finished configure stage"
}

#############
# Run Stage: Executes puppet apply.
#############
run_stage() {  
  info "-- start run stage"

  info "-- run puppet apply --modulepath=/etc/puppet/modules /etc/puppet/manifests/site.pp"
  puppet apply --modulepath=/etc/puppet/modules /etc/puppet/manifests/site.pp
  info "-- finished puppet apply run"
  
  info "-- finished run stage"
}

############
# Pick your stages: If you supply an argument with install, configure or run, you can run each stage individually. 
############

case "$1" in
    "install")
      install_stage
    ;;
    "configure")
      configure_stage
    ;;
    "run")
      run_stage
    ;;
    *)
      install_stage
      configure_stage
      run_stage
    ;;
esac

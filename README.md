bootstrap-puppet
==============

A script that installs, configures and runs puppet apply, that works on all recent unix distributions. (Except Arch Linux and Freebsd)

### Prerequisites
* Internet Access
* A Vanilla distribution: Do not have puppet pre-installed by a third party.

## Purpose:
This script as well as its cousin [bootstrap-chef](https://github.com/ozone-io/bootstrap-chef) and its future cousins are part of the [ozone.io](http://ozone.io) project that aims to abstract various cloud providers and configuration management tools in a simple understandable manner to test and deploy large clusters.

Underlying principles:

* Any state introduced except by your configuration management tool "taints" the image, as your actions will be not be reproducable by your co-workers or those that will inherit your work.
* Do not use snapshots or cloning of your machines when launch-time is not important. Rather re-deploy the same base-image and provision it from beginning to end. This will make sure the state of your cluster is always reproducable.
* Reap the benefits of using vanilla cloud images by experimenting with various operating system versions. Upgrading a distribution will never be easier than this and at most involve you to change your configuation management parameters accordingly, which is what the cm-tool is expected of.

## How to use:
Default with no environment variables, only puppet is installed and nothing is done.

When you wish to add modules/configuration, you set the following environment variables:

* PUPPET_FORGE_MODULES: Optional. Each newline reflects a puppet module name that can be looked up at the [puppet forge](https://forge.puppetlabs.com/)
* PUPPET_MODULES: Optional. Each newline reflects: 1. `name of module`, 2. `url to the module`, 3. `the path to the module content when untarred`. These options are delimited by `;`
* PUPPET_HIERA_DATA_COMMON: This sets the classes and configuration through hiera to be used with your modules.

--------------
For example, for installing modules nginx,ntp through puppet forge, and mysql through github and configure only nginx and ntp:

    #set multiline variable PUPPET_FORGE_MODULES
    cat > "$OUT" << EOF
    puppetlabs-ntp
    jfryman-nginx
    EOF
    export PUPPET_FORGE_MODULES="$(cat "$OUT")"
    #end multiline variable PUPPET_FORGE_MODULES
    
    #set multiline variable PUPPET_MODULES
    cat > "$OUT" << EOF
    mysql;https://github.com/puppetlabs/puppetlabs-mysql/archive/master.tar.gz;/puppetlabs-mysql-master
    EOF
    export PUPPET_MODULES="$(cat "$OUT")"
    #end multiline variable PUPPET_MODULES
    
    #set multiline variable PUPPET_HIERA_DATA_COMMON
    cat > "$OUT" << EOF
    {
        "classes": [
    		"nginx",
    		"ntp"
    	],
    	"ntp::package_ensure": "latest",
    	"ntp::service_enable": true,
    	"ntp::service_manage": true,
    	"ntp::servers": [
    		"0.us.pool.ntp.org iburst",
    		"1.us.pool.ntp.org iburst"
    	]
    }
    EOF
    export PUPPET_HIERA_DATA_COMMON="$(cat "$OUT")"
    #end multiline variable PUPPET_HIERA_DATA_COMMON


### Test:

The test folder contains settings that will install and configure ntp, nginx and mysql.

Examine the Vagrantfile for the distro you would like to test. Then for i.e. fedora20, excute the following:

    vagrant up fedora20

Vagrant will automatically execute the test script and install puppet, download modules if set and will run puppet apply.

* Requires vagrant 1.5+ (uses the Vagrantcloud for boxes)

### OS supported:

Tested on the following using vagrant but should support more in the future. (Or already does)

* _Ubuntu_: 12.04, 12.10, 13.04, 13.10
* _CentOS_: 5.8, 5.10, 6.5
* _Debian_: 6.0.8 (Squeeze), 7.4 (Wheezy)
* _fedora_: 19,20

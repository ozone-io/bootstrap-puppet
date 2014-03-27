#/bin/sh
#temp file for reading constants
OUT="$(mktemp)"

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

/vagrant/bootstrap-puppet.sh


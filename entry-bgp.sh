#!/bin/sh

set -e

term() {
	echo "Terminating..."
	exit 0
}

die() {
	echo "$@"
	exit 1
}

set_defaults() {
	export BGP_LOCAL_AS=${BGP_LOCAL_AS:-65000}
}

validate_input() {
	[ -z "$BGP_LOCAL_AS" ] && die "BGP_LOCAL_AS not set."
	[ -z "$BGP_ROUTER_ID" ] && die "BGP_ROUTER_ID not set."
	true
}

create_config_part1() {
	cat << EOF
[global.config]
	as = $BGP_LOCAL_AS
	router-id = "$BGP_ROUTER_ID"
EOF

	if [ -n "$BGP_MAX_PATH" ]; then
		if [ -z "$BGP_POLICY_DOCUMENT" ]; then
			cat << EOF
[global.apply-policy.config]
	default-import-policy = "reject-route"
	import-policy-list = ["policy_max_path"]
[[policy-definitions]]
	name = "policy_max_path"
	[[policy-definitions.statements]]
		name = "statement1"
		[policy-definitions.statements.conditions.bgp-conditions.as-path-length]
		operator = "le"
		value = $BGP_MAX_PATH
	[policy-definitions.statements.actions]
		route-disposition = "accept-route"
EOF
		else
			# BGP_MAX_PATH used together with BGP_POLICY_DOCUMENT
			# --> not supported
			echo "# not using \$BGP_MAX_PATH (BGP_POLICY_DOCUMENT used.)"
		fi
	fi


	# "simple" neighbor specification
	if [ -n "$BGP_NEIGHBORS" ]; then
		IFS=,
		for neighbor in $BGP_NEIGHBORS; do
			as=${neighbor%%@*}
			peer=${neighbor##*@}
			cat << EOF
[[neighbors]]
  [neighbors.config]
    neighbor-address = "${peer}"
    peer-as = ${as}
EOF
			if [ -n "$BGP_AUTHPASSWORD" ]; then
				printf "auth-password = \"${BGP_AUTHPASSWORD}\"\n"
			fi
		done
		unset IFS
	fi

	# per neighbor configuration
	if [ -n "$BGP_NEIGHBOR_COUNT" ]; then
		printf "\n# $BGP_NEIGHBOR_COUNT (additional) neighbor(s):\n"
		idx=-1
		while [ $(( ++idx )) -lt "$BGP_NEIGHBOR_COUNT" ]; do
			printf "# BGP_NEIGHBOR_$idx:\n"
			vn_as="BGP_NEIGHBOR_${idx}_PEERAS"
			vn_address="BGP_NEIGHBOR_${idx}_ADDRESS"
			vn_authpassword="BGP_NEIGHBOR_${idx}_AUTHPASSWORD"
			vn_local_as="BGP_NEIGHBOR_${idx}_LOCAL_AS"
			vn_remove_private_as="BGP_NEIGHBOR_${idx}_REMOVE_PRIVATE_AS"
			vn_timer_connect_retry="BGP_NEIGHBOR_${idx}_TIMER_CONNECT_RETRY"
			vn_timer_hold="BGP_NEIGHBOR_${idx}_TIMER_HOLD"
			vn_timer_keepalive="BGP_NEIGHBOR_${idx}_TIMER_KEEPALIVE"
			cat << EOF
[[neighbors]]
  [neighbors.config]
    neighbor-address = "${!vn_address}"
    peer-as = ${!vn_as}
EOF
			if [ -n "${!vn_local_as}" ]; then
				printf "    local-as = ${!vn_local_as}\n"
			fi
			if [ -n "${!vn_authpassword}" ]; then
				printf "    auth-password = \"${!vn_authpassword}\"\n"
			fi
			if [ -n "${!vn_remove_private_as}" ]; then
				if [ "${!vn_remove_private_as}" = all -o "${!vn_remove_private_as}" = replace -o "${!vn_remove_private_as}" = none ]; then
					printf "    remove-private-as = \"${!vn_remove_private_as}\"\n"
				else
					printf "# Invalid BGP_NEIGHBOR_${idx}_REMOVE_PRIVATE_AS=${!vn_remove_private_as} ignored.\n"
				fi
			fi
			if [ -n "${!vn_timer_connect_retry}${!vn_timer_hold}${!vn_timer_keepalive}" ]; then
				printf "  [neighbors.timers.config]\n"
			if [ -n "${!vn_timer_connect_retry}" ]; then
				printf "    connect-retry = ${!vn_timer_connect_retry}\n"
			fi
			if [ -n "${!vn_timer_hold}" ]; then
				printf "    hold-time = ${!vn_timer_hold}\n"
			fi
			if [ -n "${!vn_timer_keepalive}" ]; then
				printf "    keepalive-interval = ${!vn_timer_keepalive}\n"
			fi

			fi
			printf "\n\n"
		done
	fi

	if [ -n "$BGP_IPV6" -o "$BGP_IPV6" = yes ]; then
	    cat << EOF
  [[neighbors.afi-safis]]
    [neighbors.afi-safis.config]
      afi-safi-name = "ipv4-unicast"
  [[neighbors.afi-safis]]
    [neighbors.afi-safis.config]
      afi-safi-name = "ipv6-unicast"
EOF
	fi

	if [ -n "$BGP_FIB_MANIPULATION" ]; then
		cat << EOF
[zebra]
  [zebra.config]
    enabled = true
    #url = "tcp:127.0.0.1:2601"
    url = "unix:/run/quagga/zserv.api"
    version = 3
EOF
		if [ -n "$BGP_FIB_ANNOUNCE" ]; then
			echo '    redistribute-route-type-list = ["connect"]'
		else
			echo '    redistribute-route-type-list = []'
		fi
	fi

	if [ -n "$BGP_POLICY_DOCUMENT" ]; then
		echo "# included policy document from: $BGP_POLICY_DOCUMENT"
		cat $BGP_POLICY_DOCUMENT
	fi

	true
}

create_zebra_config() {
	cat << EOF
hostname zebra
password zebra
enable password zebra
line vty
log stdout debugging
EOF
	if [ -z "$BGP_IPV6" -o "$BGP_IPV6" = no ]; then
	    echo "no ipv6 forwarding"
	fi

	true
}

run_bgpd() {
	echo "Applying defaults..."
	set_defaults
	echo "Validating input..."
	validate_input
	echo "Creating configuration..."
	create_config_part1 > /run/bgpd-config.toml
	printf ">>> bgpd configuration >>>>>>>>>>>>>>>>>\n"
	cat /run/bgpd-config.toml
	printf "<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<\n\n"

	if [ -n "$BGP_FIB_MANIPULATION" ]; then
		printf ">>> zebra configuration >>>>>>>>>>>>>>>>>\n"
		create_zebra_config |tee /run/zebra.conf
		printf "<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<\n\n"
		echo "Starting fib manipulator..."
		/usr/sbin/zebra --config_file /run/zebra.conf &
		sleep 3
		printf "Done.\n\n"
	fi

	# start a background process to inject routes after gobgpd started
	if [ -n "$BGP_STATIC_ROUTES" ]; then
		echo "Going to inject to rib: $BGP_STATIC_ROUTES"
		nohup env routes="$BGP_STATIC_ROUTES" \
			bash -c "IFS=, ; \
			sleep 1 ; \
			for r in \$routes; do \
				/usr/bin/gobgp global rib add -a ipv4 \$r origin egp ; \
			done" > /dev/null 2>&1 &
	fi

	echo "executing bgp daemon..."
	/usr/bin/gobgpd -f /run/bgpd-config.toml &
	sleep 3
	trap term TERM
	while true; do
		# Poor man's supervisor.
		if [ -n "$BGP_FIB_MANIPULATION" ]; then
			if ! pidof zebra > /dev/null; then
				echo "Zebra died. Terminating."
				exit 1
			fi
		fi
		if ! pidof gobgpd > /dev/null; then
			echo "Gobgpd died. Terminating."
			exit 1
		fi
		sleep 1
	done
}

announce() {
	prefix="$1" ; shift
	if [ -z "$prefix" ]; then
		echo "announce requires a prefix provided on the command line."
		return
	fi
	/usr/bin/gobgp global rib add -a ipv4 "$prefix" origin egp
	sleep 1
	/usr/bin/gobgp global rib
	echo "announce done."
}

command="$1"

[ -n "$ENVFILE" ] && . "$ENVFILE"

if [ -z "$command" ]; then
	run_bgpd
	exit 0
fi
shift # command

if [ "$command" = announce ]; then
	announce "$@"
fi

#!/bin/bash

# This script is intended to optimally configure TRex and launch it in
# a screen session for the user.

tmp_dir="/tmp"
trex_dir="/opt/trex/current"
use_ht="n"
use_l2="n"
use_vlan="n"
devices=""
yaml_file=""

opts=$(getopt -q -o c: --longoptions "tmp-dir:,trex-dir:,use-ht:,use-l2:,use-vlan:,devices:,yaml-file:" -n "getopt.sh" -- "$@")
if [ $? -ne 0 ]; then
    printf -- "$*\n"
    printf -- "\n"
    printf -- "\tThe following options are available:\n\n"
    printf -- "\n"
    printf -- "--tmp-dir=str\n"
    printf -- "  Directory where temporary files should be stored.\n"
    printf -- "  Default is ${tmp_dir}\n"
    printf -- "\n"
    printf -- "--trex-dir=str\n"
    printf -- "  Directory where TRex is installed.\n"
    printf -- "  Default is ${trex_dir}\n"
    printf -- "\n"
    printf -- "--use-ht=<y|n>\n"
    printf -- "  Should TRex use HT CPUs.\n"
    printf -- "  Default is ${use_ht}\n"
    printf -- "\n"
    printf -- "--use-l2=<y|n>\n"
    printf -- "  Should TRex use L2 instead of L3 configuration.\n"
    printf -- "  Default is ${use_l2}\n"
    printf -- "\n"
    printf -- "--use-vlan=<y|n>\n"
    printf -- "  Should TRex use vlan tag or not.\n"
    printf -- "  Default is ${use_vlan}\n"
    printf -- "\n"
    printf -- "--devices=str\n"
    printf -- "  Comma separated list of PCI devices to use.  Should already be bound to vfio-pci.\n"
    printf -- "  There is no default\n"
    printf -- "\n"
    printf -- "--yaml-file=str\n"
    printf -- "  Optional parameter to specify a manually created TRex YAML file.\n"
    printf -- "  There is no default\n"
    exit 1
fi
eval set -- "$opts"
while true; do
    case "${1}" in
	--tmp-dir)
	    shift
	    if [ -n "${1}" ]; then
		tmp_dir=${1}
		shift
	    fi
	    ;;
	--trex-dir)
	    shift
	    if [ -n "${1}" ]; then
		trex_dir=${1}
		shift
	    fi
	    ;;
	--use-ht)
	    shift
	    if [ -n "${1}" ]; then
		use_ht=${1}
		shift
	    fi
	    ;;
	--use-l2)
	    shift
	    if [ -n "${1}" ]; then
		use_l2=${1}
		shift
	    fi
	    ;;
        --use-vlan)
            shift
            if [ -n "${1}" ]; then
                use_vlan=${1}
                shift
            fi
            ;;
	--devices)
	    shift
	    if [ -n "${1}" ]; then
		devices=${1}
		shift
	    fi
	    ;;
	--yaml-file)
	    shift
	    if [ -n "${1}" ]; then
		yaml_file=${1}
		shift
		if [ ! -e "${yaml_file}" ]; then
		    echo "ERROR: The YAML file you specified (${yaml_file}) does not exist/could not be located"
		    exit 1
		fi
	    fi
	    ;;
	--)
	    break
	    ;;
	*)
	    if [ -n "${1}" ]; then
		echo "ERROR: Unrecognized option ${1}"
	    fi
	    exit 1
	    ;;
    esac
done

if [ -z "${devices}" -a -z "${yaml_file}" ]; then
    echo "ERROR: You must specify a list of devices OR supply a YAML file"
    exit 1
fi

# start the trex server                                                                                                                                                                                                
echo "starting TRex server"

function convert_number_range() {
    # converts a range of cpus, like "1-3,5" to a list, like "1,2,3,5"                                                                                                                                                                    
    local cpu_range=$1
    local cpus_list=""
    local cpus=""
    for cpus in `echo "${cpu_range}" | sed -e 's/,/ /g'`; do
        if echo "${cpus}" | grep -q -- "-"; then
            cpus=`echo ${cpus} | sed -e 's/-/ /'`
            cpus=`seq ${cpus} | sed -e 's/ /,/g'`
        fi
        for cpu in ${cpus}; do
            cpus_list="${cpus_list},${cpu}"
        done
    done
    cpus_list=`echo ${cpus_list} | sed -e 's/^,//'`
    echo "${cpus_list}"
}

if [ -d ${trex_dir} -a -d ${tmp_dir} ]; then
    pushd ${trex_dir} 2>/dev/null

    if [ -z "${yaml_file}" ]; then
	/bin/rm -f ${tmp_dir}/trex_cfg.yaml

	isolated_cpus=$(cat /sys/devices/system/cpu/nohz_full)
	cpu_list=$(convert_number_range "${isolated_cpus}" | sed -e "s/,/ /g")
	trex_config_args=""
	if [ "${use_ht}" == "n" ]; then
            trex_config_args+="--no-ht "
	fi
	if [ "${use_l2}" == "y" ]; then
            trex_config_args+="--force-macs "

            if [ -e /etc/trex_cfg.yaml -a ! -e /etc/trex_cfg.yaml.launch-trex-backup ]; then
		mv -v /etc/trex_cfg.yaml /etc/trex_cfg.yaml.launch-trex-backup
            fi

            # generate a temporary yaml which is required for MAC discovery
            echo "- version       : 2" >/etc/trex_cfg.yaml
            yaml_devices=$(echo ${devices} | sed -e "s/^/\"/" -e "s/,/\",\"/g" -e "s/$/\"/")
            echo "  interfaces    : [${yaml_devices}]" >>/etc/trex_cfg.yaml
            echo "  port_limit    : 2" >>/etc/trex_cfg.yaml
	else
            # in case we didn't clean up after ourselves previously...
            if [ -e /etc/trex_cfg.yaml.launch-trx-backup ]; then
		mv -v /etc/trex_cfg.yaml.launch-trex-backup /etc/trex_cfg.yaml
            fi
	fi

	yaml_file="${tmp_dir}/trex_cfg.yaml"

	trex_config_cmd="./dpdk_setup_ports.py -c `echo ${devices} | sed -e s/,/" "/g` --cores-include ${cpu_list} -o ${yaml_file} ${trex_config_args}"
	echo "configuring trex with: ${trex_config_cmd}"
	${trex_config_cmd}
    fi

    trex_cpus=14
    for cpu_block in $(cat ${yaml_file} | grep threads | sed -e "s/\s//g" -e "s/threads://"); do
        yaml_cpus=$(echo "${cpu_block}" | sed -e 's/.*\[\(.*\)\]/\1/' -e 's/,/ /g' | wc -w)
        if [ ${yaml_cpus} -lt ${trex_cpus} ]; then
	    trex_cpus=${yaml_cpus}
        fi
    done

    if [ ${use_vlan} == "y" ]; then
        vlan_opt="--vlan"
    else
        vlan_opt=""
    fi
    trex_server_cmd="./t-rex-64 -i -c ${trex_cpus} --checksum-offload --cfg ${yaml_file} --iom 0 -v 4 ${vlan_opt}"
    echo "about to run: ${trex_server_cmd}"
    echo "trex yaml:"
    echo "-------------------------------------------------------------------"
    cat ${yaml_file}
    echo "-------------------------------------------------------------------"
    rm -fv /tmp/trex.server.out
    screen -dmS trex -t server ${trex_server_cmd}
    screen -x trex -X chdir /tmp
    screen -x trex -p server -X logfile trex.server.out
    screen -x trex -p server -X logtstamp on
    screen -x trex -p server -X log on

    # wait for trex server to be ready                                                                                                                                                                                                    
    count=30
    num_ports=0
    while [ ${count} -gt 0 -a ${num_ports} -lt 2 ]; do
        sleep 1
        num_ports=`netstat -tln | grep -E :4500\|:4501 | wc -l`
        ((count--))
    done
    if [ ${num_ports} -eq 2 ]; then
        echo "trex-server is ready"
    else
        echo "ERROR: trex-server could not start properly.  Check \'screen -x trex\'"
        exit 1
    fi
else
    echo "ERROR: ${trex_dir} and/or ${tmp_dir} does not exist"
fi
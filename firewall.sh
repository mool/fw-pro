#!/bin/bash

test "$1" == "debug" && set -x
test "$1" == "show"  && iptables() { echo iptables "$@"; } && ip() { echo ip "$@"; } 

source firewall.conf

echo "Generating routing rules..."
ip ru flush
ip ru del from all table main
ip ru add from all prio 1 table main
for ((i=1;i<=${#gw[@]};i++)); do
  if [ -z "$(cat /etc/iproute2/rt_tables | grep enlace$i)" ]; then
    echo -n "* Adding table enlace$i to /etc/iproute2/rt_tables: "
    echo -e "10$i\tenlace$i" >> /etc/iproute2/rt_tables
    echo "done"
  fi

  echo -n "* Setting link $i ${gw_name[$i]}: "
  ip ro flush table enlace$i 2>/dev/null
  ip ro add ${gw[$i]} dev ${gw_iface[$i]} scope link table enlace$i
  ip ro add default via ${gw[$i]} dev ${gw_iface[$i]} proto static onlink table enlace$i
  ip ru add from ${gw_ip[$i]} prio 90 table enlace$i
  ip ru add from ${gw_net[$i]} prio 100 table enlace$i
  ip ru del fwmark 0x$i 2>/dev/null
  ip ru add fwmark 0x$i prio 20$i table enlace$i
  echo "done"
done
echo -n "* Setting default route: "
ip ro del default table main
ip ro del default table default
ip ro add default via ${gw[$default]} table default
ip ru add from all prio 32767 table default
ip ro flush cache
echo "done"

echo "Setting firewall rules..."
# Activamos el IP forwarding
echo -n " * Activating IP Forwarding support: "
echo "1" > /proc/sys/net/ipv4/ip_forward

echo -n "* Deleting firewall rules:"
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
echo "done"

echo -n "Generating packet marking rules: "
iptables -t mangle -A PREROUTING -j CONNMARK --restore-mark
iptables -t mangle -N ENLACES
#iptables -t mangle -A INPUT -m mark --mark 0x0 -j ENLACES
iptables -t mangle -A FORWARD -m mark --mark 0x0 -j ENLACES
#iptables -t mangle -A OUTPUT -m mark --mark 0x0 -j ENLACES
iptables -t mangle -A FORWARD -j MARK --set-mark 0x0
#iptables -t mangle -A OUTPUT -j CONNMARK --restore-mark

for ((i=1;i<=${#lan_iface[@]};i++)); do
  iptables -t mangle -A ENLACES -o ${lan_iface[$i]} -j RETURN
done

for ((i=1;i<=${#gw[@]};i++)); do
  iptables -t mangle -A ENLACES -o ${gw_iface[$i]} -j MARK --set-mark 0x$i
  iptables -t mangle -A ENLACES -i ${gw_iface[$i]} -j MARK --set-mark 0x$i
done

iptables -t mangle -A ENLACES -j CONNMARK --save-mark
echo "done"

echo -n " * Setting firewall port rules: "
for ((i=1;i<=${#gw[@]};i++)); do
  for port in ${gw_tcp_ports[$i]}; do
    iptables -A INPUT -i ${gw_iface[$i]} -p tcp --dport $port -j ACCEPT
  done
  for port in ${gw_udp_ports[$i]}; do
    iptables -A INPUT -i ${gw_iface[$i]} -p tcp --dport $port -j ACCEPT
  done
done
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
# Acepto VPN y LAN
for ((i=1;i<=${#lan_iface[@]};i++)); do
  iptables -A INPUT -i ${lan_iface[$i]} -j ACCEPT
  iptables -A FORWARD -i ${lan_iface[$i]} -j ACCEPT
done
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -i tun+ -j ACCEPT
# Acepto ICMP
iptables -A INPUT -p icmp -j ACCEPT
# No permito conexiones a los demas puertos desde inet
iptables -A INPUT -j REJECT
echo "done"

echo -n " * Activating Port Forwarding: "
for ((i=1;i<=${#gw[@]};i++)); do
  if [[ -n "${gw_redirections[$i]}" ]]; then
    for i in ${gw_redirections[$i]}; do
      extport=$(echo $i | awk -F ':' '{ print $1 }')
      intip=$(echo $i | awk -F ':' '{ print $2 }')
      intport=$(echo $i | awk -F ':' '{ print $3 }')
      proto=$(echo $i | awk -F ':' '{ print $4 }')

      iptables -t nat -A PREROUTING -p $proto -i ${gw_iface[$i]} --dport $extport -j DNAT --to $intip:$intport
    done
  fi
done
echo "done"

echo -n " * Activating NAT: "
for ((i=1;i<=${#gw[@]};i++)); do
  iptables -t nat -A POSTROUTING -o ${gw_iface[$i]} -j MASQUERADE
done
iptables -t mangle -A FORWARD -m tcp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
echo "done"

echo -n " * Activating Transparent Proxy: "
for ((i=1;i<=${#lan_iface[@]};i++)); do
  [ -n "${lan_proxy[$i]}" ] && iptables -t nat -A PREROUTING -i ${lan_iface[$i]} ! -d ${lan_net[$i]} -p tcp -m tcp --dport 80 -j DNAT --to-destination ${lan_proxy[$i]}
done
echo "done"

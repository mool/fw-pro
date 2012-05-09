#!/bin/bash

test "$1" == "debug" && set -x

source firewall.conf

root_dnservers="B C D E F I J K L M"

if [ -n "$inet_default" ]; then
  pong=0
  for letter in $root_dnservers; do
    if(ping -n -c1 -W2 $letter.root-servers.net -I ${inet_ip[$inet_default]} &>/dev/null);then
      pong=1
      route_new="${inet_gw[$inet_default]}"
      break
    fi
  done
  #if no one answers
  if [[ $pong == 0 ]]; then
    echo "$(date) The conection with ${inet_gw[$inet_default]} is down" >> $log
    for ((i=1;i<=${#inet_gw[@]};i++)); do
      if [[ "$i" != "$inet_default" ]]; then
        for letter in $root_dnservers; do
          if(ping -n -c1 -W2 $letter.root-servers.net -I ${inet_ip[$i]} &>/dev/null);then
            pong=1
            route_new=${inet_gw[$i]}
            break
          fi
        done
        #if no one answers
        if [[ $pong == 0 ]]; then
          echo "$(date) The conection with ${inet_gw[$i]} is down" >> $log
        else
          break
        fi
      fi
    done
  fi

  #si todos estan caidos dejo todo como estaba
  test -z "$route_new" && exit 1

  route=$(ip route ls table default | grep default)
  route_new="default via $route_new dev ${inet_iface[$i]}  proto static "
  if [[ "$route" != "$route_new" ]]; then
    # si no son iguales, es hora de cambiar el default gateway
    #ip route chg table default default proto static via $route_new
    ip route chg table default $route_new
    ip route flush cache
    echo "$(date) Changing default gateway to: $route_new" >> $log
  fi
else
  multipath_total=0
  for ((i=1;i<=${#inet_gw[@]};i++)); do
    pong=0
    for letter in $root_dnservers; do
      if(ping -n -c1 -W2 $letter.root-servers.net -I ${inet_ip[$i]} &>/dev/null);then
        pong=1
        # el doble espacio antes de dev _does_mather_
        multipath="$multipath nexthop via ${inet_gw[$i]}  dev ${inet_iface[$i]} weight ${inet_weight[$i]}"
        let multipath_total+=1
        break
      fi
    done
    #if no one answers
    if [[ $pong == 0 ]]; then
      echo "$(date) The conection with ${inet_gw[$i]} is down" >> $log
    fi
  done
  #si todos estan caidos dejo todo como estaba
  test -z "${multipath}" && exit 1
  
  # cargo en $route el multipath actual
  while read line; do
    test -z "${line##default*}" && route="${line}"
    test -z "${line##*nexthop*}" && route="$route ${line}"
  done < \
  <(/sbin/ip route ls)
  
  # armo el multipath de los que estan up para poder comparar
  # tengo que preguntar xq si hay solo un enlace up, la sintaxis cambia
  if [[ $multipath_total > 1 ]]; then
    # el doble espacio antes de proto _does_mather_
    route_multipath=" default  proto static${multipath}"
  else
    route_multipath=${multipath#nexthop }
    route_multipath=${route_multipath% weight*}
    route_multipath=" default ${route_multipath/ dev/ dev} proto static"
  fi
  
  #printf "%q\n" "${route}"
  #printf "%q\n" "${route_multipath}"
  # Ya tengo los 2 multipath, ahora puedo comparar
  if [[ "$route" != "$route_multipath" ]]; then
    # si no son iguales, es hora de cambiar el default gateway
    ip route chg table default default proto static $multipath
    ip route flush cache
    echo "$(date) Changing default gateway to: $multipath" >> $log
  fi
fi

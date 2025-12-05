#!/bin/sh
##############################################################################
#
# Optimized for asynchronous execution to prevent blocking odhcpd
#
##############################################################################

# Load standard OpenWRT functions
. /lib/functions.sh

# Define the lock file
UB_ODHCPD_LOCK=/var/lock/unbound_odhcpd.lock

odhcpd_zonedata() {
  # Load Unbound defaults (creates variables like UB_VARDIR, UB_CONTROL_CFG)
  . /usr/lib/unbound/defaults.sh

  local dhcp_link=$( uci_get unbound.@unbound[0].dhcp_link )
  local dhcp4_slaac6=$( uci_get unbound.@unbound[0].dhcp4_slaac6 )
  local dhcp_domain=$( uci_get unbound.@unbound[0].domain )
  # Dynamically grab the leasefile path.
  local dhcp_origin=$( uci_get dhcp.@odhcpd[0].leasefile )
  local exclude_ipv6_ga=$( uci_get unbound.@unbound[0].exclude_ipv6_ga )

  if [ "$exclude_ipv6_ga" != "0" ] && [ "$exclude_ipv6_ga" != "1" ]; then
    logger -t unbound -s "invalid exclude_ipv6_ga value, using default (0)"
    exclude_ipv6_ga=0
  fi

  # Verify files exist before proceeding
  if [ -f "$UB_TOTAL_CONF" ] && [ -f "$dhcp_origin" ] \
  && [ "$dhcp_link" = "odhcpd" ] && [ -n "$dhcp_domain" ] ; then
    local longconf dateconf dateoldf
    local dns_ls_add=$UB_VARDIR/dhcp_dns.add
    local dns_ls_del=$UB_VARDIR/dhcp_dns.del
    local dns_ls_new=$UB_VARDIR/dhcp_dns.new
    local dns_ls_old=$UB_VARDIR/dhcp_dns.old
    local dhcp_ls_new=$UB_VARDIR/dhcp_lease.new

    if [ ! -f $UB_DHCP_CONF ] || [ ! -f $dns_ls_old ] ; then
      # no old files laying around
      touch $dns_ls_old
      sort $dhcp_origin > $dhcp_ls_new
      longconf=freshstart

    else
      # incremental at high load or full refresh about each 5 minutes
      dateconf=$(( $( date +%s ) - $( date -r $UB_DHCP_CONF +%s ) ))
      dateoldf=$(( $( date +%s ) - $( date -r $dns_ls_old +%s ) ))

      if [ $dateconf -gt 300 ] ; then
        touch $dns_ls_old
        sort $dhcp_origin > $dhcp_ls_new
        longconf=longtime

      elif [ $dateoldf -gt 1 ] ; then
        touch $dns_ls_old
        sort $dhcp_origin > $dhcp_ls_new
        longconf=increment

      else
        # odhcpd is rapidly updating leases a race condition could occur
        longconf=skip
      fi
    fi

    # Execute Logic
    case $longconf in
    freshstart)
      awk -v conffile=$UB_DHCP_CONF -v pipefile=$dns_ls_new \
          -v domain=$dhcp_domain -v bslaac=$dhcp4_slaac6 \
          -v bisolt=0 -v bconf=1 -v exclude_ipv6_ga=$exclude_ipv6_ga \
          -f /usr/lib/unbound/odhcpd.awk $dhcp_ls_new

      cp $dns_ls_new $dns_ls_add
      cp $dns_ls_new $dns_ls_old
      cat $dns_ls_add | $UB_CONTROL_CFG local_datas
      rm -f $dns_ls_new $dns_ls_del $dns_ls_add $dhcp_ls_new
      ;;

    longtime)
      awk -v conffile=$UB_DHCP_CONF -v pipefile=$dns_ls_new \
          -v domain=$dhcp_domain -v bslaac=$dhcp4_slaac6 \
          -v bisolt=0 -v bconf=1 -v exclude_ipv6_ga=$exclude_ipv6_ga \
          -f /usr/lib/unbound/odhcpd.awk $dhcp_ls_new

      awk '{ print $1 }' $dns_ls_old | sort | uniq > $dns_ls_del
      cp $dns_ls_new $dns_ls_add
      cp $dns_ls_new $dns_ls_old
      cat $dns_ls_del | $UB_CONTROL_CFG local_datas_remove
      cat $dns_ls_add | $UB_CONTROL_CFG local_datas
      rm -f $dns_ls_new $dns_ls_del $dns_ls_add $dhcp_ls_new
      ;;

    increment)
      # incremental add and prepare the old list for delete later
      # unbound-control can be slow so high DHCP rates cannot run a full list
      awk -v conffile=$UB_DHCP_CONF -v pipefile=$dns_ls_new \
          -v domain=$dhcp_domain -v bslaac=$dhcp4_slaac6 \
          -v bisolt=0 -v bconf=0 -v exclude_ipv6_ga=$exclude_ipv6_ga \
          -f /usr/lib/unbound/odhcpd.awk $dhcp_ls_new

      sort $dns_ls_new $dns_ls_old $dns_ls_old | uniq -u > $dns_ls_add
      sort $dns_ls_new $dns_ls_old | uniq > $dns_ls_old
      cat $dns_ls_add | $UB_CONTROL_CFG local_datas
      rm -f $dns_ls_new $dns_ls_del $dns_ls_add $dhcp_ls_new
      ;;
    *)
      # Do nothing
      ;;
    esac
  fi
}

##############################################################################
# ASYNC EXECUTION BLOCK
##############################################################################
# This runs the logic in a background subshell.
# odhcpd will exit this script immediately (exit 0), while the logic
# runs in the background. The flock ensures only one instance runs at a time.

(
    # Try to obtain a lock on file descriptor 1000.
    # If locked, exit this subshell silently (skip update).
    flock -x -n 1000 || exit 0

    # Run the main function
    odhcpd_zonedata

) 1000>$UB_ODHCPD_LOCK &

# Immediate exit to unblock odhcpd
exit 0
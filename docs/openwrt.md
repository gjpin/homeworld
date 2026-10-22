# Router setup (upstream OpenWrt, GL.iNet GL-MT6000)

## Before you start

Assumptions (nothing below checks them, so confirm them first):

- Fresh stock upstream OpenWrt 25.12 or higher on a GL.iNet GL-MT6000 with the stock
  shape: DSA ports `lan1`–`lan5`, `br-lan`, exactly one `2g` plus one `5g`
  `wifi-device`, named sections `network.lan` (192.168.1.1),
  `network.wan`, `network.wan6`, `network.loopback`, `network.globals`,
  one anonymous `dhcp.@dnsmasq[0]`, one anonymous `firewall.@defaults[0]`,
  one `lan`-named and one `wan`-named anonymous firewall zone, one
  `lan`→`wan` anonymous forwarding, named `dropbear.main` and
  `uhttpd.main`, and an existing `attendedsysupgrade.client` section.
- The ISP router is at `192.168.2.1/24` and reachable; package installation
  needs working WAN before the renumbering happens.
- You are root, connected over local Ethernet to one of the LAN ports.

Invariants these blocks preserve: IPv4-only (no `wan6`, no ULA, IPv6
delegation and RA/DHCPv6/NDP disabled on every managed network), `system`
untouched, software and hardware flow offloading on (SQM off), Wireless
Ethernet Dispatch enabled (loads after the final reboot), PixelIoT on
WPA2-PSK `psk2+ccmp` with PMF off for older IoT devices, PixelThings on
WPA2/WPA3 `sae-mixed` with optional PMF for WPA2-only clients, chrony client-only,
dnsmasq on port 54 with no public upstreams and no cache, AdGuard Home
primary on port 53 with its dashboard reachable from Pixel only and every
`*.homeworld.internal` name rewritten to the cluster's Gateway VIP
`192.168.8.50`, and an
IPv4-only WireGuard server on `VPN_IF`/`VPN_PORT`/`VPN_ADDR` attached to the
trusted Pixel zone with no preconfigured peers (peers inherit the Pixel
zone's DNS interception).

Warnings:

- Nothing here is undone automatically. Make an off-router `sysupgrade -b`
  backup first and keep a verified recovery path.
- Secrets: the exported variables end up in shell history, `ps`, and (after
  commit) `uci show` output. Keep the bcrypt hash single-quoted. The
  WireGuard private key is secret in the same way.
- AdGuard Home binds DNS to the WireGuard server address; removing that
  interface later breaks AdGuard's startup.
- Blocks do not fail fast: a failed command does not stop the block. Read
  each block's output before continuing.
- Run each block once, in order, and paste it whole. Keep one shell
  session open until activation; the blocks use the exported variables. If
  a block goes wrong, restore the backup and start over rather than
  pasting it again.
- During activation the SSH session to `192.168.1.1` drops; section 13
  handles that deliberately.

## 1. Variables

```sh
export PIXEL_WIFI_PASSWORD='replace-me' # 8-63 printable characters
export THINGS_WIFI_PASSWORD='replace-me'
export GUEST_WIFI_PASSWORD='replace-me'
export IOT_WIFI_PASSWORD='replace-me'
export VPN_IF='wgserver'        # <=15 chars, letters/digits/underscore, letter start
export VPN_PORT='42451'         # UDP listen port, 1-65535
# VPN_KEY is generated in section 2, after wireguard-tools provides `wg`.
# To reuse an existing 44-char WireGuard private key, export it here instead:
# export VPN_KEY='...'
export VPN_ADDR='10.10.0.1/24'  # no overlap with 192.168.2.0/24 or 192.168.8-11.0/24
export COUNTRY='XX'             # two-letter ISO country code
export CHANNEL='36'             # 5 GHz channel (default 36)
export CHANNEL_2G='6'           # 2.4 GHz channel (default 6)
export ADGUARD_USERNAME='admin' # letter/digit first, <=64 chars
# 60-char bcrypt hash, generated off-router, for example:
#   htpasswd -bnBC 12 '' 'secret' | cut -d: -f2
# Keep the single quotes: the $ characters are special to the shell.
export ADGUARD_PASSWORD_HASH='$2y$12$replace-with-a-real-60-character-bcrypt-hash'
# Optional: permit private DNS answers for this apex and its subdomains.
# export DNS_REBIND_DOMAIN='mydomain.com'
umask 077
```

## 2. Packages

```sh
apk update
apk add gawk grep sed ss coreutils-sort nano
apk add chrony-nts
/etc/init.d/sysntpd stop
/etc/init.d/sysntpd disable
/etc/init.d/chronyd enable
apk add adguardhome luci-app-adguardhome
# Keep AdGuard Home stopped and disabled until its configuration is in place.
/etc/init.d/adguardhome stop >/dev/null 2>&1 || :
/etc/init.d/adguardhome disable
apk add wireguard-tools luci-proto-wireguard
[ -n "${VPN_KEY-}" ] || VPN_KEY=$(wg genkey)
export VPN_KEY
[ "${#VPN_KEY}" -eq 44 ] || echo 'VPN_KEY is not a 44-character WireGuard key; stop here' >&2
```

## 3. Network

Name the stock anonymous `dnsmasq` and `br-lan` device sections, remove the
stock LAN and IPv6 WAN, then pin the WAN address and create the four VLANs
with their DHCP pools.

```sh
uci rename "$(uci show dhcp | sed -n 's/^dhcp\.\(@dnsmasq\[[0-9]*\]\)=dnsmasq$/dhcp.\1/p' | head -n1)=dnsmasq"
for s in $(uci show network | sed -n 's/^network\.\(@device\[[0-9]*\]\)=device$/network.\1/p'); do
    [ "$(uci -q get "$s.name")" = br-lan ] && uci rename "$s=br_lan" && break
done

uci delete network.wan6
uci delete network.globals.ula_prefix
uci delete network.lan
uci delete dhcp.lan
uci -q batch <<'EOF'
set network.wan.proto='static'
set network.wan.ipaddr='192.168.2.2'
set network.wan.netmask='255.255.255.0'
set network.wan.gateway='192.168.2.1'
set network.wan.ipv6='0'

set network.pixel_vlan='bridge-vlan'
set network.pixel_vlan.device='br-lan'
set network.pixel_vlan.vlan='1'
add_list network.pixel_vlan.ports='lan1:u*'
add_list network.pixel_vlan.ports='lan2:u*'
add_list network.pixel_vlan.ports='lan3:u*'
add_list network.pixel_vlan.ports='lan4:u*'
add_list network.pixel_vlan.ports='lan5:u*'

set network.pixelthings_vlan='bridge-vlan'
set network.pixelthings_vlan.device='br-lan'
set network.pixelthings_vlan.vlan='4'
add_list network.pixelthings_vlan.ports='lan1:t'

set network.pixelguest_vlan='bridge-vlan'
set network.pixelguest_vlan.device='br-lan'
set network.pixelguest_vlan.vlan='2'
add_list network.pixelguest_vlan.ports='lan1:t'

set network.pixeliot_vlan='bridge-vlan'
set network.pixeliot_vlan.device='br-lan'
set network.pixeliot_vlan.vlan='3'
add_list network.pixeliot_vlan.ports='lan1:t'

set network.pixel='interface'
set network.pixel.device='br-lan.1'
set network.pixel.proto='static'
set network.pixel.ipaddr='192.168.8.1'
set network.pixel.netmask='255.255.255.0'
set network.pixel.delegate='0'

set network.pixelthings='interface'
set network.pixelthings.device='br-lan.4'
set network.pixelthings.proto='static'
set network.pixelthings.ipaddr='192.168.11.1'
set network.pixelthings.netmask='255.255.255.0'
set network.pixelthings.delegate='0'

set network.pixelguest='interface'
set network.pixelguest.device='br-lan.2'
set network.pixelguest.proto='static'
set network.pixelguest.ipaddr='192.168.9.1'
set network.pixelguest.netmask='255.255.255.0'
set network.pixelguest.delegate='0'

set network.pixeliot='interface'
set network.pixeliot.device='br-lan.3'
set network.pixeliot.proto='static'
set network.pixeliot.ipaddr='192.168.10.1'
set network.pixeliot.netmask='255.255.255.0'
set network.pixeliot.delegate='0'

set dhcp.pixel='dhcp'
set dhcp.pixel.interface='pixel'
set dhcp.pixel.ignore='0'
set dhcp.pixel.start='100'
set dhcp.pixel.limit='150'
set dhcp.pixel.leasetime='12h'
set dhcp.pixel.ra='disabled'
set dhcp.pixel.dhcpv6='disabled'
set dhcp.pixel.ndp='disabled'

set dhcp.pixelthings='dhcp'
set dhcp.pixelthings.interface='pixelthings'
set dhcp.pixelthings.ignore='0'
set dhcp.pixelthings.start='100'
set dhcp.pixelthings.limit='150'
set dhcp.pixelthings.leasetime='12h'
set dhcp.pixelthings.ra='disabled'
set dhcp.pixelthings.dhcpv6='disabled'
set dhcp.pixelthings.ndp='disabled'

set dhcp.pixelguest='dhcp'
set dhcp.pixelguest.interface='pixelguest'
set dhcp.pixelguest.ignore='0'
set dhcp.pixelguest.start='100'
set dhcp.pixelguest.limit='150'
set dhcp.pixelguest.leasetime='12h'
set dhcp.pixelguest.ra='disabled'
set dhcp.pixelguest.dhcpv6='disabled'
set dhcp.pixelguest.ndp='disabled'

set dhcp.pixeliot='dhcp'
set dhcp.pixeliot.interface='pixeliot'
set dhcp.pixeliot.ignore='0'
set dhcp.pixeliot.start='100'
set dhcp.pixeliot.limit='150'
set dhcp.pixeliot.leasetime='12h'
set dhcp.pixeliot.ra='disabled'
set dhcp.pixeliot.dhcpv6='disabled'
set dhcp.pixeliot.ndp='disabled'
EOF
uci commit network
uci commit dhcp
```

## 4. Firewall

Name the stock defaults and WAN zone, remove the stock LAN zone, its
LAN→WAN forwarding and the IPsec rules, then apply the zone/isolation policy
and enable flow offloading. Each loop looks the sections up again after
every change, because anonymous UCI indices shift.

```sh
uci rename "$(uci show firewall | sed -n 's/^firewall\.\(@defaults\[[0-9]*\]\)=defaults$/firewall.\1/p' | head -n1)=defaults"
# Stock zones: delete lan, name wan.
while :; do
    s=$(uci show firewall | sed -n 's/^firewall\.\(@zone\[[0-9]*\]\)=zone$/firewall.\1/p' | head -n1)
    [ -n "$s" ] || break
    case $(uci -q get "$s.name") in
        lan) uci delete "$s" ;;
        wan) uci rename "$s=wan" ;;
        *) break ;;
    esac
done
# Stock lan -> wan forwarding.
s=$(uci show firewall | sed -n 's/^firewall\.\(@forwarding\[[0-9]*\]\)=forwarding$/firewall.\1/p' | head -n1)
[ "$(uci -q get "$s.src")" = lan ] && [ "$(uci -q get "$s.dest")" = wan ] && uci delete "$s"
# Stock IPsec forwarding rules (Allow-IPSec-ESP, Allow-ISAKMP); not needed.
while :; do
    s=$(uci show firewall | sed -n -e "s/^\(firewall\.@rule\[[0-9]*\]\)\.name='Allow-IPSec-ESP'$/\1/p" -e "s/^\(firewall\.@rule\[[0-9]*\]\)\.name='Allow-ISAKMP'$/\1/p" | head -n1)
    [ -n "$s" ] || break
    uci delete "$s"
done
uci del_list firewall.wan.network='wan6'

uci -q batch <<'EOF'
set firewall.pixel='zone'
set firewall.pixel.name='pixel'
add_list firewall.pixel.network='pixel'
set firewall.pixel.input='ACCEPT'
set firewall.pixel.output='ACCEPT'
set firewall.pixel.forward='ACCEPT'

set firewall.pixelguest='zone'
set firewall.pixelguest.name='pixelguest'
add_list firewall.pixelguest.network='pixelguest'
set firewall.pixelguest.input='REJECT'
set firewall.pixelguest.output='ACCEPT'
set firewall.pixelguest.forward='REJECT'

set firewall.pixeliot='zone'
set firewall.pixeliot.name='pixeliot'
add_list firewall.pixeliot.network='pixeliot'
set firewall.pixeliot.input='REJECT'
set firewall.pixeliot.output='REJECT'
set firewall.pixeliot.forward='REJECT'

set firewall.pixelthings='zone'
set firewall.pixelthings.name='pixelthings'
add_list firewall.pixelthings.network='pixelthings'
set firewall.pixelthings.input='REJECT'
set firewall.pixelthings.output='ACCEPT'
set firewall.pixelthings.forward='REJECT'

set firewall.pixel_wan='forwarding'
set firewall.pixel_wan.src='pixel'
set firewall.pixel_wan.dest='wan'
set firewall.pixelguest_wan='forwarding'
set firewall.pixelguest_wan.src='pixelguest'
set firewall.pixelguest_wan.dest='wan'
set firewall.pixelthings_wan='forwarding'
set firewall.pixelthings_wan.src='pixelthings'
set firewall.pixelthings_wan.dest='wan'
set firewall.pixel_things='forwarding'
set firewall.pixel_things.src='pixel'
set firewall.pixel_things.dest='pixelthings'
set firewall.pixel_guest='forwarding'
set firewall.pixel_guest.src='pixel'
set firewall.pixel_guest.dest='pixelguest'
set firewall.pixel_iot='forwarding'
set firewall.pixel_iot.src='pixel'
set firewall.pixel_iot.dest='pixeliot'

set firewall.reject_isp_transit_pixelguest='rule'
set firewall.reject_isp_transit_pixelguest.name='Reject-ISP-Transit-PixelGuest'
set firewall.reject_isp_transit_pixelguest.src='pixelguest'
set firewall.reject_isp_transit_pixelguest.dest='wan'
set firewall.reject_isp_transit_pixelguest.dest_ip='192.168.2.0/24'
set firewall.reject_isp_transit_pixelguest.family='ipv4'
set firewall.reject_isp_transit_pixelguest.proto='all'
set firewall.reject_isp_transit_pixelguest.target='REJECT'
set firewall.reject_isp_transit_pixelthings='rule'
set firewall.reject_isp_transit_pixelthings.name='Reject-ISP-Transit-PixelThings'
set firewall.reject_isp_transit_pixelthings.src='pixelthings'
set firewall.reject_isp_transit_pixelthings.dest='wan'
set firewall.reject_isp_transit_pixelthings.dest_ip='192.168.2.0/24'
set firewall.reject_isp_transit_pixelthings.family='ipv4'
set firewall.reject_isp_transit_pixelthings.proto='all'
set firewall.reject_isp_transit_pixelthings.target='REJECT'
set firewall.reject_isp_transit_pixeliot='rule'
set firewall.reject_isp_transit_pixeliot.name='Reject-ISP-Transit-PixelIoT'
set firewall.reject_isp_transit_pixeliot.src='pixeliot'
set firewall.reject_isp_transit_pixeliot.dest='wan'
set firewall.reject_isp_transit_pixeliot.dest_ip='192.168.2.0/24'
set firewall.reject_isp_transit_pixeliot.family='ipv4'
set firewall.reject_isp_transit_pixeliot.proto='all'
set firewall.reject_isp_transit_pixeliot.target='REJECT'

set firewall.pixelthings_services='rule'
set firewall.pixelthings_services.name='PixelThings-DNS-DHCP'
set firewall.pixelthings_services.src='pixelthings'
set firewall.pixelthings_services.dest_port='53 67 68'
set firewall.pixelthings_services.proto='tcp udp'
set firewall.pixelthings_services.target='ACCEPT'
set firewall.pixelguest_services='rule'
set firewall.pixelguest_services.name='PixelGuest-DNS-DHCP'
set firewall.pixelguest_services.src='pixelguest'
set firewall.pixelguest_services.dest_port='53 67 68'
set firewall.pixelguest_services.proto='tcp udp'
set firewall.pixelguest_services.target='ACCEPT'
set firewall.pixeliot_services='rule'
set firewall.pixeliot_services.name='PixelIoT-DNS-DHCP'
set firewall.pixeliot_services.src='pixeliot'
set firewall.pixeliot_services.dest_port='53 67 68'
set firewall.pixeliot_services.proto='tcp udp'
set firewall.pixeliot_services.target='ACCEPT'

# IoT rejects general router-originated output, so permit only DHCPv4 replies.
set firewall.pixeliot_dhcp_reply='rule'
set firewall.pixeliot_dhcp_reply.name='PixelIoT-DHCP-Reply'
set firewall.pixeliot_dhcp_reply.dest='pixeliot'
set firewall.pixeliot_dhcp_reply.src_port='67'
set firewall.pixeliot_dhcp_reply.dest_port='68'
set firewall.pixeliot_dhcp_reply.proto='udp'
set firewall.pixeliot_dhcp_reply.family='ipv4'
set firewall.pixeliot_dhcp_reply.target='ACCEPT'
EOF
uci set firewall.defaults.flow_offloading='1'
uci set firewall.defaults.flow_offloading_hw='1'
uci commit firewall
```

## 5. Wireless

Discover the two radios by band (names vary), apply the access-point
overlay, inject the keys, pin channels and modes, and enable Wireless
Ethernet Dispatch.

```sh
WIRELESS_2G_DEVICE=
WIRELESS_5G_DEVICE=
for s in $(uci show wireless | sed -n 's/^wireless\.\([^.]*\)=wifi-device$/\1/p'); do
    case $(uci -q get "wireless.$s.band" 2>/dev/null) in
        2g) WIRELESS_2G_DEVICE=$s ;;
        5g) WIRELESS_5G_DEVICE=$s ;;
    esac
done
echo "2.4 GHz radio: $WIRELESS_2G_DEVICE; 5 GHz radio: $WIRELESS_5G_DEVICE"
[ -n "$WIRELESS_2G_DEVICE" ] && [ -n "$WIRELESS_5G_DEVICE" ] ||
    echo 'expected exactly one 2g and one 5g wifi-device' >&2

# Remove the stock open "OpenWrt" SSIDs (default_radio0/default_radio1 on a
# fresh image), matched by SSID.
while :; do
    s=$(uci show wireless | sed -n "s/^\(wireless\.[^.]*\)\.ssid='OpenWrt'$/\1/p" | head -n1)
    [ -n "$s" ] || break
    uci delete "$s" || break
done

uci -q batch <<'EOF'
set wireless.pixel='wifi-iface'
set wireless.pixel.mode='ap'
set wireless.pixel.network='pixel'
set wireless.pixel.ssid='Pixel'
set wireless.pixel.encryption='sae'

set wireless.pixelthings='wifi-iface'
set wireless.pixelthings.mode='ap'
set wireless.pixelthings.network='pixelthings'
set wireless.pixelthings.ssid='PixelThings'
set wireless.pixelthings.encryption='sae-mixed'
set wireless.pixelthings.ieee80211w='1'
set wireless.pixelthings.isolate='1'

set wireless.pixelguest='wifi-iface'
set wireless.pixelguest.mode='ap'
set wireless.pixelguest.network='pixelguest'
set wireless.pixelguest.ssid='PixelGuest'
set wireless.pixelguest.encryption='sae'
set wireless.pixelguest.isolate='1'

set wireless.pixeliot='wifi-iface'
set wireless.pixeliot.mode='ap'
set wireless.pixeliot.network='pixeliot'
set wireless.pixeliot.ssid='PixelIoT'
set wireless.pixeliot.encryption='psk2+ccmp'
set wireless.pixeliot.ieee80211w='0'
set wireless.pixeliot.isolate='1'
EOF
uci set "wireless.pixel.key=$PIXEL_WIFI_PASSWORD"
uci set "wireless.pixelthings.key=$THINGS_WIFI_PASSWORD"
uci set "wireless.pixelguest.key=$GUEST_WIFI_PASSWORD"
uci set "wireless.pixeliot.key=$IOT_WIFI_PASSWORD"
uci set "wireless.pixel.device=$WIRELESS_5G_DEVICE"
uci set "wireless.pixelthings.device=$WIRELESS_5G_DEVICE"
uci set "wireless.pixelguest.device=$WIRELESS_5G_DEVICE"
uci set "wireless.pixeliot.device=$WIRELESS_2G_DEVICE"
uci set "wireless.$WIRELESS_2G_DEVICE.country=$COUNTRY"
uci set "wireless.$WIRELESS_5G_DEVICE.country=$COUNTRY"
uci set "wireless.$WIRELESS_5G_DEVICE.channel=$CHANNEL"
uci set "wireless.$WIRELESS_5G_DEVICE.htmode=HE80"
uci set "wireless.$WIRELESS_2G_DEVICE.channel=$CHANNEL_2G"
uci set "wireless.$WIRELESS_2G_DEVICE.htmode=HT20"
uci add_list "wireless.$WIRELESS_5G_DEVICE.hostapd_options=he_twt_responder=0"
# First-boot wireless ships the radios with disabled='1'; enable both.
uci set "wireless.$WIRELESS_5G_DEVICE.disabled=0"
uci set "wireless.$WIRELESS_2G_DEVICE.disabled=0"
uci commit wireless

# WED: one options line in /etc/modules.conf; loads after the final reboot.
printf '%s\n' 'options mt7915e wed_enable=Y' >>/etc/modules.conf
```

## 6. Admin access and upgrade checks

Bind LuCI and SSH to the Pixel management network only, and have LuCI check
for upgrades whenever the status page loads.

```sh
uci delete uhttpd.main.listen_http
uci delete uhttpd.main.listen_https
uci -q batch <<'EOF'
add_list uhttpd.main.listen_http='192.168.8.1:80'
add_list uhttpd.main.listen_https='192.168.8.1:443'
set uhttpd.main.redirect_https='1'

set dropbear.main.DirectInterface='pixel'
set dropbear.main.Port='22'
set dropbear.main.enable='1'
EOF
uci commit uhttpd
uci commit dropbear
uci set attendedsysupgrade.client.login_check_for_upgrades='1'
uci commit attendedsysupgrade
```

## 7. Time sync (authenticated NTP)

This rebuilds the package's chrony UCI from scratch: its stock pool,
DHCP-supplied NTP source, and LAN allow sections are intentionally
discarded, keeping the router a client-only NTP node. The plain NTP-by-IP
bootstrap sources are what let a cold clock synchronize before encrypted
DNS is available.

```sh
: >/etc/config/chrony
uci -q batch <<'EOF'
set chrony.cloudflare='server'
set chrony.cloudflare.hostname='time.cloudflare.com'
set chrony.cloudflare.iburst='1'
set chrony.cloudflare.nts='1'
set chrony.cloudflare.prefer='1'

set chrony.netnod='server'
set chrony.netnod.hostname='nts.netnod.se'
set chrony.netnod.iburst='1'
set chrony.netnod.nts='1'
set chrony.netnod.prefer='1'

set chrony.time_nl='server'
set chrony.time_nl.hostname='ntppool1.time.nl'
set chrony.time_nl.iburst='1'
set chrony.time_nl.nts='1'
set chrony.time_nl.prefer='1'

set chrony.bootstrap_1='server'
set chrony.bootstrap_1.hostname='194.177.4.1'
set chrony.bootstrap_1.iburst='1'
set chrony.bootstrap_1.nts='0'

set chrony.bootstrap_2='server'
set chrony.bootstrap_2.hostname='213.222.217.11'
set chrony.bootstrap_2.iburst='1'
set chrony.bootstrap_2.nts='0'

set chrony.bootstrap_3='server'
set chrony.bootstrap_3.hostname='80.50.102.114'
set chrony.bootstrap_3.iburst='1'
set chrony.bootstrap_3.nts='0'

set chrony.bootstrap_4='server'
set chrony.bootstrap_4.hostname='193.219.28.60'
set chrony.bootstrap_4.iburst='1'
set chrony.bootstrap_4.nts='0'

set chrony.dhcp_ntp_server='dhcp_ntp_server'
set chrony.dhcp_ntp_server.iburst='1'
set chrony.dhcp_ntp_server.disabled='1'

set chrony.makestep='makestep'
set chrony.makestep.threshold='1.0'
set chrony.makestep.limit='3'

set chrony.nts='nts'
set chrony.nts.rtccheck='1'
set chrony.nts.systemcerts='1'
EOF
uci commit chrony
# Let the unauthenticated bootstrap sources select on their own.
awk '
    /^[[:space:]]*authselectmode[[:space:]]+/ { next }
    /^[[:space:]]*confdir[[:space:]]+\/var\/etc\/chrony\.d[[:space:]]*([#].*)?$/ {
        print "authselectmode ignore"
    }
    { print }
' /etc/chrony/chrony.conf >/etc/chrony/chrony.conf.new.$$
mv -f /etc/chrony/chrony.conf.new.$$ /etc/chrony/chrony.conf
```

## 8. DNS policy (dnsmasq on 54, AdGuard Home on 53)

AdGuard Home becomes the primary resolver on every managed network:
dnsmasq moves to port 54 for `.lan` and PTR only, clients get their
gateway advertised via DHCP option 6, port-53 traffic is intercepted, and
encrypted-DNS bypasses (DoT/DoQ) plus direct port-54 access are rejected
for every VLAN.

```sh
uci delete adguardhome.config
uci -q batch <<'EOF'
set adguardhome.config='adguardhome'
set adguardhome.config.config_file='/etc/adguardhome/adguardhome.yaml'
set adguardhome.config.work_dir='/opt/adguardhome'
set adguardhome.config.user='adguardhome'
set adguardhome.config.group='adguardhome'
set adguardhome.config.verbose='0'

set dhcp.dnsmasq.port='54'
set dhcp.dnsmasq.noresolv='1'
set dhcp.dnsmasq.cachesize='0'
set dhcp.dnsmasq.localservice='1'
set dhcp.dnsmasq.domain='lan'
set dhcp.dnsmasq.local='/lan/'
set dhcp.dnsmasq.expandhosts='1'

add_list dhcp.pixel.dhcp_option='6,192.168.8.1'
add_list dhcp.pixelguest.dhcp_option='6,192.168.9.1'
add_list dhcp.pixeliot.dhcp_option='6,192.168.10.1'
add_list dhcp.pixelthings.dhcp_option='6,192.168.11.1'

set network.wan.peerdns='0'

set firewall.divert_dns_pixel='redirect'
set firewall.divert_dns_pixel.name='Pixel-Divert-DNS'
set firewall.divert_dns_pixel.src='pixel'
set firewall.divert_dns_pixel.src_dport='53'
set firewall.divert_dns_pixel.dest_port='53'
set firewall.divert_dns_pixel.proto='tcp udp'
set firewall.divert_dns_pixel.target='DNAT'
set firewall.reject_dot_pixel='rule'
set firewall.reject_dot_pixel.name='Pixel-Reject-DoT'
set firewall.reject_dot_pixel.src='pixel'
set firewall.reject_dot_pixel.dest='*'
set firewall.reject_dot_pixel.dest_port='853'
set firewall.reject_dot_pixel.proto='tcp udp'
set firewall.reject_dot_pixel.target='REJECT'
set firewall.reject_doq_pixel='rule'
set firewall.reject_doq_pixel.name='Pixel-Reject-DoQ'
set firewall.reject_doq_pixel.src='pixel'
set firewall.reject_doq_pixel.dest='*'
set firewall.reject_doq_pixel.dest_port='8853'
set firewall.reject_doq_pixel.proto='udp'
set firewall.reject_doq_pixel.target='REJECT'
set firewall.reject_doq_784_pixel='rule'
set firewall.reject_doq_784_pixel.name='Pixel-Reject-DoQ-784'
set firewall.reject_doq_784_pixel.src='pixel'
set firewall.reject_doq_784_pixel.dest='*'
set firewall.reject_doq_784_pixel.dest_port='784'
set firewall.reject_doq_784_pixel.proto='udp'
set firewall.reject_doq_784_pixel.target='REJECT'
set firewall.reject_dnsmasq_pixel='rule'
set firewall.reject_dnsmasq_pixel.name='Pixel-Reject-dnsmasq-Bypass'
set firewall.reject_dnsmasq_pixel.src='pixel'
set firewall.reject_dnsmasq_pixel.dest_port='54'
set firewall.reject_dnsmasq_pixel.proto='tcp udp'
set firewall.reject_dnsmasq_pixel.target='REJECT'

set firewall.divert_dns_pixelguest='redirect'
set firewall.divert_dns_pixelguest.name='PixelGuest-Divert-DNS'
set firewall.divert_dns_pixelguest.src='pixelguest'
set firewall.divert_dns_pixelguest.src_dport='53'
set firewall.divert_dns_pixelguest.dest_port='53'
set firewall.divert_dns_pixelguest.proto='tcp udp'
set firewall.divert_dns_pixelguest.target='DNAT'
set firewall.reject_dot_pixelguest='rule'
set firewall.reject_dot_pixelguest.name='PixelGuest-Reject-DoT'
set firewall.reject_dot_pixelguest.src='pixelguest'
set firewall.reject_dot_pixelguest.dest='*'
set firewall.reject_dot_pixelguest.dest_port='853'
set firewall.reject_dot_pixelguest.proto='tcp udp'
set firewall.reject_dot_pixelguest.target='REJECT'
set firewall.reject_doq_pixelguest='rule'
set firewall.reject_doq_pixelguest.name='PixelGuest-Reject-DoQ'
set firewall.reject_doq_pixelguest.src='pixelguest'
set firewall.reject_doq_pixelguest.dest='*'
set firewall.reject_doq_pixelguest.dest_port='8853'
set firewall.reject_doq_pixelguest.proto='udp'
set firewall.reject_doq_pixelguest.target='REJECT'
set firewall.reject_doq_784_pixelguest='rule'
set firewall.reject_doq_784_pixelguest.name='PixelGuest-Reject-DoQ-784'
set firewall.reject_doq_784_pixelguest.src='pixelguest'
set firewall.reject_doq_784_pixelguest.dest='*'
set firewall.reject_doq_784_pixelguest.dest_port='784'
set firewall.reject_doq_784_pixelguest.proto='udp'
set firewall.reject_doq_784_pixelguest.target='REJECT'
set firewall.reject_dnsmasq_pixelguest='rule'
set firewall.reject_dnsmasq_pixelguest.name='PixelGuest-Reject-dnsmasq-Bypass'
set firewall.reject_dnsmasq_pixelguest.src='pixelguest'
set firewall.reject_dnsmasq_pixelguest.dest_port='54'
set firewall.reject_dnsmasq_pixelguest.proto='tcp udp'
set firewall.reject_dnsmasq_pixelguest.target='REJECT'

set firewall.divert_dns_pixelthings='redirect'
set firewall.divert_dns_pixelthings.name='PixelThings-Divert-DNS'
set firewall.divert_dns_pixelthings.src='pixelthings'
set firewall.divert_dns_pixelthings.src_dport='53'
set firewall.divert_dns_pixelthings.dest_port='53'
set firewall.divert_dns_pixelthings.proto='tcp udp'
set firewall.divert_dns_pixelthings.target='DNAT'
set firewall.reject_dot_pixelthings='rule'
set firewall.reject_dot_pixelthings.name='PixelThings-Reject-DoT'
set firewall.reject_dot_pixelthings.src='pixelthings'
set firewall.reject_dot_pixelthings.dest='*'
set firewall.reject_dot_pixelthings.dest_port='853'
set firewall.reject_dot_pixelthings.proto='tcp udp'
set firewall.reject_dot_pixelthings.target='REJECT'
set firewall.reject_doq_pixelthings='rule'
set firewall.reject_doq_pixelthings.name='PixelThings-Reject-DoQ'
set firewall.reject_doq_pixelthings.src='pixelthings'
set firewall.reject_doq_pixelthings.dest='*'
set firewall.reject_doq_pixelthings.dest_port='8853'
set firewall.reject_doq_pixelthings.proto='udp'
set firewall.reject_doq_pixelthings.target='REJECT'
set firewall.reject_doq_784_pixelthings='rule'
set firewall.reject_doq_784_pixelthings.name='PixelThings-Reject-DoQ-784'
set firewall.reject_doq_784_pixelthings.src='pixelthings'
set firewall.reject_doq_784_pixelthings.dest='*'
set firewall.reject_doq_784_pixelthings.dest_port='784'
set firewall.reject_doq_784_pixelthings.proto='udp'
set firewall.reject_doq_784_pixelthings.target='REJECT'
set firewall.reject_dnsmasq_pixelthings='rule'
set firewall.reject_dnsmasq_pixelthings.name='PixelThings-Reject-dnsmasq-Bypass'
set firewall.reject_dnsmasq_pixelthings.src='pixelthings'
set firewall.reject_dnsmasq_pixelthings.dest_port='54'
set firewall.reject_dnsmasq_pixelthings.proto='tcp udp'
set firewall.reject_dnsmasq_pixelthings.target='REJECT'

set firewall.divert_dns_pixeliot='redirect'
set firewall.divert_dns_pixeliot.name='PixelIoT-Divert-DNS'
set firewall.divert_dns_pixeliot.src='pixeliot'
set firewall.divert_dns_pixeliot.src_dport='53'
set firewall.divert_dns_pixeliot.dest_port='53'
set firewall.divert_dns_pixeliot.proto='tcp udp'
set firewall.divert_dns_pixeliot.target='DNAT'
set firewall.reject_dot_pixeliot='rule'
set firewall.reject_dot_pixeliot.name='PixelIoT-Reject-DoT'
set firewall.reject_dot_pixeliot.src='pixeliot'
set firewall.reject_dot_pixeliot.dest='*'
set firewall.reject_dot_pixeliot.dest_port='853'
set firewall.reject_dot_pixeliot.proto='tcp udp'
set firewall.reject_dot_pixeliot.target='REJECT'
set firewall.reject_doq_pixeliot='rule'
set firewall.reject_doq_pixeliot.name='PixelIoT-Reject-DoQ'
set firewall.reject_doq_pixeliot.src='pixeliot'
set firewall.reject_doq_pixeliot.dest='*'
set firewall.reject_doq_pixeliot.dest_port='8853'
set firewall.reject_doq_pixeliot.proto='udp'
set firewall.reject_doq_pixeliot.target='REJECT'
set firewall.reject_doq_784_pixeliot='rule'
set firewall.reject_doq_784_pixeliot.name='PixelIoT-Reject-DoQ-784'
set firewall.reject_doq_784_pixeliot.src='pixeliot'
set firewall.reject_doq_784_pixeliot.dest='*'
set firewall.reject_doq_784_pixeliot.dest_port='784'
set firewall.reject_doq_784_pixeliot.proto='udp'
set firewall.reject_doq_784_pixeliot.target='REJECT'
set firewall.reject_dnsmasq_pixeliot='rule'
set firewall.reject_dnsmasq_pixeliot.name='PixelIoT-Reject-dnsmasq-Bypass'
set firewall.reject_dnsmasq_pixeliot.src='pixeliot'
set firewall.reject_dnsmasq_pixeliot.dest_port='54'
set firewall.reject_dnsmasq_pixeliot.proto='tcp udp'
set firewall.reject_dnsmasq_pixeliot.target='REJECT'
EOF
uci commit dhcp
uci commit firewall
uci commit network
uci commit adguardhome
```

## 9. AdGuard Home configuration

The dashboard binds to Pixel only; DNS binds loopback, the WireGuard server
address, and the four VLAN
gateways. Blocked responses are NXDOMAIN, AAAA answers are disabled
(IPv4-only networks), `.lan` and private PTR go to dnsmasq on port 54,
`*.homeworld.internal` (every cluster hostname, at any depth) is answered
locally with the Envoy Gateway VIP `192.168.8.50` (outside the DHCP pool,
see section 17), and 26 filter lists are enabled. Rewrites are
answered before filtering, so the rebind-protection list does not block
these private answers. An optional `DNS_REBIND_DOMAIN` adds a private
answer exception after the built-in user rules.

```sh
mkdir -p /etc/adguardhome
DNS_REBIND_DOMAIN=$(printf '%s' "${DNS_REBIND_DOMAIN-}" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz')
awk -v username="$ADGUARD_USERNAME" \
    -v password_hash="$ADGUARD_PASSWORD_HASH" \
    -v rebind_domain="$DNS_REBIND_DOMAIN" \
    -v wireguard_bind_host="${VPN_ADDR%/*}" '
    $0 == "@ADGUARD_USER@" {
        print "- name: \047" username "\047"
        print "  password: \047" password_hash "\047"
        next
    }
    $0 == "@USER_RULES@" {
        print "user_rules:"
        print "- \047@@||steamconnecttest.com^\047"
        print "- \047@@||ipv6check-udp.steamserver.net^\047"
        print "- \047@@||ipv6check-http.steamserver.net^\047"
        print "- \047@@||lgtvonline.lge.com^\047"
        print "- \047@@||ipv4.connman.net^\047"
        print "- \047@@||ipv6.connman.net^\047"
        print "- \047@@||lgtvsdp.com^\047"
        print "- \047@@||suggestqueries*.youtube.com^\047"
        print "- \047@@||suggestqueries.google.com^\047"
        print "- \047@@||clients1.google.com^\047"
        print "- \047@@||clients2.google.com^\047"
        print "- \047@@||clients3.google.com^\047"
        print "- \047@@||clients.l.google.com^\047"
        print "- \047@@||script.google.com^\047"
        print "- \047@@||script.googleusercontent.com^\047"
        print "- \047@@||doc-*-docstext.googleusercontent.com^\047"
        if (rebind_domain != "") {
            print "- \047@@||" rebind_domain "^\047"
        }
        next
    }
    $0 == "@WIREGUARD_BIND_HOST@" {
        print "  - " wireguard_bind_host
        next
    }
    { print }
' >/etc/adguardhome/adguardhome.yaml <<'EOF'
http:
  address: 192.168.8.1:3000
  session_ttl: 720h
  pprof:
    enabled: false
    port: 6060
  doh:
    insecure_enabled: false
    routes:
    - GET /dns-query
    - POST /dns-query
    - GET /dns-query/{ClientID}
    - POST /dns-query/{ClientID}
users:
@ADGUARD_USER@
auth_attempts: 5
block_auth_min: 15
http_proxy: ""
language: en
theme: auto
dns:
  bind_hosts:
  - 127.0.0.1
@WIREGUARD_BIND_HOST@
  - 192.168.8.1
  - 192.168.9.1
  - 192.168.10.1
  - 192.168.11.1
  port: 53
  anonymize_client_ip: false
  ratelimit: 20
  ratelimit_subnet_len_ipv4: 24
  ratelimit_subnet_len_ipv6: 56
  ratelimit_whitelist: []
  refuse_any: true
  upstream_dns:
  - '[/lan/]127.0.0.1:54'
  - https://dns.quad9.net/dns-query
  - https://security.cloudflare-dns.com/dns-query
  - https://freedns.controld.com/p2
  upstream_dns_file: ""
  bootstrap_dns:
  - 9.9.9.11:53
  - 1.1.1.1:53
  - 8.8.8.8:53
  fallback_dns: []
  upstream_mode: load_balance
  fastest_timeout: 1s
  allowed_clients: []
  disallowed_clients: []
  blocked_hosts: []
  trusted_proxies: []
  cache_enabled: true
  cache_size: 4194304
  cache_ttl_min: 0
  cache_ttl_max: 0
  cache_optimistic: false
  cache_optimistic_answer_ttl: 30s
  cache_optimistic_max_age: 12h
  bogus_nxdomain: []
  aaaa_disabled: true
  enable_dnssec: false
  edns_client_subnet:
    enabled: false
    use_custom: false
    custom_ip: ""
  max_goroutines: 300
  handle_ddr: true
  upstream_timeout: 10s
  private_networks:
  - 127.0.0.0/8
  - 10.0.0.0/8
  - 172.16.0.0/12
  - 192.168.0.0/16
  use_private_ptr_resolvers: true
  local_ptr_upstreams:
  - 127.0.0.1:54
  use_dns64: false
  dns64_prefixes: []
  serve_http3: false
  use_http3_upstreams: false
  serve_plain_dns: true
  hostsfile_enabled: true
  pending_requests:
    enabled: true
filtering:
  protection_enabled: true
  filtering_enabled: true
  filters_update_interval: 24
  blocking_mode: nxdomain
  blocking_ipv4: ""
  blocking_ipv6: ""
  blocked_response_ttl: 10
  parental_enabled: false
  safebrowsing_enabled: false
  rewrites_enabled: true
  rewrites:
  - domain: '*.homeworld.internal'
    answer: 192.168.8.50
    enabled: true
  safe_fs_patterns: []
  safe_search:
    enabled: false
    bing: true
    duckduckgo: true
    ecosia: true
    google: true
    pixabay: true
    yandex: true
    youtube: true
  blocked_services:
    schedule:
      time_zone: Local
    ids: []
filters:
- enabled: true
  url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
  name: AdGuard DNS filter
  id: 1
- enabled: true
  url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt
  name: AdAway Default Blocklist
  id: 2
- enabled: true
  url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_71.txt
  name: HaGeZi DNS Rebind Protection
  id: 3
- enabled: true
  url: https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt
  name: HaGeZi - Multi PRO
  id: 4
- enabled: true
  url: https://big.oisd.nl
  name: OISD
  id: 5
- enabled: true
  url: https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts
  name: Steven Black
  id: 6
- enabled: true
  url: 'https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext'
  name: Peter Lowe
  id: 7
- enabled: true
  url: https://raw.githubusercontent.com/nextdns/native-tracking-domains/refs/heads/main/domains/windows
  name: NextDNS - Windows
  id: 8
- enabled: true
  url: https://raw.githubusercontent.com/nextdns/native-tracking-domains/refs/heads/main/domains/samsung
  name: NextDNS - Samsung
  id: 9
- enabled: true
  url: https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/native.samsung.txt
  name: HaGeZi - Samsung native tracking
  id: 10
- enabled: true
  url: https://raw.githubusercontent.com/nextdns/native-tracking-domains/refs/heads/main/domains/apple
  name: NextDNS - Apple
  id: 11
- enabled: true
  url: https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/doh-vpn-proxy-bypass.txt
  name: HaGeZi - Prevent DNS bypass
  id: 12
- enabled: true
  url: https://raw.githubusercontent.com/Perflyst/PiHoleBlocklist/master/SmartTV-AGH.txt
  name: Smart TV
  id: 13
- enabled: true
  url: https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/native.lgwebos.txt
  name: HaGeZi - LG webOS
  id: 14
- enabled: true
  url: https://perflyst.github.io/PiHoleBlocklist/SmartTV.txt
  name: Smart TV blocklist
  id: 15
- enabled: true
  url: https://blocklistproject.github.io/Lists/smart-tv.txt
  name: Block List Project - Smart TV
  id: 16
- enabled: true
  url: https://raw.githubusercontent.com/Perflyst/PiHoleBlocklist/master/android-tracking.txt
  name: Perflyst - Android tracking
  id: 17
- enabled: true
  url: https://divested.dev/blocklists/LG.txt
  name: Divested - LG
  id: 18
- enabled: true
  url: https://divested.dev/blocklists/Mobile.txt
  name: Divested - Mobile
  id: 19
- enabled: true
  url: https://repository.gameindustry.eu/raw/gaminghosts
  name: GameIndustry - Gaming hosts
  id: 20
- enabled: true
  url: https://raw.githubusercontent.com/AdguardTeam/cname-trackers/master/data/combined_disguised_trackers_justdomains.txt
  name: AdGuard CNAME trackers
  id: 21
- enabled: true
  url: https://hole.cert.pl/domains/v2/domains.txt
  name: CERT Polska
  id: 22
- enabled: true
  url: https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/native.apple.txt
  name: HaGeZi - Apple native tracking
  id: 23
- enabled: true
  url: https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/native.winoffice.txt
  name: HaGeZi - Windows/Office native tracking
  id: 24
- enabled: true
  url: https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/native.tiktok.txt
  name: HaGeZi - TikTok native tracking
  id: 25
- enabled: true
  url: https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/tif.medium.txt
  name: HaGeZi - Threat Intelligence Feeds
  id: 26
whitelist_filters: []
@USER_RULES@
clients:
  persistent: []
  runtime_sources:
    whois: true
    arp: true
    rdns: true
    dhcp: true
    hosts: true
dhcp:
  enabled: false
  interface_name: ""
  local_domain_name: lan
  dhcpv4:
    gateway_ip: ""
    subnet_mask: ""
    range_start: ""
    range_end: ""
    lease_duration: 86400
    icmp_timeout_msec: 1000
tls:
  enabled: false
  server_name: ""
  force_https: false
  port_https: 0
  port_dns_over_tls: 0
  port_dns_over_quic: 0
  port_dnscrypt: 0
  dnscrypt_config_file: ""
  allow_unencrypted_doh: false
  certificate_chain: ""
  private_key: ""
  certificate_path: ""
  private_key_path: ""
  strict_sni_check: false
querylog:
  enabled: true
  file_enabled: true
  interval: 7d
  size_memory: 5000
  ignored: []
  ignored_enabled: false
statistics:
  enabled: true
  interval: 7d
  ignored: []
  ignored_enabled: false
os:
  group: ""
  user: ""
  rlimit_nofile: 0
schema_version: 34
log:
  file: ""
  max_backups: 0
  max_size: 100
  max_age: 3
  compress: true
  local_time: false
  verbose: false
EOF
chmod 600 /etc/adguardhome/adguardhome.yaml
chown adguardhome:adguardhome /etc/adguardhome/adguardhome.yaml
chmod 700 /etc/adguardhome
chown adguardhome:adguardhome /etc/adguardhome
/usr/bin/AdGuardHome --check-config --config /etc/adguardhome/adguardhome.yaml --no-check-update
```

## 10. WireGuard server

The server interface, its WAN firewall rule, and membership in the trusted
Pixel zone. The server starts with no client peers; section 16 adds them.
It has to exist before activation, because AdGuard Home binds DNS to its
address.

NOTE: the heredoc delimiter below is deliberately UNQUOTED so that `$VPN_IF`,
`$VPN_PORT` and `$VPN_ADDR` expand. Quoting it by habit creates a garbage
literal `$VPN_IF` section; the `uci get network.$VPN_IF` line in section 14
catches that.

```sh
uci -q batch <<EOF
set network.$VPN_IF='interface'
set network.$VPN_IF.proto='wireguard'
set network.$VPN_IF.listen_port='$VPN_PORT'
add_list network.$VPN_IF.addresses='$VPN_ADDR'
add_list firewall.pixel.network='$VPN_IF'
set firewall.allow_wireguard='rule'
set firewall.allow_wireguard.name='Allow-WireGuard'
set firewall.allow_wireguard.src='wan'
set firewall.allow_wireguard.dest_port='$VPN_PORT'
set firewall.allow_wireguard.proto='udp'
set firewall.allow_wireguard.target='ACCEPT'
EOF
uci set "network.$VPN_IF.private_key=$VPN_KEY"
uci commit network
uci commit firewall
```

## 11. File modes

Every UCI file and `/etc/modules.conf` hold secrets or policy and should be
mode 600; the package-owned chrony configuration stays 644. `uci commit`
does not enforce that, so normalize after the last commit.

```sh
chmod 600 /etc/config/network /etc/config/firewall /etc/config/wireless /etc/config/dhcp \
    /etc/config/system /etc/config/adguardhome /etc/config/chrony /etc/config/uhttpd \
    /etc/config/dropbear /etc/config/attendedsysupgrade
chmod 600 /etc/modules.conf
chmod 644 /etc/chrony/chrony.conf
```

## 12. Pre-activation gate

Both must be clean before continuing: `fw4 check` prints nothing on
success, and the grep must output nothing (no unresolved placeholders).

```sh
fw4 check
grep -F '${' /etc/config/* /etc/adguardhome/adguardhome.yaml
```

## 13. Activation

The restart sequence re-addresses management to `192.168.8.1`, which kills
this SSH session. Run it detached so it survives: paste the block, then
leave the session alone until it drops (~a minute later). If you have a
serial console you may run `sh /root/simple-apply.sh "$VPN_IF"` there
instead. The runner only restarts services, so it can be run again if it
stops partway.

The network is restarted, not reloaded: netifd loads protocol handlers only
when it starts, and the WireGuard handler arrived with `wireguard-tools` in
section 2. A reload would leave the WireGuard interface down (`NO_DEVICE`).
The runner then waits for the WireGuard address before restarting dnsmasq
and AdGuard Home, so AdGuard's DNS bind on that address succeeds.

After it finishes: force a new DHCP lease (replug the Ethernet cable, or
set a static `192.168.8.x/24` address), then SSH to `root@192.168.8.1`.

```sh
cat >/root/simple-apply.sh <<'EOF'
#!/bin/sh
/etc/init.d/adguardhome stop
/etc/init.d/dnsmasq stop
/etc/init.d/network restart
i=0
until ifstatus "$1" | grep -q '"up": true' || [ "$i" -ge 30 ]; do
    i=$((i + 1))
    sleep 1
done
ifstatus "$1" | grep -q '"up": true' || echo "WireGuard interface $1 is not up" >&2
wifi reload
/etc/init.d/firewall reload
/etc/init.d/uhttpd restart
/etc/init.d/dropbear restart
/etc/init.d/chronyd restart
/etc/init.d/dnsmasq restart
/etc/init.d/adguardhome restart
/etc/init.d/adguardhome enable
EOF
setsid sh /root/simple-apply.sh "$VPN_IF" >/root/simple-apply.log 2>&1 &
```

## 14. Verify

From the new session at `192.168.8.1` (the block derives what it needs from
UCI). Expected values are in the trailing comments.

```sh
: "${VPN_IF:=wgserver}" # set again if you chose a different name
VPN_ADDR=$(uci -q get "network.$VPN_IF.addresses")
cat /root/simple-apply.log
ss -lntu | grep -E ':(53|54|3000)[[:space:]]'
wg show "$VPN_IF"                      # server, public key, listen port; no peers yet
ss -lntu | grep -F "${VPN_ADDR%/*}:53" # AdGuard on the WireGuard server address
uci show firewall.allow_wireguard
uci get network.$VPN_IF # interface (catches a mis-quoted heredoc in section 10)
/etc/init.d/adguardhome enabled && echo 'adguardhome enabled'
fw4 check
uci show network
uci show firewall
uci show dhcp
uci show wireless
uci show wireless | grep -F "ssid='OpenWrt'" # nothing (stock open SSIDs removed)
uci get firewall.defaults.flow_offloading    # 1
uci get firewall.defaults.flow_offloading_hw # 1
grep -x 'options mt7915e wed_enable=Y' /etc/modules.conf
grep -B1 -x 'confdir /var/etc/chrony.d' /etc/chrony/chrony.conf # authselectmode ignore
cat /var/etc/chrony.d/10-uci.conf
uci show chrony # 7 server sections; prefer only on the three NTS sources
uci show adguardhome
grep -E '^(http:|dns:|filters:|querylog:|statistics:)' /etc/adguardhome/adguardhome.yaml
grep -c -- '- enabled: true' /etc/adguardhome/adguardhome.yaml # 26
grep -A7 'bind_hosts:' /etc/adguardhome/adguardhome.yaml       # loopback, the WireGuard server address, plus the four VLAN gateways
uci show uhttpd | grep listen_
nslookup git.homeworld.internal 127.0.0.1 # 192.168.8.50 (AdGuard rewrite)
uci show dropbear           # DirectInterface='pixel', Port 22
uci get network.wan.peerdns # 0
chronyc tracking
chronyc -n selectdata -a
chronyc -N authdata
/etc/init.d/sysntpd enabled >/dev/null 2>&1 && echo 'sysntpd still enabled'
stat -c '%a %n' /etc/config/wireless /etc/modules.conf /etc/chrony/chrony.conf # 600 600 644
logread -e netifd -e firewall -e adguardhome -e dnsmasq -e chronyd -e uhttpd -e dropbear
```

Then confirm from a client in each VLAN: DHCP and DNS work, expected
internet access works, forbidden inter-VLAN routes stay blocked, and
LuCI/SSH answer only on `192.168.8.1` (from Pixel). Guest, IoT, and Things
must not be able to open TCP 22, 80, or 443 on their own gateways.

## 15. Reboot

Wireless Ethernet Dispatch loads only after a reboot. Reboot now that
everything checks out.

```sh
reboot
```

After the reboot, verify WED loaded and time is authenticated:

```sh
cat /sys/module/mt7915e/parameters/wed_enable # Y
: "${VPN_IF:=wgserver}"
wg show "$VPN_IF" # server present after reboot
chronyc tracking
chronyc -N authdata
```

## 16. WireGuard clients (peers)

Each client becomes a `network.wg_<name>` section of type
`wireguard_$VPN_IF` with its public key, preshared key and a `/32` allowed
IP, and gets a ready-to-import configuration file in
`/root/wireguard-clients/`. Clients reach the WireGuard subnet, Pixel
(`192.168.8.0/24`, including the cluster's Gateway VIP `192.168.8.50`, so
every `*.homeworld.internal` service works remotely) and the agents VM
subnet (`10.20.0.0/24`, routed through the Ryzen node, section 17) through
the tunnel; other traffic stays on their own connection. As members of the Pixel zone they get the same DNS policy as
Pixel clients: AdGuard Home on the server address, port-53 interception and
no direct port-54 access.

Because WAN sits behind the ISP router, forward UDP `VPN_PORT` on the ISP
router to `192.168.2.2` (or put the router in the ISP router's DMZ) before
testing from outside.

Prepare once, from the `192.168.8.1` session (edit the endpoint first):

```sh
VPN_ENDPOINT_HOST='vpn.example.com' # public hostname or IPv4 of the ISP router, no port
: "${VPN_IF:=wgserver}"             # set again if you chose a different name
WG_CLIENT_DIR=/root/wireguard-clients
umask 077
cp -p /etc/config/network /root/network-before-peers
VPN_PORT=$(uci get "network.$VPN_IF.listen_port")
VPN_ADDR=$(uci get "network.$VPN_IF.addresses") # one IPv4 /24 address, e.g. 10.10.0.1/24
VPN_PREFIX=${VPN_ADDR%.*}
VPN_SERVER_ADDR=${VPN_ADDR%/*}
CLIENT_ALLOWED_IPS="${VPN_PREFIX}.0/24,192.168.8.0/24,10.20.0.0/24"
SERVER_PUBLIC=$(uci get "network.$VPN_IF.private_key" | wg pubkey)
mkdir -p "$WG_CLIENT_DIR"
chmod 700 "$WG_CLIENT_DIR"
```

Then paste one block per client, editing the first two lines each time:

```sh
peer_name=laptop # unique; letters, digits and underscore only
peer_host=2      # unique host number in the WireGuard /24, not the server's
conf="$WG_CLIENT_DIR/$peer_name.conf"
private_key=$(wg genkey)
preshared_key=$(wg genpsk)
public_key=$(printf '%s' "$private_key" | wg pubkey)
cat >"$conf" <<EOF
[Interface]
PrivateKey = $private_key
Address = ${VPN_PREFIX}.${peer_host}/32
DNS = $VPN_SERVER_ADDR

[Peer]
PublicKey = $SERVER_PUBLIC
PresharedKey = $preshared_key
Endpoint = $VPN_ENDPOINT_HOST:$VPN_PORT
AllowedIPs = $CLIENT_ALLOWED_IPS
PersistentKeepalive = 25
EOF
chmod 600 "$conf"
uci set "network.wg_$peer_name=wireguard_$VPN_IF"
uci set "network.wg_$peer_name.description=$peer_name"
uci set "network.wg_$peer_name.public_key=$public_key"
uci set "network.wg_$peer_name.preshared_key=$preshared_key"
uci add_list "network.wg_$peer_name.allowed_ips=${VPN_PREFIX}.${peer_host}/32"
unset private_key preshared_key public_key
```

After the last client, load them. Restarting the interface briefly removes
the server address, so AdGuard Home is restarted to make sure it listens
there again:

```sh
uci commit network
ifdown "$VPN_IF"
ifup "$VPN_IF"
/etc/init.d/adguardhome restart
sleep 5
wg show "$VPN_IF" peers                  # one public key per client
ss -lntu | grep -F "$VPN_SERVER_ADDR:53" # AdGuard Home on the server address
fw4 check
ls -l "$WG_CLIENT_DIR"                   # one .conf per client, mode 600
```

Copy each `.conf` to its device. For a phone, `apk add qrencode`, then
`qrencode -t ansiutf8 <"$WG_CLIENT_DIR/<name>.conf"` prints a QR code to
scan. The files contain private keys; keep them only as long as needed.

From a connected client, check the handshake and the DNS policy (replace
`10.10.0.1` with your server address):

```sh
ping -c 3 10.10.0.1                   # tunnel up; `wg show` on the router shows a recent handshake
dig @10.10.0.1 openwrt.org +short     # answered by AdGuard Home
dig @192.168.8.254 openwrt.org +short # also answered: intercepted and sent to AdGuard Home
dig @10.10.0.1 git.homeworld.internal +short # 192.168.8.50 (the cluster's Gateway VIP)
dig -p 54 @10.10.0.1 openwrt.org      # must fail: dnsmasq is not reachable directly
```

## 17. Homeworld cluster

Run this once, from the `192.168.8.1` session, before installing the nodes
([docs/k3s.md](k3s.md)). It gives the three nodes and the NAS static leases,
routes the agents VM subnet through the Ryzen node, rejects that subnet
everywhere but the internet, and runs the Tang server the nodes' LUKS roots
are bound to ([docs/fedora.md](fedora.md)).

The Pixel DHCP pool is `192.168.8.100`–`.249` (section 3), so every address
below `.100` stays unassigned unless a lease names it. The two cluster
virtual IPs need no router configuration beyond staying out of every lease:
`192.168.8.50` (Gateway VIP, answered by Cilium) and `192.168.8.51`
(Kubernetes API VIP, answered by kube-vip). The node-to-address assignment
may change; keep every address below `.100`, and update `host/cluster.env`
in git if the NAS or a VIP moves.

```sh
# MAC address of each machine's LAN port (`ip link` on the machine, or the
# DHCP lease list in LuCI).
RYZEN_MAC='aa:bb:cc:dd:ee:10'
COREBOX_MAC='aa:bb:cc:dd:ee:11'
RADXA_MAC='aa:bb:cc:dd:ee:12'
NAS_MAC='aa:bb:cc:dd:ee:20'

uci -q batch <<EOF
set dhcp.ryzen='host'
set dhcp.ryzen.name='ryzen'
set dhcp.ryzen.mac='$RYZEN_MAC'
set dhcp.ryzen.ip='192.168.8.10'
set dhcp.corebox='host'
set dhcp.corebox.name='corebox'
set dhcp.corebox.mac='$COREBOX_MAC'
set dhcp.corebox.ip='192.168.8.11'
set dhcp.radxa='host'
set dhcp.radxa.name='radxa'
set dhcp.radxa.mac='$RADXA_MAC'
set dhcp.radxa.ip='192.168.8.12'
set dhcp.nas='host'
set dhcp.nas.name='nas'
set dhcp.nas.mac='$NAS_MAC'
set dhcp.nas.ip='192.168.8.20'

set network.agents='route'
set network.agents.interface='pixel'
set network.agents.target='10.20.0.0/24'
set network.agents.gateway='192.168.8.10'

set firewall.reject_agents_input='rule'
set firewall.reject_agents_input.name='Reject-Agents-Input'
set firewall.reject_agents_input.src='pixel'
set firewall.reject_agents_input.src_ip='10.20.0.0/24'
set firewall.reject_agents_input.family='ipv4'
set firewall.reject_agents_input.proto='all'
set firewall.reject_agents_input.target='REJECT'
set firewall.reject_agents_local='rule'
set firewall.reject_agents_local.name='Reject-Agents-Local'
set firewall.reject_agents_local.src='pixel'
set firewall.reject_agents_local.src_ip='10.20.0.0/24'
set firewall.reject_agents_local.dest='*'
add_list firewall.reject_agents_local.dest_ip='10.0.0.0/8'
add_list firewall.reject_agents_local.dest_ip='172.16.0.0/12'
add_list firewall.reject_agents_local.dest_ip='192.168.0.0/16'
add_list firewall.reject_agents_local.dest_ip='100.64.0.0/10'
add_list firewall.reject_agents_local.dest_ip='169.254.0.0/16'
add_list firewall.reject_agents_local.dest_ip='224.0.0.0/4'
set firewall.reject_agents_local.family='ipv4'
set firewall.reject_agents_local.proto='all'
set firewall.reject_agents_local.target='REJECT'
EOF
uci commit dhcp
uci commit network
uci commit firewall

# Tang (LUKS network unlock). The package generates its key pair on first
# start in /usr/share/tang/db.
apk add tang
uci set tang.config=tang
uci set tang.config.enabled='1'
uci set tang.config.port='7500'
uci commit tang
/etc/init.d/tang enable
/etc/init.d/tang start

/etc/init.d/dnsmasq restart
/etc/init.d/network reload
fw4 check && fw4 reload
```

The route sends LAN and WireGuard traffic for `10.20.0.0/24` to the Ryzen
node, which runs the VM on a routed libvirt network
([docs/openchamber.md](openchamber.md)). The two reject rules are defense in
depth behind the Ryzen's firewalld, which already confines the VM to the
internet: the VM may not open connections to the router or to any private,
CGNAT, link-local or multicast address through it. Replies to LAN and
WireGuard clients are established traffic and pass before these rules.

Verify:

```sh
uci show dhcp | grep -E '^dhcp\.(ryzen|corebox|radxa|nas)\.'
ip route show 10.20.0.0/24             # via 192.168.8.10
fw4 print | grep -F 10.20.0.0/24       # the two reject rules
ss -lnt | grep -F ':7500'              # tangd
tang-show-keys 7500                    # the thumbprint bootstrap.sh asks you to compare
```

Back up `/usr/share/tang/db` offline, together with the nodes' LUKS recovery
passphrases and header backups ([docs/fedora.md](fedora.md)), and never only
in Vaultwarden: the cluster that runs Vaultwarden cannot boot unattended
without these keys. The sysupgrade backup keeps them too (the package marks
the directory as configuration).

LAN clients reach the VM asymmetrically: their packets go through the router
(their default gateway) and the route above, while the VM's replies go from
the Ryzen straight back on the LAN. WireGuard clients are symmetric. From a
Pixel client, connect to `10.20.0.10:6767` (Paseo) directly; if the
connection stalls after the handshake, check `logread -e firewall` for
invalid-state drops.

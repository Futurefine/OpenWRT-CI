#!/bin/bash
# SPDX-License-Identifier: MIT
#
# 雅典娜（JDCloud RE-CS-02 / AX6600）私有扩展
# 作用：把「三路射频分工 + 无线中继」预置进固件，重刷/工厂重置后自动恢复
#
# 谁来调用：Scripts/Packages.sh 末尾
#     if [ -f "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh" ]; then
#         source "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh"
#     fi
# 工作目录：已克隆好的构建树 ./wrt/（所以下面的相对路径都相对构建树根）
#
# 为什么这样写一定能进镜像：
#   package/base-files/Makefile 的 install 段第一行就是
#       $(CP) ./files/* $(1)/
#   即 package/base-files/files/ 下的一切都会原样进 rootfs。所以把配置写到
#   ./package/base-files/files/etc/config/wireless 就等于写进了固件的 /etc/config/wireless。
#
# 为什么预置的配置不会被首次启动的自动探测冲掉：
#   首启时 /etc/hotplug.d/ieee80211/10-wifi-detect 会执行 `wifi config`，
#   它跑 /lib/wifi/mac80211.uc —— 该脚本对每个检测到的射频先做 radio_exists()，
#   按 path 后缀匹配，命中就 continue（连默认 AP 都不再生成）。
#   所以只要三个 radio 的 path 写对，整份配置原样保留。
#
# 由 workflow 变量提供（不在这里写死）：
#   WRT_SSID -> AP 名称前缀      WRT_WORD -> 三个 AP 的口令
#   WRT_NAME -> 主机名          WRT_IP   -> LAN 地址

set -e

# ══════════════════════════════════════════════════════════════════════
#  需要你确认的项：只有下面两行
# ══════════════════════════════════════════════════════════════════════
UPSTREAM_SSID='CU_Adeb_5G'   # 上游 WiFi 名称，区分大小写
UPSTREAM_KEY=''              # ← 上游 WiFi 口令。留空 = 中继客户端建好但保持停用
# ══════════════════════════════════════════════════════════════════════
#  UPSTREAM_KEY 留空时：固件烧好后 /etc/config/wireless 里会有 wifinet2 这个
#  STA 接口，但 disabled='1'。到 LuCI（网络 → 无线 → radio2 的客户端）填入口令
#  并启用即可，或直接执行：
#     uci set wireless.wifinet2.key='上游口令'
#     uci set wireless.wifinet2.disabled='0'
#     uci commit wireless && wifi reload
# ══════════════════════════════════════════════════════════════════════

AP58="${WRT_SSID}-5.8G"
AP24="${WRT_SSID}-2.4G"
AP52="${WRT_SSID}-5.2G"

WIRELESS="./package/base-files/files/etc/config/wireless"
UCI_DEFAULTS="./package/base-files/files/etc/uci-defaults/90-athena-relay"

# ── 取值校验 ───────────────────────────────────────────────────────────
# uci 配置用单引号包值，heredoc 里反引号/反斜杠会被 shell 处理，
# 这三类字符会破坏生成的文件，宁可早失败也不要烧出一个坏固件。
check_val() {
	case "$2" in
		*"'"*|*'`'*|*'\'*)
			echo "" >&2
			echo "ERROR: $1 含有单引号 / 反引号 / 反斜杠，无法安全写入 uci 配置。" >&2
			echo "       请换成不含这三类字符的值；或把该项留空、烧好后到 LuCI 里填。" >&2
			echo "" >&2
			exit 1
			;;
	esac
	if [ -z "$2" ]; then
		echo "" >&2
		echo "ERROR: $1 为空。" >&2
		echo "" >&2
		exit 1
	fi
}

check_val "WRT_SSID"      "$WRT_SSID"
check_val "WRT_WORD"      "$WRT_WORD"
check_val "UPSTREAM_SSID" "$UPSTREAM_SSID"

if [ -n "$UPSTREAM_KEY" ]; then
	check_val "UPSTREAM_KEY" "$UPSTREAM_KEY"
	STA_DISABLED='0'
	STA_NOTE="中继客户端已启用"
else
	STA_DISABLED='1'
	STA_NOTE="中继客户端已建好但停用（UPSTREAM_KEY 为空）"
fi

# ── 1) 预置 /etc/config/wireless ───────────────────────────────────────
# 三路射频的分工，与 2026-10-16 实测可用状态一致：
#   radio0 集成 5G (2x2)  ch149 HE80  23dBm -> AP  OWRT-5.8G  （纯下行，主力覆盖）
#   radio1 集成 2.4G      ch6   HE20  20dBm -> AP  OWRT-2.4G
#   radio2 QCN9074 (4x4)  ch36  VHT80       -> STA 上行 + AP OWRT-5.2G（同信道半双工）
#
# 频段互斥是硬约束（设备树 ieee80211-freq-limit）：
#   phy0 只能用 ch100-144 / ch149-169；phy2 只能用 ch36-64。
#   上游在 ch36，所以上行只能挂在 radio2 上，没得选。
#
# 关于 radio2 的 htmode：现网跑的是 VHT80，这里就照抄 VHT80。
# 想换成 HE80（5.2G 那个 AP 就有 11ax，11ac 客户端仍可连）把下行改成 HE80 即可，
# 两种都不会踩进 5250-5350 的 DFS 段。注意必须是 80 —— ch36+HE160 会跨进 DFS，
# radar_required 置位后 mac80211 会拒绝扫描，报 Resource busy (-16)。
mkdir -p "$(dirname "$WIRELESS")"
cat > "$WIRELESS" <<EOF
config wifi-device 'radio0'
	option type 'mac80211'
	option path 'platform/soc@0/c000000.wifi'
	option band '5g'
	option channel '149'
	option htmode 'HE80'
	option country 'US'
	option txpower '23'
	option cell_density '0'
	option disabled '0'

config wifi-iface 'default_radio0'
	option device 'radio0'
	option network 'lan'
	option mode 'ap'
	option ssid '$AP58'
	option encryption 'psk2+ccmp'
	option key '$WRT_WORD'
	option disabled '0'

config wifi-device 'radio1'
	option type 'mac80211'
	option path 'platform/soc@0/c000000.wifi+1'
	option band '2g'
	option channel '6'
	option htmode 'HE20'
	option country 'US'
	option txpower '20'
	option cell_density '0'
	option disabled '0'

config wifi-iface 'default_radio1'
	option device 'radio1'
	option network 'lan'
	option mode 'ap'
	option ssid '$AP24'
	option encryption 'psk2+ccmp'
	option key '$WRT_WORD'
	option disabled '0'

config wifi-device 'radio2'
	option type 'mac80211'
	option path 'soc@0/20000000.pcie/pci0000:00/0000:00:00.0/0000:01:00.0'
	option band '5g'
	option channel '36'
	option htmode 'VHT80'
	option country 'US'
	option cell_density '0'
	option disabled '0'

config wifi-iface 'wifinet2'
	option device 'radio2'
	option mode 'sta'
	option network 'wwan'
	option ssid '$UPSTREAM_SSID'
	option encryption 'psk2+ccmp'
EOF

# 上游口令留空时不写 key 选项（uci 不接受空值），只把接口停用。
# 这样固件里能看到这个客户端接口，填入口令再启用即可，也不会刷报错日志。
if [ -n "$UPSTREAM_KEY" ]; then
	echo "	option key '$UPSTREAM_KEY'" >> "$WIRELESS"
fi

cat >> "$WIRELESS" <<EOF
	option disabled '$STA_DISABLED'

config wifi-iface 'ap52'
	option device 'radio2'
	option mode 'ap'
	option network 'lan'
	option ssid '$AP52'
	option encryption 'psk2+ccmp'
	option key '$WRT_WORD'
	option disabled '0'
EOF

# ── 2) 预置 uci-defaults：wwan 逻辑接口 + 防火墙归入 wan 区 ────────────
# 这两项用增量方式做，不整份替换 network/firewall，
# 以免覆盖掉上游默认值、以及 homeproxy / router-role 等包自动维护的段。
mkdir -p "$(dirname "$UCI_DEFAULTS")"
cat > "$UCI_DEFAULTS" <<'EOF'
#!/bin/sh
# 无线中继收尾：新增 wwan 逻辑接口，并把 wwan 并入 wan 防火墙区域。
# 只做增量 uci 修改。首次启动执行一次后本脚本会被自动删除。

# 无线上行用 DHCP 从上游取地址
uci -q set network.wwan=interface
uci -q set network.wwan.proto='dhcp'
uci -q commit network

# 把 wwan 加进 wan 区（该区名下有 masq='1'，NAT 因此生效）
# 匿名段与命名段都兼容
WAN_ZONE=$(uci show firewall | sed -n "s/^\(firewall\.[^.]*\)\.name='wan'$/\1/p" | head -n1)
if [ -n "$WAN_ZONE" ]; then
	uci -q add_list "$WAN_ZONE.network='wwan'"
	uci -q commit firewall
fi

# NAT 规则的实际补挂由 /etc/hotplug.d/iface/20-firewall 在接口上线时完成，
# 不需要额外脚本。

exit 0
EOF
chmod +x "$UCI_DEFAULTS"

# ── 构建日志里留一份可核对的痕迹 ───────────────────────────────────────
echo ""
echo "=============================================================="
echo " athena-relay: 中继配置已预置进本次固件"
echo "--------------------------------------------------------------"
echo " /etc/config/wireless        <- $WIRELESS"
echo "   radio0  AP  $AP58   ch149 / HE80 / 23dBm"
echo "   radio1  AP  $AP24   ch6   / HE20 / 20dBm"
echo "   radio2  AP  $AP52   ch36  / VHT80   +  STA 上行"
echo "   STA 目标 $UPSTREAM_SSID   $STA_NOTE"
echo " /etc/uci-defaults/90-athena-relay <- $UCI_DEFAULTS"
echo "   network.wwan (dhcp) + firewall wan 区加入 wwan"
echo " AP 口令取自 WRT_WORD；主机名 WRT_NAME；LAN WRT_IP"
echo "=============================================================="
echo ""

# sysupgrade 生成配置备份时会被自动 source（/lib/upgrade/*.sh）。
#
# 作用：把「用户自己 apk add 装上的包」清单加进备份，升级后由
# /etc/init.d/dream-restore-packages 自动重装。
#
# 为什么不用上游的 sysupgrade -k：它只把清单写进备份，不会重装；而且
# LuCI 网页升级根本不带 -k。这里走 sysupgrade_init_conffiles 钩子，
# 在生成备份那一刻现场扫描，保证清单是升级前的最新状态。
#
# 注意：这个钩子只在「新固件已经在跑」之后的升级才存在。从老固件第一次
# 升级过来时，手动执行一次 /usr/sbin/dream-pkg-list 再升级即可兜底。

dream_extra_packages_conffiles() {
	local filelist="$1"
	local list=/etc/dream-extra-packages

	# 即便清单生成失败也不能阻断升级，配置备份比后装包重要得多。
	/usr/sbin/dream-pkg-list || logger -t dream-pkg-list "生成清单失败，本次升级不重装后装包"

	# 追加而非覆盖：build_list_of_backup_config_files 先写好备份清单，
	# 后面的钩子都往同一个文件追加（LuCI 的 add_luci_conffiles 也是这么做的）。
	# 该路径同时列在 /etc/sysupgrade.conf 里，清单已存在时会被 find 收进去，
	# 所以这里要判重，别让 tar 打进两份同名条目。
	if [ -f "$list" ] && ! grep -qxF "$list" "$filelist"; then
		echo "$list" >> "$filelist"
	fi
	return 0
}

sysupgrade_init_conffiles="$sysupgrade_init_conffiles dream_extra_packages_conffiles"

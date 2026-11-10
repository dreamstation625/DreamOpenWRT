'use strict';
'require view';
'require fs';
'require ui';

var RULES_FILE = '/usr/share/nftables.d/chain-pre/mangle_prerouting/99-custom.nft';

return view.extend({
	load: function() {
		return fs.read(RULES_FILE).catch(function() {
			return '';
		});
	},

	render: function(content) {
		var textarea = E('textarea', {
			'class': 'cbi-input-textarea',
			'style': 'width:100%; min-height:380px; font-family:monospace',
			'spellcheck': 'false',
			'wrap': 'off'
		}, [ content || '' ]);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ _('防火墙 - 自定义规则') ]),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('这里写 fw4 的 mangle_prerouting 规则表达式，不要写 nft add rule。保存后立即重载 firewall。')
			]),
			E('div', { 'class': 'cbi-section' }, [ textarea ])
		]);
	},

	handleSaveApply: null,
	handleReset: null,

	handleSave: function() {
		var textarea = document.querySelector('textarea.cbi-input-textarea');
		var data = textarea ? textarea.value : '';

		return fs.write(RULES_FILE, data).then(function() {
			return fs.exec('/etc/init.d/firewall', [ 'reload' ]).catch(function() {});
		}).then(function() {
			ui.addNotification(null, E('p', {}, [ _('自定义规则已保存并生效。') ]), 'info');
		}).catch(function(err) {
			ui.addNotification(null, E('p', {}, [ _('保存失败：') + err ]), 'error');
		});
	}
});

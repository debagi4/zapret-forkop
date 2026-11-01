'use strict';
'require view';
'require form';
'require uci';
'require ui';

function outboundJSON(section_id) {
	var n = +uci.get('zapret_forkop', section_id, 'slot');
	if (!Number.isInteger(n) || n < 1 || n > 254)
		return null;
	return JSON.stringify({ type: 'socks', tag: 'Zapret-' + n, server: '127.0.0.1',
		server_port: 11079 + n, version: '5' });
}

function copyText(text) {
	if (navigator.clipboard && window.isSecureContext)
		return navigator.clipboard.writeText(text);

	// LuCI is often served over HTTP, where the Clipboard API is unavailable.
	var input = document.createElement('textarea');
	input.value = text;
	input.style.position = 'fixed';
	input.style.left = '-9999px';
	document.body.appendChild(input);
	input.select();
	try {
		return document.execCommand('copy') ? Promise.resolve() : Promise.reject();
	}
	catch (e) {
		return Promise.reject(e);
	}
	finally {
		input.remove();
	}
}

return view.extend({
	load: function() {
		return uci.load('zapret_forkop');
	},

	render: function() {
		var map = new form.Map('zapret_forkop',
			_('Zapret for Forkop'),
			_('Configure Zapret profiles here, then choose which traffic uses them in Forkop.'));
		var s = map.section(form.GridSection, 'profile', _('Profiles'));
		s.anonymous = true;
		s.addremove = true;

		var enabled = s.option(form.Flag, 'enabled', _('Enabled'));
		enabled.default = '0';
		enabled.rmempty = false;

		var name = s.option(form.Value, 'name', _('Name'));
		name.rmempty = false;
		name.datatype = 'maxlength(48)';

		var slot = s.option(form.Value, 'slot', _('Profile number'));
		slot.datatype = 'range(1,254)';
		slot.rmempty = false;
		slot.description = _('Each profile must have a unique number. SOCKS port: 11079 + number; queue: 4399 + number.');
		slot.validate = function(section_id, value) {
			for (var section of uci.sections('zapret_forkop', 'profile')) {
				if (section['.name'] !== section_id && section.slot === value)
					return _('Profile numbers must be unique.');
			}
			return true;
		};

		var strategy = s.option(form.TextValue, 'strategy', _('Zapret 1 strategy'));
		strategy.rows = 8;
		strategy.wrap = true;
		strategy.renderWidget = function(section_id, option_index, cfgvalue) {
			var widget = form.TextValue.prototype.renderWidget.call(this, section_id, option_index, cfgvalue);
			widget.querySelector('textarea').style.resize = 'vertical';
			return widget;
		};
		strategy.rmempty = false;
		strategy.modalonly = true;
		strategy.description = _('Arguments for nfqws. Queue and firewall mark are assigned by the service; do not include --qnum or --dpi-desync-fwmark.');
		strategy.validate = function(section_id, value) {
			var args = (value || '').trim().split(/\s+/);
			var reserved = [ '--qnum', '--dpi-desync-fwmark', '--dry-run', '--version',
				'--daemon', '--pidfile', '--user', '--uid' ];
			for (var arg of args) {
				if (!arg.startsWith('--') || /["'\\`]/.test(arg))
					return _('Use unquoted --option or --option=value arguments only.');
				if (reserved.indexOf(arg.split('=')[0]) !== -1)
					return _('Queue, mark and service options are managed automatically.');
			}
			return true;
		};

		var outbound = s.option(form.DummyValue, '_outbound', _('Forkop SOCKS outbound JSON'));
		outbound.modalonly = true;
		outbound.cfgvalue = function(section_id) {
			return outboundJSON(section_id) || _('Save a valid profile number first.');
		};
		outbound.description = _('Use this JSON as the outbound in a Forkop section. The profile number must be saved first.');

		var copy = s.option(form.Button, '_copy_outbound', _('Forkop config'));
		copy.inputtitle = _('Copy');
		copy.inputstyle = 'action';
		copy.modalonly = false;
		copy.textvalue = function(section_id) {
			return E('button', {
				'type': 'button',
				'class': 'cbi-button cbi-button-action',
				'click': function(ev) { return copy.onclick(ev, section_id); }
			}, _('Copy'));
		};
		copy.onclick = function(ev, section_id) {
			var value = outboundJSON(section_id);
			if (!value) {
				ui.addNotification(null, E('p', _('Save a valid profile number first.')), 'warning');
				return;
			}
			return copyText(value).then(function() {
				ui.addTimeLimitedNotification(null, E('p', _('Forkop config copied.')), 3000, 'info');
			}, function() {
				ui.addNotification(null, E('p', _('Could not copy. Open the profile and copy the JSON manually.')), 'warning');
			});
		};
		return map.render();
	}
});

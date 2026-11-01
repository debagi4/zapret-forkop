'use strict';
const fs = require('fs');
const assert = require('assert');
const sections = [];
const values = { p1: '1', p2: '2' };
const uci = { load: () => Promise.resolve(), get: (_, id, key) => key === 'slot' ? values[id] : undefined, sections: () => [] };
const section = { option: (_, name) => { const o = { option: name }; sections.push(o); return o; } };
const form = {
	Map: function() { this.section = () => section; this.render = () => null; },
	GridSection: {}, Flag: {}, Value: {}, TextValue: {}, DummyValue: {}
};
const view = { extend: (definition) => definition };
const src = fs.readFileSync('openwrt/htdocs/luci-static/resources/view/zapret-forkop/profiles.js', 'utf8');
const instance = new Function('view', 'form', 'uci', '_', src)(view, form, uci, x => x);
instance.render();
const opt = sections.find(x => x.option === '_outbound');
assert.deepStrictEqual(JSON.parse(opt.cfgvalue('p1')), { type: 'socks', tag: 'Zapret-1', server: '127.0.0.1', server_port: 11080, version: '5' });
assert.deepStrictEqual(JSON.parse(opt.cfgvalue('p2')), { type: 'socks', tag: 'Zapret-2', server: '127.0.0.1', server_port: 11081, version: '5' });
assert.strictEqual(opt.cfgvalue('missing'), 'Save a valid profile number first.');

const slot = sections.find(x => x.option === 'slot');
for (const value of ['1', '42', '254'])
	assert.strictEqual(slot.validate('p1', value), true, value);
for (const value of ['01', '007', '', '1.0'])
	assert.notStrictEqual(slot.validate('p1', value), true, value);

// The UI must reject exactly what the service-side preparation rejects.
const prepare = fs.readFileSync('openwrt/root/usr/libexec/zapret-forkop-prepare', 'utf8');
const reserved = prepare.match(/^\s*(--qnum\|[^)]*)\)/m)[1].split('|');
assert.ok(reserved.length >= 8);
const strategy = sections.find(x => x.option === 'strategy');
assert.strictEqual(strategy.validate('p1', '--filter-tcp=443 --dpi-desync=fake'), true);
for (const option of reserved) {
	assert.notStrictEqual(strategy.validate('p1', '--filter-tcp=443 ' + option), true, option);
	assert.notStrictEqual(strategy.validate('p1', option + '=1'), true, option);
}
console.log('LuCI outbound JSON, slot and strategy tests passed');

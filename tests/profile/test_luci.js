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
console.log('LuCI outbound JSON tests passed');

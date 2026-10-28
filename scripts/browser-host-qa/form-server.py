#!/usr/bin/env python3
"""Loopback-only pages for browser panel QA: the QA page at / (keys, composition, find, tooltip,
dialogs, file input, drop zone, download link), /second, /download (an attachment),
/animation (a page that repaints every frame), /a11y (landmarks, headings, form controls, list,
table, image, iframe, a positioned button and one far down the page), /large (a page with
thousands of accessibility nodes), and for page load errors /slow?ms=N (answers after N ms),
/slow-redirect (redirects to /second after 1.5 s), /spa (moves with history.pushState) and
/no-content (204), and for a page that stops responding /busy (#loop holds the main thread for
?ms=N milliseconds when clicked, or for good with ms=0), and for the caret and keys /login (a text
and a password field, large and empty so the caret's pixels can be found; it records how old each
input event is and moves as an SPA does, by pushState, after a click on #go or Enter in #pass;
?autofocus=<id> gives that field autofocus, and window.__restored says whether it came back from the
back-forward cache), /login-frame?src=<url> (that page in a frame at the top
left), and for the vault for agents /vault/login (a sign-in form), /vault/get and /vault/elsewhere (sign-ins that would
send the password where it does not belong, VAULT_GET below), /vault/react (fields kept the way React keeps
controlled inputs), /vault/otp (a one-time code field and six one-digit boxes, checked against RFC 6238's
test key in the page), /vault/otp/setup (a site's two-factor setup: a QR code of an otpauth:// address and a
field for the first code, checked against the QR code's test key), /vault/otp/export (a picture of Google
Authenticator's export QR code with two TOTP accounts and one counter-based one, all test keys), /isolation (a blank page whose cookies and localStorage the QA reads and sets), /vault/reveal (a password field with a show button), /vault/step (a first step with the email only), /vault/signup (a
sign-up form whose new password and confirmation fields carry passwordrules), /vault/change (a password change form for
person@example.test: current, new and confirmation fields, none marked, the current one told apart by its label) and /vault/webauthn (a blank
page for WebAuthn on localhost), /passkey (a sign-in form with passkey autofill and the passkey requests sites
make, started by window.passkey(kind)), for what ordinary sites ask of a browser /compat (window.compat(kind)
starts each request and window.qa.compat says how it ended; links to other apps' addresses, mailto:, tel: and one
no app opens; a wallet button shown only with the Payment Request API; /compat/frame is its cross-site frame,
loaded from localhost), /basic-auth (HTTP Basic authentication, user qa and password secret), /compat/doc.pdf (a one-page
PDF) and the same pages over HTTPS with a self-signed certificate on a second port, for the full-page screenshot /tall (the window scrolls: a header,
a 100vh band, five sections and a footer, each its own color, 4086 px tall in an 800 px viewport), and for a
card checkout /checkout (a card form posting to /checkout/done), /checkout/address (a shipping address form),
/checkout/wallet (a wallet button's Payment Request) and the card issuer's check (3-D Secure) on another port
reached as localhost, another site: /checkout/frame (in frames, posting to the issuer and back), /checkout/redirect
(the whole page posts to the issuer and back) and /checkout/popup (a new window that answers window.opener), and
a sign-in's cookie check across two sites, /cookie-check/start (COOKIE_SIGN_IN below), for picking an element
/pick (PICK below), and for the agent's browser use /viewport (what the page sees of its screen size, device and color
scheme, and a tap target), /frames (an open and a closed shadow root, a frame from this site and one from another that
holds a frame from this site again) and /handoff (a check only the person passes).
Each records what the page received in window.qa."""
import time
import argparse
import base64
import ssl
import subprocess
import threading
import html
import json
from urllib.parse import parse_qs, unquote
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output-dir', required=True, type=Path)
parser.add_argument('--port', type=int, default=0)
args = parser.parse_args()
args.output_dir.mkdir(parents=True, exist_ok=True)

# Picking an element for the composer: a button deep in a card (no id, two classes, a sibling of the
# same kind), a counter whose clicks show whether the page or the picker took them, and a form whose
# fields the QA fills (typed values, a hidden token, a password and a value the vault "filled" shown as
# text), none of which may leave in the element's context or show in its capture.
PICK = '''<!doctype html>
<html lang="en"><meta charset="utf-8"><title>Pick</title>
<style>
  body { font: 15px -apple-system, system-ui, sans-serif; margin: 24px; background: #fff; color: #222; }
  main { display: flex; flex-direction: column; gap: 16px; max-width: 520px; }
  section.card { padding: 12px 16px; border: 1px solid #ccd; border-radius: 8px; }
  button.primary { background: #1a73e8; color: #fff; border: 0; border-radius: 6px; padding: 10px 22px; font: inherit; }
  form { display: grid; gap: 8px; padding: 12px; border: 1px solid #ccd; border-radius: 8px; }
  input, textarea { font: 16px -apple-system, system-ui, sans-serif; padding: 8px; border: 1px solid #999; border-radius: 4px;
    background: #fff; color: #000; }
</style>
<main>
  <section class="card"><h2>First</h2><button class="primary">Other</button></section>
  <section class="card"><h2>Second</h2><button class="primary large" data-qa="target">Save changes</button>
    <button id="count" onclick="window.qa.clicks++">Count</button></section>
  <form id="account" onsubmit="return false">
    <input id="name" name="name">
    <input id="pw" type="password" name="pw">
    <input type="hidden" name="csrf" value="csrf-hidden-3">
    <textarea id="notes" name="notes">default-note-5</textarea>
    <span id="reveal"></span>
  </form>
</main>
<script>window.qa = {clicks: 0};</script>
</html>'''

# The full-page screenshot's page: bands of known height and color, so a capture shows whether each
# comes once and in order. window.qa.resizes counts the page's resize events.
TALL = '''<!doctype html>
<html><meta charset="utf-8"><title>Tall</title>
<script>window.qa = {resizes: 0}; addEventListener('resize', () => window.qa.resizes++)</script>
<style>
  body { margin: 0; font: 40px -apple-system, sans-serif; }
  body > * { display: flex; align-items: center; justify-content: center; }
  header { height: 120px; background: rgb(34, 34, 68); color: white; }
  .hero { height: 100vh; background: rgb(255, 102, 221); }
  section { height: 600px; }
  footer { height: 166px; background: rgb(32, 128, 64); color: white; }
</style>
<header>Header</header>
<div class="hero">100vh</div>
<section style="background: rgb(224, 64, 64)">Section 1</section>
<section style="background: rgb(64, 192, 64)">Section 2</section>
<section style="background: rgb(64, 64, 224)">Section 3</section>
<section style="background: rgb(224, 192, 32)">Section 4</section>
<section style="background: rgb(32, 192, 192)">Section 5</section>
<footer>Footer</footer>
</html>'''

PAGE = '''<!doctype html>
<html lang="ko"><meta charset="utf-8"><title>Browser QA</title>
<style>
body{font:16px -apple-system,system-ui;margin:24px;background:#faf9f6;color:#30332f}
input{font:inherit;padding:8px;width:70%}button{font:inherit;padding:6px 12px}
#drop{margin:12px 0;padding:18px;border:2px dashed #999}
</style>
<h1>Browser QA</h1>
<p><label for="name">Name</label> <input id="name" placeholder="Enter your name" autocomplete="off"></p>
<p>needle one, needle two, <span id="tip" title="Tooltip text">needle three (hover for a tooltip)</span></p>
<p><button id="arm-unload" type="button">Ask before leaving</button>
<a id="download" href="/download">Download a file</a> <a href="/second">Second page</a>
<a id="blank-link" href="/second" target="_blank">Open in a new window</a></p>
<p><input id="file" type="file"></p>
<div id="drop">Drop a file here</div>
<select id="color"><option>Red</option><option>Green</option><option>Blue</option></select>
<script>
window.qa = {keys: []};
const field = document.getElementById('name');
field.addEventListener('keydown', e => window.qa.keys.push(`${e.key}/${e.code}/${e.keyCode}`));
for (const type of ['compositionstart', 'compositionupdate', 'compositionend']) {
  field.addEventListener(type, e => console.log(type, e.data));
}
document.getElementById('arm-unload').addEventListener('click', () => {
  window.onbeforeunload = e => { e.preventDefault(); e.returnValue = ''; };
});
const drop = document.getElementById('drop');
drop.addEventListener('dragover', e => e.preventDefault());
drop.addEventListener('drop', e => {
  e.preventDefault();
  const file = e.dataTransfer.files[0];
  window.qa.dropped = file ? `${file.name}:${file.size}` : 'none';
});
</script>
</html>'''

SECOND = '''<!doctype html><meta charset="utf-8"><title>Second</title><link rel="icon" href="/icon-blue.png"><h1>Second page</h1>
<a href="/">Back to the QA page</a>'''

ANIMATION = '''<!doctype html>
<html><meta charset="utf-8"><title>Animation</title>
<style>#box{width:120px;height:120px;background:#3b6fd8;border-radius:12px;will-change:transform}</style>
<h1>Animation</h1><div id="frames">0</div><div id="box"></div>
<script>
let frames = 0;
function tick(time) {
  frames += 1;
  document.getElementById('frames').textContent = frames;
  document.getElementById('box').style.transform = `translateX(${(time / 4) % 300}px) rotate(${time / 10}deg)`;
  requestAnimationFrame(tick);
}
requestAnimationFrame(tick);
</script>
</html>'''


ACCESSIBILITY = """<!doctype html>
<html lang="en"><meta charset="utf-8"><title>Accessibility QA</title><link rel="icon" href="/icon-green.png">
<style>
body{font:16px -apple-system,system-ui;margin:0;padding:24px;background:#fff;color:#222}
#box{position:absolute;left:400px;top:120px;width:200px;height:40px;margin:0;padding:0;border:0;background:#dde}
iframe{width:320px;height:80px;border:1px solid #999}
</style>
<header><nav aria-label="Primary"><a id="link" href="/second">Second page</a> <a href="#bottom">Jump down</a></nav></header>
<main>
<h1>Accessibility QA</h1>
<button type="button" id="box">Positioned box</button>
<h2>Form</h2>
<form onsubmit="return false">
<p><label for="email">Email</label> <input id="email" type="email" placeholder="you@example.com"></p>
<p><label><input id="agree" type="checkbox"> I agree</label></p>
<fieldset><legend>Size</legend>
<label><input type="radio" name="size" id="small" checked> Small</label>
<label><input type="radio" name="size" id="big"> Large</label></fieldset>
<p><label for="fruit">Fruit</label> <select id="fruit"><option>Apple</option><option>Banana</option><option>Cherry</option></select></p>
<p><label for="notes">Notes</label> <textarea id="notes"></textarea></p>
<p><button type="button" id="press">Press me</button> Presses: <span id="count">0</span></p>
</form>
<h2>List</h2>
<ul id="list"><li>First item</li><li>Second <a href="/second">item link</a></li><li>Third item</li></ul>
<h2>Table</h2>
<table id="table"><caption>Scores</caption>
<thead><tr><th>Name</th><th>Score</th></tr></thead>
<tbody><tr><td>Kim</td><td>90</td></tr><tr><td>Lee</td><td>85</td></tr></tbody></table>
<p><img id="logo" alt="Yardlet logo" width="40" height="40"
 src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='40' height='40'%3E%3Crect width='40' height='40' fill='%233b6fd8'/%3E%3C/svg%3E"></p>
<iframe id="frame" title="Embedded frame" srcdoc="<button id='inner' style='margin:10px'>Inner button</button>"></iframe>
<div style="height:1600px"></div>
<button type="button" id="bottom">Bottom button</button>
</main>
<script>
window.qa = {presses: 0, inputs: 0, changes: 0};
document.getElementById('press').addEventListener('click', () => {
  window.qa.presses += 1;
  document.getElementById('count').textContent = String(window.qa.presses);
});
document.getElementById('email').addEventListener('input', () => window.qa.inputs += 1);
document.getElementById('fruit').addEventListener('change', () => window.qa.changes += 1);
</script>
</html>"""


def large_page():
    rows = ''.join(f'<tr><td>Row {i}</td><td>{i * 3}</td><td><a href="/second?r={i}">Open {i}</a></td>'
                   f'<td><input type="checkbox" aria-label="Pick {i}"></td></tr>' for i in range(500))
    items = ''.join(f'<li><a href="/second?i={i}">Item {i}</a> with some text about item {i}.</li>'
                    for i in range(2000))
    paragraphs = ''.join(f'<p>Paragraph {i}: the quick brown fox jumps over the lazy dog, '
                         f'again and again, line after line of ordinary page text.</p>' for i in range(500))
    return f"""<!doctype html><html lang="en"><meta charset="utf-8"><title>Large page</title>
<h1>Large page</h1><table><thead><tr><th>Name</th><th>Value</th><th>Link</th><th>Pick</th></tr></thead>
<tbody>{rows}</tbody></table><ul>{items}</ul>{paragraphs}<button id="last">Last button</button></html>"""


SPA = '''<!doctype html><meta charset="utf-8"><title>SPA</title><h1 id="where">SPA home</h1>
<a id="push" href="/spa/b" onclick="event.preventDefault(); history.pushState({}, '', '/spa/b');
document.querySelector('#where').textContent = 'SPA b'">Go to b</a>
<a id="no-content" href="/no-content">No content</a> <a id="scheme" href="x-yardlet-qa://open">Other scheme</a>'''

BUSY = '''<!doctype html><meta charset="utf-8"><title>Busy</title><h1>Busy page</h1>
<button id="loop" style="font-size:24px;padding:12px 20px">Hold the main thread</button>
<script>
const ms = Number(new URLSearchParams(location.search).get('ms') || '0');
document.querySelector('#loop').addEventListener('click', () => {
  const end = ms > 0 ? Date.now() + ms : Infinity;
  while (Date.now() < end) {}
  document.title = 'Busy (done)';
});
</script>'''

SLOW = '''<!doctype html><meta charset="utf-8"><title>Slow</title><h1>Slow page</h1>'''
LOGIN = '''<!doctype html><meta charset="utf-8"><title>Login</title>
<style>body{margin:24px;background:#fff;font:16px -apple-system} input{display:block;width:280px;height:40px;
margin:0 0 16px;padding:0 10px;border:1px solid #bbb;background:#fff;color:#000;font:24px -apple-system;outline:none}</style>
<form onsubmit="return false"><input id="user" autocomplete="off">
<input id="pass" type="password" autocomplete="off"><button id="go" type="button">Sign in</button></form>
<div id="done"></div>
<script>
// How old each input event is when the page gets it (event.timeStamp against performance.now()).
window.__input = [];
// Whether the page came back from the back-forward cache.
addEventListener('pageshow', e => { window.__restored = e.persisted });
for (const type of ['keydown', 'mousedown', 'wheel'])
  addEventListener(type, e => __input.push([type, Math.round(performance.now() - e.timeStamp)]), true);
// A soft navigation, as an SPA moves after a click or Enter: pushState, then new content painted.
let moves = 0;
function move() {
  moves += 1;
  history.pushState({}, '', '/login/step' + moves);
  document.querySelector('#done').innerHTML = '<h1 style="font-size:64px">Step ' + moves + '</h1>';
  document.title = 'Login step ' + moves;
}
document.querySelector('#go').addEventListener('click', move);
document.querySelector('#pass').addEventListener('keydown', e => { if (e.key === 'Enter') move() });
</script>'''

# The login page from another site (?src=) in a frame at the top left, so its fields are where /login has them.
LOGIN_FRAME = '''<!doctype html><meta charset="utf-8"><title>Login frame</title><body style="margin:0">
<iframe id="frame" src="SRC" style="display:block;border:0;width:100%;height:400px"></iframe>'''


VAULT_LOGIN = '''<!doctype html><meta charset="utf-8"><title>Vault sign-in</title>
<form id="form" method="post"><label>Email <input id="user" name="user" autocomplete="username"></label>
<label>Password <input id="pass" name="pass" type="password" autocomplete="current-password"></label>
<label>Note <input id="note" name="note"></label><button id="go">Sign in</button></form>
<script>
window.qa = {inputs: {user: 0, pass: 0}, trusted: [], submitted: null};
for (const id of ['user', 'pass']) document.getElementById(id).addEventListener('input', e => {
  window.qa.inputs[id] += 1; window.qa.trusted.push(e.isTrusted); });
document.getElementById('form').addEventListener('submit', e => { e.preventDefault();
  window.qa.submitted = {user: user.value, pass: pass.value, note: note.value}; });
</script>'''

# Sign-ins that would send a filled password where it does not belong (docs/BROWSER_VAULT_DESIGN.md, "Filled values
# and addresses"): /vault/get (a form without a method or a script of its own, so the browser puts its fields in the
# address; #js builds such an address itself and #nested puts one inside another's query) and /vault/elsewhere (a form
# posting to the other site, 127.0.0.1 for localhost). Each goes to /vault/landed; the QA asks /qa/landed how many
# requests arrived there.
VAULT_GET = '''<!doctype html><meta charset="utf-8"><title>Vault GET sign-in</title>
<form id="form" action="/vault/landed"><label>Email <input id="user" name="email" autocomplete="username"></label>
<label>Password <input id="pass" name="password" type="password" autocomplete="current-password"></label>
<button id="go">Sign in</button></form>
<button id="js" onclick="location.href = '/vault/landed?p=' + encodeURIComponent(pass.value)">Script sign-in</button>
<button id="nested" onclick="location.href = '/vault/landed?next=' + encodeURIComponent('/home?p=' + encodeURIComponent(pass.value))">Nested sign-in</button>'''

VAULT_ELSEWHERE = '''<!doctype html><meta charset="utf-8"><title>Vault elsewhere</title>
<form id="form" method="post"><label>Email <input id="user" name="email" autocomplete="username"></label>
<label>Password <input id="pass" name="password" type="password" autocomplete="current-password"></label>
<button id="go">Sign in</button></form>
<script>
const other = location.hostname === 'localhost' ? '127.0.0.1' : 'localhost';
form.action = location.protocol + '//' + other + ':' + location.port + '/vault/landed';
</script>'''

VAULT_LANDED = '<!doctype html><meta charset="utf-8"><title>Vault landed</title><h1>Landed</h1>'
# How many requests reached /vault/landed, which /qa/landed answers: the QA app asks over loopback rather than reading
# this server's log from its folder.
landed = 0

VAULT_REACT = '''<!doctype html><meta charset="utf-8"><title>Vault controlled</title>
<form id="form"><input id="user" autocomplete="username"><input id="pass" type="password"><button>Sign in</button></form>
<script>
// React keeps the value it last set on the element (a property on the instance) and takes an input
// event only when the element's value differs from it, then renders its state back into the element.
const state = {user: '', pass: ''};
const native = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
for (const id of ['user', 'pass']) {
  const node = document.getElementById(id);
  let tracked = node.value;
  Object.defineProperty(node, 'value', {configurable: true, get() { return native.get.call(this); },
    set(v) { tracked = String(v); native.set.call(this, v); }});
  node.addEventListener('input', () => {
    const value = native.get.call(node);
    if (value === tracked) return;
    tracked = value; state[id] = value; node.value = state[id];
  });
}
window.qa = {submitted: null};
document.getElementById('form').addEventListener('submit', e => { e.preventDefault(); window.qa.submitted = {...state}; });
</script>'''

VAULT_OTP = '''<!doctype html><meta charset="utf-8"><title>Vault code</title>
<form id="one"><input id="code" autocomplete="one-time-code" inputmode="numeric" maxlength="6"><button>Verify</button></form>
<form id="boxes"><span id="digits">''' + ''.join(f'<input id="d{i}" maxlength="1" inputmode="numeric">' for i in range(6)) + '''</span><button>Verify</button></form>
<script>
// RFC 6238's SHA-1 test key, "12345678901234567890", six digits, 30 seconds.
async function expected(offset) {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode('12345678901234567890'),
    {name: 'HMAC', hash: 'SHA-1'}, false, ['sign']);
  const counter = Math.floor(Date.now() / 1000 / 30) + offset;
  const message = new ArrayBuffer(8); new DataView(message).setUint32(4, counter);
  const hash = new Uint8Array(await crypto.subtle.sign('HMAC', key, message));
  const o = hash[19] & 15;
  const binary = ((hash[o] & 127) << 24) | (hash[o + 1] << 16) | (hash[o + 2] << 8) | hash[o + 3];
  return String(binary % 1000000).padStart(6, '0');
}
async function check(code) { return [await expected(0), await expected(-1)].includes(code); }
window.qa = {one: null, boxes: null};
document.getElementById('one').addEventListener('submit', async e => { e.preventDefault();
  window.qa.one = await check(document.getElementById('code').value); });
document.getElementById('boxes').addEventListener('submit', async e => { e.preventDefault();
  window.qa.boxes = await check([0, 1, 2, 3, 4, 5].map(i => document.getElementById('d' + i).value).join('')); });
</script>'''

# Two-factor setup (vault §14). The QR codes are PNGs made with CoreImage's CIQRCodeGenerator, one
# pixel a module, from these made-up addresses; the page draws them large with crisp pixels.
# Setup: otpauth://totp/Yardlet%20QA:person@example.test?secret=JBSWY3DPEHPK3PXP&issuer=Yardlet%20QA
SETUP_QR_PNG = (
    'iVBORw0KGgoAAAANSUhEUgAAACsAAAArCAYAAADhXXHAAAAAAXNSR0IArs4c6QAAADhlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAA'
    'GgAAAAAAAqACAAQAAAABAAAAK6ADAAQAAAABAAAAKwAAAABNFGXCAAAECElEQVRYCdXW4ZITMQwDYMrw/q98VOl9i9YkvfsJmdnK'
    'liU57ZQej4/n+fGfnF+55+PxOF6330vrwutpTn3C6WnDvdNn3ie+ddmQHUIkTD91PNGpW6s2C8qcXPd8kOe6bAbI1MyTbw0dbTDz'
    'PKnx+sbUDp3+NLtdlviEHWpxay2JTp0538TWdM6p/nka7PiEe/pClrrM7GXhZYTvmu6Et0/WspMYT9foIuHUQZp4zRplNran+euT'
    '9Q4bWyjAosxOl8qMfqfzJtofXU7vV78mz9kz9MvfWeHCXBiGV0NcsE9nNf+den0NBATnyfI8jnpeanrNYfy8rcVl3nz6nJ7fvgaG'
    'BHCG6DPPk37WOLg21/KZPTPpg2a3rwEyApdQB/vQzqV8+HiixafvWfocmlf354Lp6ddlLSY01DfStubdIl766edt/lRfP13ChDOk'
    '75m6l4TTt765mdczO4P4II+d12V7wCDETB+zC+Iad34LM5t58c65/Bs+m48O39W43RKXTGhOa3HNL9Hni7zWvZuvXwPiXhRTeIFm'
    'tLB1Uzt7F8Hz4mHmeXpHZrdfg0U8RTl9UX1wF4IPOnMRHsoJ5tCf+GiuXwPikF8dgXRzYXgcTXC3o7NOHprraxDCY0H3qZ25dPa0'
    'O94sWamjCartCJrJuf6ChUC2uQ3h52lO3Tmdi58Z6XuPvjH1ddleZAEuwhzL8EHczmNG1/hKfL3SBWVnkrr767LMhsEZwiwUnrw7'
    '/dSmp+uds16658L1O5smyxf5edFpOM3pGlfQZ2b43ZGXGW/rJnf7ZDPs4A4T0vPdkl7AH1TL0dupNw/i7Lxd1hAKEsBkLrB5syCe'
    'nz44Z+mb617m7bLEhETp1b1Y3bPOCK+n3WF0Hrujkyvj+gsWYhfOYAmjsOmjp9NHj5ve3SxcjvzU1/+60uR0eHoLJm8WXiAt5DGP'
    'hz51H9pw7W/+9jVocwxM+O4T0kGZdd+1CzRHL7ORLpwnGeuyISJgyCA9U3qzHY9rzfSkz7FLvcjny9wls/lvfbJtcCHLMmsOHzTb'
    'zWXC6E+H5nZZZEypPf1p0OAaLaPpvrnUuzdAH5zzcH/9A5uiBO/CLd/NvIEseHemt3eb2ZOcddkmuraol6sFR98e83hpcFBu48zI'
    'LFx71mWFtlk9L9M8n0A9TbAvMZe3LrWc5tt/fQ2aJLYc4iFPY2vD69W0yTCbefrMW39ddppbxAyF9LK+zOT5WiOfFtIGW5/+9msQ'
    '4nSEZ66GPMJ3fS6TpzV9wfD97DJunyzBDueiaHDq4LyMPti61tIswedLc7y3TzakZxr1jOlT+3TwevrTG8rcDIaTk3qe65OdS1rY'
    'YWrYuq77jeyy+WF7U/P05a//Ik7xv9j/BhS4sWnN/IuYAAAAAElFTkSuQmCC'
)

# Export: otpauth-migration://offline?data=… (MigrationPayload) with "QA Export" export-one@example.test
# (key "qa-export-key-one!!!", SHA-1, 6 digits), "QA Second:export-two@example.test" (key
# "qa-export-key-two!!!", SHA-256, 8 digits) and the counter-based "QA Counter" hotp@example.test.
EXPORT_QR_PNG = (
    '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'
    'AABJRU5ErkJggg=='
)

VAULT_OTP_SETUP = """<!doctype html><meta charset="utf-8"><title>Vault two-factor setup</title>
<style>img{width:215px;height:215px;image-rendering:pixelated;margin:16px 0}</style>
<h1>Set up two-factor authentication</h1><p>Scan this QR code with your authenticator app.</p>
<img id="qr" alt="QR code" src="data:image/png;base64,""" + SETUP_QR_PNG + """">
<p>Can't scan it? Enter this setup key: JBSW Y3DP EHPK 3PXP</p>
<form id="confirm"><label>Code <input id="code" autocomplete="one-time-code" inputmode="numeric" maxlength="6"></label>
<button>Turn on</button></form>
<script>
// The QR code's key, "Hello!" and DE AD BE EF.
async function expected(offset) {
  const key = await crypto.subtle.importKey('raw', new Uint8Array([72, 101, 108, 108, 111, 33, 222, 173, 190, 239]),
    {name: 'HMAC', hash: 'SHA-1'}, false, ['sign']);
  const counter = Math.floor(Date.now() / 1000 / 30) + offset;
  const message = new ArrayBuffer(8); new DataView(message).setUint32(4, counter);
  const hash = new Uint8Array(await crypto.subtle.sign('HMAC', key, message));
  const o = hash[19] & 15;
  const binary = ((hash[o] & 127) << 24) | (hash[o + 1] << 16) | (hash[o + 2] << 8) | hash[o + 3];
  return String(binary % 1000000).padStart(6, '0');
}
window.qa = {confirmed: null};
document.getElementById('confirm').addEventListener('submit', async e => { e.preventDefault();
  window.qa.confirmed = [await expected(0), await expected(-1)].includes(document.getElementById('code').value); });
</script>"""

VAULT_OTP_EXPORT = """<!doctype html><meta charset="utf-8"><title>Vault authenticator export</title>
<style>img{width:284px;height:284px;image-rendering:pixelated;margin:16px 0}</style>
<h1>Export accounts</h1><img id="qr" alt="QR code" src="data:image/png;base64,""" + EXPORT_QR_PNG + """">"""

VAULT_REVEAL = '''<!doctype html><meta charset="utf-8"><title>Vault reveal</title>
<style>input{font:28px -apple-system;width:420px;padding:8px}</style>
<form><input id="user" autocomplete="username"><input id="pass" type="password">
<button type="button" id="show" onclick="pass.type = pass.type === 'password' ? 'text' : 'password'">Show</button></form>'''

VAULT_STEP = '''<!doctype html><meta charset="utf-8"><title>Vault first step</title>
<form id="form"><label>Email <input id="user" autocomplete="username"></label><button>Next</button></form>
<script>window.qa = {submitted: null};
document.getElementById('form').addEventListener('submit', e => { e.preventDefault(); window.qa.submitted = user.value; });</script>'''

# window.qa.ok() says whether the new password meets the field's passwordrules, without giving it.
VAULT_SIGNUP = '''<!doctype html><meta charset="utf-8"><title>Vault sign-up</title>
<form id="form" method="post"><label>Email <input id="user" autocomplete="username"></label>
<label>Password <input id="pass" type="password" autocomplete="new-password"
  passwordrules="minlength: 12; maxlength: 18; required: lower; required: upper; required: digit; required: [-!]"></label>
<label>Confirm password <input id="again" type="password" autocomplete="new-password"></label><button id="go">Create account</button></form>
<script>
window.qa = {submitted: null, ok: () => /^[a-zA-Z0-9!-]{12,18}$/.test(pass.value) && /[a-z]/.test(pass.value)
  && /[A-Z]/.test(pass.value) && /[0-9]/.test(pass.value) && /[-!]/.test(pass.value) && pass.value === again.value};
document.getElementById('form').addEventListener('submit', e => { e.preventDefault();
  window.qa.submitted = {user: user.value, ok: window.qa.ok()}; });
</script>'''

VAULT_CHANGE = '''<!doctype html><meta charset="utf-8"><title>Vault password change</title>
<form id="form" method="post"><input id="user" autocomplete="username" value="person@example.test" hidden>
<label>Current password <input id="current" type="password"></label>
<label>New password <input id="fresh" type="password"></label>
<label>Confirm new password <input id="again" type="password"></label><button id="go">Change password</button></form>
<script>
window.qa = {submitted: null};
document.getElementById('form').addEventListener('submit', e => { e.preventDefault();
  window.qa.submitted = {current: current.value, match: fresh.value !== '' && fresh.value === again.value,
    changed: fresh.value !== current.value}; });
</script>'''

ISOLATION = '''<!doctype html><meta charset="utf-8"><title>Isolation</title><h1>Isolation</h1>'''

# The sign-ins tasks follow (BrowserHostIsolationQA, docs/BROWSER_SESSION_ISOLATION.md 11). /follow/signin has a
# password form, whose post sets qa_follow to the username, and a "Sign in with QA" link to the other site's
# /follow/idp (localhost and 127.0.0.1 are two sites), which waits for a click as an account chooser does and goes
# back to /follow/callback, which sets qa_follow=SSO. Both end on /follow/home. /follow/home?rotate renews qa_rotate
# from the page, as a site renews a cookie while it is used.
FOLLOW_SIGN_IN = """<!doctype html><meta charset="utf-8"><title>Follow sign-in</title>
<form method="post" action="/follow/signin"><input id="user" name="user" autocomplete="username">
<input id="password" name="password" type="password" autocomplete="current-password">
<button id="go" type="submit">Sign in</button></form>
<p><a id="sso" href="#">Sign in with QA</a> <a id="rotate" href="/follow/home?rotate">Browse</a></p>
<script>
const other = location.hostname === 'localhost' ? '127.0.0.1' : 'localhost';
document.querySelector('#sso').href = location.protocol + '//' + other + ':' + location.port + '/follow/idp?return='
  + encodeURIComponent(location.origin + '/follow/callback');
</script>"""
FOLLOW_HOME = """<!doctype html><meta charset="utf-8"><title>Follow home</title><h1>Home</h1>
<script>if (location.search.includes('rotate')) document.cookie = 'qa_rotate=' + Date.now() + '; path=/; max-age=3600';</script>"""
FOLLOW_IDP = """<!doctype html><meta charset="utf-8"><title>QA sign-in</title><h1>Choose an account</h1>
<a id="continue" href="RETURN?code=qa">Continue</a>"""

# A sign-in's cookie check across two sites, the way accounts.google.com checks its cookies before a Google
# Cloud console page opens and answers what it does not expect with /CookieMismatch. /cookie-check/start on
# this server (the console) redirects to the issuer origin (the accounts site, localhost, another site), whose
# /cookie-check/set sets a host-only sign-in cookie and a __Host- one and redirects to /cookie-check/verify there.
# verify reads the Cookie header: "ok" when each sign-in cookie came once, "CookieMismatch" when one is missing or
# came twice, or when the accounts site received the cookie its frame set partitioned under the console.
# /cookie-check/console (on this server) frames the accounts site's /cookie-check/frame, which sets that
# partitioned cookie and an unpartitioned SameSite=None one and reports what the frame can read.
# window.qa.cookieCheck also has the user agent and client hints the accounts site received.
COOKIE_SIGN_IN = ['qa_signin', '__Host-qa_signin']
COOKIE_CONSOLE = """<!doctype html><meta charset="utf-8"><title>Console</title><h1>Console</h1>
<iframe id="frame" src="ISSUER/cookie-check/frame"></iframe>
<script>window.qa = {}; addEventListener('message', e => { if (e.data && e.data.frame) window.qa.frame = e.data.frame; });</script>"""
COOKIE_FRAME = """<!doctype html><meta charset="utf-8"><title>Accounts frame</title><p>Accounts frame</p>
<script>
(async () => {
  const frame = {cookie: document.cookie};
  try { frame.hasStorageAccess = await document.hasStorageAccess(); } catch (e) { frame.hasStorageAccess = e.name; }
  parent.postMessage({frame}, '*');
})();
</script>"""

VAULT_WEBAUTHN = '''<!doctype html><meta charset="utf-8"><title>Vault WebAuthn</title><h1>WebAuthn</h1>'''

PASSKEY = '''<!doctype html><meta charset="utf-8"><title>Passkey</title>
<style>input{font:20px -apple-system;width:320px;padding:6px;margin:8px}</style>
<form id="form"><input id="user" autocomplete="username webauthn" placeholder="Email">
<input id="pass" type="password" autocomplete="current-password"><button>Sign in</button></form>
<script>
// The passkey requests sites make, for a person with no passkey for this site anywhere:
// window.passkey(kind) starts one, window.qa.passkey says how it ended ('pending' until then)
// and window.qa.abort() ends it.
const bytes = n => crypto.getRandomValues(new Uint8Array(n));
const rp = { name: 'Yardlet QA', id: 'localhost' };
const params = [{ type: 'public-key', alg: -7 }, { type: 'public-key', alg: -257 }];
const user = () => ({ id: bytes(16), name: 'qa@localhost', displayName: 'Yardlet QA' });
const requests = {
  // The sign-in field's passkey autofill, which most sign-in pages start on load.
  conditionalGet: () => ({ mediation: 'conditional',
    publicKey: { challenge: bytes(32), rpId: 'localhost', userVerification: 'preferred' } }),
  // "Sign in with a passkey": any passkey for the site, wherever it is.
  discoverableGet: () => ({
    publicKey: { challenge: bytes(32), rpId: 'localhost', userVerification: 'preferred', timeout: 120000 } }),
  // Facebook's "face, fingerprint or screen lock" step: a passkey on this device only.
  getPlatformOnly: () => ({ publicKey: { challenge: bytes(32), rpId: 'localhost',
    allowCredentials: [{ type: 'public-key', id: bytes(16), transports: ['internal'] }],
    userVerification: 'required', hints: ['client-device'], timeout: 120000 } }),
  // A sign-in for an account the site knows, as Google's passkey step after the email: the
  // account's passkeys, listed in window.qa.allow ({id: base64, transports}).
  getAllowed: () => ({ publicKey: { challenge: bytes(32), rpId: 'localhost', userVerification: 'required', timeout: 120000,
    allowCredentials: window.qa.allow.map(c => ({ type: 'public-key', transports: c.transports,
      id: Uint8Array.from(atob(c.id), ch => ch.charCodeAt(0)) })) } }),
  // "Create a passkey" as most sites ask for it: no attachment named.
  createAny: () => ({ publicKey: { challenge: bytes(32), rp, user: user(), pubKeyCredParams: params,
    authenticatorSelection: { residentKey: 'preferred', userVerification: 'preferred' }, timeout: 60000 } }),
  // A passkey on this device only.
  createPlatform: () => ({ publicKey: { challenge: bytes(32), rp, user: user(), pubKeyCredParams: params,
    hints: ['client-device'], timeout: 120000,
    authenticatorSelection: { authenticatorAttachment: 'platform', residentKey: 'required', userVerification: 'required' } } }),
};
window.qa = { passkey: 'idle', controller: null, allow: [] };
window.qa.abort = () => { window.qa.controller && window.qa.controller.abort(); return 'ok'; };
window.passkey = kind => {
  window.qa.controller = new AbortController();
  window.qa.passkey = 'pending';
  const options = { ...requests[kind](), signal: window.qa.controller.signal };
  const call = kind.startsWith('create') ? navigator.credentials.create(options) : navigator.credentials.get(options);
  call.then(() => { window.qa.passkey = 'resolved'; }, e => { window.qa.passkey = e.name + ': ' + e.message; });
  return 'started';
};
</script>'''

# A card checkout and the card issuer's check (3-D Secure) a payment may need. The merchant is this
# server at 127.0.0.1 (MERCHANT); the issuer answers on the second port as localhost (ISSUER), another
# site. Fixed positions let the QA click inside the issuer's frame.
CHECKOUT = '''<!doctype html><meta charset="utf-8"><title>Checkout</title>
<style>body{font:14px -apple-system,system-ui;margin:12px}label{display:inline-block;margin:2px 4px}
input{font:inherit;padding:2px;width:140px;display:block}</style>
<h1>Checkout</h1>
<form id="pay" method="post" action="/checkout/done">
<label>Name on card <input id="cc-name" name="name" autocomplete="cc-name"></label>
<label>Card number <input id="cc-number" name="number" autocomplete="cc-number" inputmode="numeric"></label>
<label>Month <input id="cc-exp-month" name="month" autocomplete="cc-exp-month"></label>
<label>Year <input id="cc-exp-year" name="year" autocomplete="cc-exp-year"></label>
<label>Security code <input id="cc-csc" name="csc" autocomplete="cc-csc"></label>
<button id="pay-button" type="submit">Pay</button>
</form>'''

PAID = '''<!doctype html><meta charset="utf-8"><title>Paid</title><h1>Paid</h1>'''

# A shipping address, complete enough for Chromium to offer saving it, short enough to fit a small panel.
CHECKOUT_ADDRESS = '''<!doctype html><meta charset="utf-8"><title>Checkout address</title>
<style>body{font:14px -apple-system,system-ui;margin:12px}label{display:inline-block;margin:2px 4px}
input{font:inherit;padding:2px;width:140px;display:block}</style>
<form method="post" action="/checkout/shipped">
<label>Full name <input id="name" name="name" autocomplete="name"></label>
<label>Address <input id="street" name="street" autocomplete="address-line1"></label>
<label>City <input id="city" name="city" autocomplete="address-level2"></label>
<label>State <input id="state" name="state" autocomplete="address-level1"></label>
<label>ZIP code <input id="zip" name="zip" autocomplete="postal-code"></label>
<label>Country <input id="country" name="country" autocomplete="country"></label>
<label>Phone <input id="phone" name="phone" autocomplete="tel"></label>
<button id="ship" type="submit">Ship here</button>
</form>'''

# 3-D Secure 2 in frames, as Stripe runs it: a hidden frame posts the browser's details to the issuer
# (the method URL) and the issuer posts back to the merchant; then the challenge opens in a visible
# frame by a form post, and the issuer's answer posts back to the merchant, whose page tells the
# checkout by postMessage.
CHECKOUT_FRAME = '''<!doctype html><meta charset="utf-8"><title>Checkout frame</title>
<style>body{margin:0;font:16px -apple-system}h1{margin:12px;font-size:20px}
#challenge{position:absolute;left:0;top:60px;width:400px;height:300px;border:1px solid #999}</style>
<h1>Card check</h1>
<iframe name="method" style="display:none"></iframe>
<form id="method-form" method="post" action="ISSUER/acs/method" target="method">
<input type="hidden" name="threeDSMethodData" value="qa"></form>
<iframe name="challenge" id="challenge"></iframe>
<form id="challenge-form" method="post" action="ISSUER/acs/challenge" target="challenge">
<input type="hidden" name="creq" value="qa"><input type="hidden" name="return" value="MERCHANT/checkout/complete"></form>
<script>
window.qa = {messages: []};
addEventListener('message', e => {
  window.qa.messages.push(e.origin + ' ' + JSON.stringify(e.data));
  if (e.data && e.data.step === 'method') { window.qa.challenge = 'loading'; document.getElementById('challenge-form').submit(); }
  if (e.data && e.data.step === 'challenge') { window.qa.result = e.data.result; document.title = 'Checkout frame done'; }
});
document.getElementById('challenge').onload = () => { if (window.qa.challenge === 'loading') window.qa.challenge = 'loaded'; };
document.getElementById('method-form').submit();
</script>'''

# 3-D Secure 1 by redirect: the whole page posts to the issuer, and the issuer's page posts back to the
# merchant's TermUrl.
CHECKOUT_REDIRECT = '''<!doctype html><meta charset="utf-8"><title>Checkout redirect</title>
<style>body{margin:0;font:16px -apple-system}#go{position:absolute;left:20px;top:20px;width:240px;height:40px}</style>
<form method="post" action="ISSUER/acs/challenge">
<input type="hidden" name="PaReq" value="qa"><input type="hidden" name="return" value="MERCHANT/checkout/return">
<button id="go">Continue to your bank</button></form>'''

# The issuer's check in a new window that answers the page that opened it, as some issuers, PayPal and
# sign-in popups do.
CHECKOUT_POPUP = '''<!doctype html><meta charset="utf-8"><title>Checkout popup</title>
<style>body{margin:0;font:16px -apple-system}#open{position:absolute;left:20px;top:20px;width:240px;height:40px}</style>
<button id="open">Check with your bank</button>
<script>
window.qa = {messages: []};
addEventListener('message', e => {
  window.qa.messages.push(e.origin + ' ' + JSON.stringify(e.data));
  if (e.data && e.data.step === 'popup') { window.qa.result = e.data.result; document.title = 'Checkout popup done'; }
});
document.getElementById('open').onclick = () => {
  window.qa.opened = !!window.open('ISSUER/acs/popup', 'issuer', 'popup,width=420,height=560');
};
</script>'''

# A wallet button (Google Pay, Apple Pay, Secure Payment Confirmation) starts the Payment Request API, whose
# sheet is Chrome's. Opened at localhost, a valid relying party for Secure Payment Confirmation; no credential
# matches, as for a card never enrolled. window.qa.request.abort() ends a request still open. As on a real
# checkout, the button shows only where the browser has the API (Yardlet's hides it, as the Claude app's does).
CHECKOUT_WALLET = '''<!doctype html><meta charset="utf-8"><title>Checkout wallet</title>
<style>body{margin:0;font:16px -apple-system}#pay{position:absolute;left:20px;top:20px;width:240px;height:40px}</style>
<button id="pay">Pay with a wallet</button>
<script>
window.qa = {api: typeof PaymentRequest, state: 'idle'};
document.getElementById('pay').hidden = typeof PaymentRequest === 'undefined';
document.getElementById('pay').onclick = async () => {
  window.qa.state = 'started';
  try {
    const request = new PaymentRequest([{supportedMethods: 'secure-payment-confirmation', data: {
      credentialIds: [new Uint8Array(16)], challenge: new Uint8Array(16), rpId: location.hostname, timeout: 60000,
      instrument: {displayName: 'Yardlet QA card', icon: location.origin + '/icon-blue.png'}, payeeName: 'Yardlet QA'}}],
      {total: {label: 'Total', amount: {currency: 'USD', value: '1.00'}}});
    window.qa.request = request;
    const response = await request.show();
    window.qa.state = 'paid';
    await response.complete('success');
  } catch (e) {
    window.qa.state = e.name + ': ' + e.message;
  }
};
</script>'''

ISSUER_POPUP = '''<!doctype html><meta charset="utf-8"><title>Issuer popup</title><h1>Issuer</h1>
<script>
if (window.opener) {
  window.opener.postMessage({step: 'popup', result: 'authenticated'}, 'MERCHANT');
  setTimeout(() => window.close(), 300);
} else {
  document.title = 'Issuer popup without opener';
}
</script>'''

ISSUER_CHALLENGE = '''<!doctype html><meta charset="utf-8"><title>Issuer check</title>
<style>body{margin:0;font:16px -apple-system}#confirm{position:absolute;left:20px;top:20px;width:200px;height:40px}</style>
<form method="post" action="/acs/verify"><input type="hidden" name="return" value="RETURN">
<button id="confirm">Confirm</button></form>'''


def auto_post(action, fields):
    """A page that posts `fields` to `action` as it loads, as issuers and 3-D Secure servers answer."""
    inputs = ''.join('<input type="hidden" name="%s" value="%s">' % (html.escape(name), html.escape(value))
                     for name, value in fields.items())
    return ('<!doctype html><meta charset="utf-8"><title>Posting</title><form method="post" action="%s">%s</form>'
            '<script>document.forms[0].submit()</script>' % (html.escape(action), inputs))


# What ordinary sites ask of a browser beyond showing pages: window.compat(kind) starts one request and
# window.qa.compat[kind] says how it ended ('pending' until then). TLS_ORIGIN and FRAME_ORIGIN are filled in
# per request: the HTTPS port with a self-signed certificate, and this server as localhost (another site).
COMPAT = """<!doctype html><meta charset="utf-8"><title>Compat</title>
<style>#apps a{display:inline-block;margin:0 6px 0 0;padding:6px 10px;border:1px solid #999}</style>
<h1>Compat</h1>
<p id="apps"><a id="mailto" href="mailto:qa@example.com">Mail</a><a id="mailto-blank" href="mailto:qa-blank@example.com"
target="_blank">Mail in a new tab</a><a id="tel" href="tel:+15555550100">Call</a><a id="no-app"
href="yardlet-qa-no-app:test">No app</a><button id="wallet" hidden>Pay with a wallet</button></p>
<p><input id="multi" type="file" multiple> <input id="dir" type="file" webkitdirectory></p>
<iframe id="frame" style="width:320px;height:60px"></iframe>
<script>
window.qa = {compat: {}, tls: 'TLS_ORIGIN', frameOrigin: 'FRAME_ORIGIN'};
const settle = (kind, promise) => {
  window.qa.compat[kind] = 'pending';
  Promise.resolve(promise).then(v => { window.qa.compat[kind] = 'resolved ' + v; },
                                e => { window.qa.compat[kind] = (e && e.name || 'error') + ': ' + (e && e.message || e); });
  return 'started';
};
const save = (href, name, target) => {
  const a = document.createElement('a');
  a.href = href;
  if (name) a.download = name;
  if (target) a.target = target;
  document.body.append(a);
  a.click();
  a.remove();
};
addEventListener('message', e => { if (e.data && e.data.frame) window.qa.compat.frame = JSON.stringify(e.data.frame); });
const requests = {
  permissionStates: async () => {
    const names = ['geolocation', 'notifications', 'camera', 'microphone', 'clipboard-read', 'clipboard-write',
                   'storage-access', 'local-fonts', 'window-management'];
    const states = [];
    for (const name of names) {
      try { states.push(name + '=' + (await navigator.permissions.query({name})).state); }
      catch (e) { states.push(name + '=' + e.name); }
    }
    return 'Notification.permission=' + Notification.permission + ' ' + states.join(' ');
  },
  notification: () => Notification.requestPermission(),
  geolocation: () => new Promise((resolve, reject) => navigator.geolocation.getCurrentPosition(
      () => resolve('position'), e => reject({name: 'GeolocationPositionError', message: e.code + ' ' + e.message}),
      {timeout: 2000, maximumAge: Infinity})),
  clipboardRead: () => navigator.clipboard.readText().then(text => 'text of ' + text.length + ' characters'),
  blobDownload: () => { save(URL.createObjectURL(new Blob(['a,b\\n1,2\\n'], {type: 'text/csv'})), 'qa-blob.csv'); return 'clicked'; },
  dataDownload: () => { save('data:text/plain;charset=utf-8,Yardlet%20QA', 'qa-data.txt'); return 'clicked'; },
  twoDownloads: () => { save('/download?name=qa-multi-1.txt', 'qa-multi-1.txt'); save('/download?name=qa-multi-2.txt', 'qa-multi-2.txt'); return 'clicked'; },
  blankDownload: () => { save('/download?name=qa-blank.txt', null, '_blank'); return 'clicked'; },
  popupWithoutGesture: () => { const opened = window.open('/second?popup'); return opened ? 'opened' : 'null'; },
  fullscreen: async () => {
    const before = innerWidth + 'x' + innerHeight;
    await document.documentElement.requestFullscreen();
    const during = !!document.fullscreenElement + ' ' + innerWidth + 'x' + innerHeight;
    await document.exitFullscreen();
    return before + ' -> ' + during;
  },
  openFilePicker: () => showOpenFilePicker().then(handles => handles.length + ' handles'),
  saveFilePicker: () => showSaveFilePicker({suggestedName: 'qa-save.txt'}).then(handle => handle.name),
  directoryPicker: () => showDirectoryPicker().then(handle => handle.name),
  multipleInput: () => { document.getElementById('multi').click(); return 'clicked'; },
  directoryInput: () => { document.getElementById('dir').click(); return 'clicked'; },
  thirdPartyFrame: () => { document.getElementById('frame').src = window.qa.frameOrigin + '/compat/frame'; return 'loading'; },
  features: () => ['IdentityCredential', 'PaymentRequest', 'showOpenFilePicker', 'Notification', 'PublicKeyCredential']
      .map(name => name + '=' + (name in window)).join(' ') + ' share=' + ('share' in navigator),
  // Camera and microphone: the QA blocks each in the panel's bar, before a grant could reach macOS.
  camera: () => navigator.mediaDevices.getUserMedia({video: true}).then(s => { s.getTracks().forEach(t => t.stop()); return 'stream'; }),
  microphone: () => navigator.mediaDevices.getUserMedia({audio: true}).then(s => { s.getTracks().forEach(t => t.stop()); return 'stream'; }),
  // A wallet button, shown as sites show theirs: only where the Payment Request API is there.
  walletButton: () => document.getElementById('wallet').hidden ? 'hidden' : 'shown',
};
// As a checkout does, the page shows its wallet button only when the browser has the Payment Request API.
document.getElementById('wallet').hidden = !('PaymentRequest' in window);
window.compat = kind => settle(kind, Promise.resolve().then(requests[kind]));
</script>"""

# The cross-site frame: sets a SameSite=None cookie, asks its own server which cookies came back, and
# tells the page what storage it has.
COMPAT_FRAME = """<!doctype html><meta charset="utf-8"><title>Frame</title><p>Cross-site frame</p>
<script>
(async () => {
  const frame = {};
  try {
    document.cookie = 'thirdparty=1; SameSite=None; Secure; Path=/; Max-Age=600';
    frame.cookie = document.cookie;
    frame.echoed = await (await fetch('/compat/echo', {credentials: 'include'})).text();
  } catch (e) { frame.cookieError = e.name; }
  try { localStorage.setItem('qa', '1'); frame.localStorage = localStorage.getItem('qa'); } catch (e) { frame.localStorage = e.name; }
  try { frame.hasStorageAccess = await document.hasStorageAccess(); } catch (e) { frame.hasStorageAccess = e.name; }
  parent.postMessage({frame}, '*');
})();
</script>"""

AUTHORIZED = '<!doctype html><meta charset="utf-8"><title>Authorized</title><h1>Signed in with HTTP authentication</h1>'
UNAUTHORIZED = '<!doctype html><meta charset="utf-8"><title>Unauthorized</title><h1>401 Unauthorized</h1>'


def one_page_pdf():
    """A valid one-page PDF that says "Yardlet QA PDF"."""
    content = b'BT /F1 24 Tf 72 720 Td (Yardlet QA PDF) Tj ET'
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>',
               b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
               b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R '
               b'/Resources << /Font << /F1 5 0 R >> >> >>',
               b'<< /Length %d >>\nstream\n' % len(content) + content + b'\nendstream',
               b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']
    out = bytearray(b'%PDF-1.4\n')
    offsets = []
    for number, body in enumerate(objects, 1):
        offsets.append(len(out))
        out += b'%d 0 obj\n' % number + body + b'\nendobj\n'
    xref = len(out)
    out += b'xref\n0 %d\n0000000000 65535 f \n' % (len(objects) + 1)
    out += b''.join(b'%010d 00000 n \n' % offset for offset in offsets)
    out += b'trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n' % (len(objects) + 1, xref)
    return bytes(out)


PDF = one_page_pdf()

# Screen size checks: what the page sees of its viewport, device and color scheme, and a tap target near the
# bottom right of a phone's screen whose clicks (and their pointer type) the page counts.
VIEWPORT = '''<!doctype html>
<html><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Viewport</title>
<style>
  body { margin: 0; font: 16px -apple-system, sans-serif; background: white; color: black; }
  @media (prefers-color-scheme: dark) { body { background: rgb(20, 20, 20); color: white; } }
  #target { position: absolute; left: 255px; top: 700px; width: 100px; height: 60px; }
</style>
<h1>Viewport</h1>
<button id="target">Tap target</button>
<script>
  window.qa = {clicks: 0, pointerTypes: []};
  window.qa.read = () => ({width: innerWidth, height: innerHeight, ratio: devicePixelRatio,
    coarse: matchMedia('(pointer: coarse)').matches, touch: 'ontouchstart' in window, touchPoints: navigator.maxTouchPoints,
    dark: matchMedia('(prefers-color-scheme: dark)').matches, userAgent: navigator.userAgent,
    mobile: !!(navigator.userAgentData && navigator.userAgentData.mobile)});
  document.getElementById('target').addEventListener('click', () => window.qa.clicks++);
  addEventListener('pointerdown', event => window.qa.pointerTypes.push(event.pointerType));
</script>
</html>'''

# Resizing the panel: a page laid out for its width, with a red edge on its right that a frame shows where the page
# ends, its width in large type and its columns by width. `?heavy=1` adds cards of text to lay out again each time.
RESPONSIVE = '''<!doctype html>
<html><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Responsive</title>
<style>
  body { margin: 0; font: 16px -apple-system, sans-serif; background: white; color: black; }
  #edge { position: fixed; top: 0; bottom: 0; right: 0; width: 4px; background: rgb(255, 0, 0); }
  #width { font-size: 40px; margin: 16px; }
  #cards { display: grid; gap: 8px; margin: 16px; grid-template-columns: 1fr; }
  @media (min-width: 480px) { #cards { grid-template-columns: 1fr 1fr; } }
  @media (min-width: 720px) { #cards { grid-template-columns: 1fr 1fr 1fr; } }
  .card { min-height: 60px; padding: 8px; background: rgb(0, 90, 200); color: white; }
</style>
<div id="edge"></div>
<div id="width"></div>
<div id="cards"></div>
<script>
  window.qa = {resizes: 0, columns: () => getComputedStyle(document.getElementById('cards')).gridTemplateColumns.split(' ').length};
  const heavy = location.search.includes('heavy');
  const text = 'A card whose words wrap again at every width the panel takes. ';
  document.getElementById('cards').innerHTML = Array.from({length: heavy ? 3000 : 6},
    (_, i) => `<div class="card">${i} ${heavy ? text.repeat(1 + i % 4) : ''}</div>`).join('');
  const show = () => { document.getElementById('width').textContent = innerWidth + ' px'; };
  addEventListener('resize', () => { window.qa.resizes++; show(); });
  show();
</script>
</html>'''

# Page reading across frames and shadow roots: an open and a closed shadow root, a frame from this site and one
# from another (ISSUER, which in turn holds a frame from this site again). Each control reports to the top page,
# which counts in window.qa what reached it.
FRAMES = '''<!doctype html><meta charset="utf-8"><title>Frames</title>
<style>body{font:16px -apple-system,sans-serif;margin:16px} iframe{display:block;margin:12px 0;border:1px solid #888}</style>
<h1>Frames</h1>
<div id="open-host"></div>
<div id="closed-host"></div>
<iframe id="same" title="Same site frame" src="/frames/inner" style="width:420px;height:90px"></iframe>
<iframe id="cross" title="Card frame" src="ISSUER/frames/cross" style="width:460px;height:230px;margin-left:40px"></iframe>
<script>
  window.qa = {loaded: [], same: 0, cross: 0, nested: 0, shadow: 0, closed: 0, crossValue: '', shadowValue: ''};
  addEventListener('message', event => {
    const data = event.data || {};
    if (data.loaded) window.qa.loaded.push(data.loaded);
    if (data.clicked) window.qa[data.clicked]++;
    if (data.value !== undefined) window.qa.crossValue = data.value;
  });
  const open = document.getElementById('open-host').attachShadow({mode: 'open'});
  open.innerHTML = '<button id="shadow-button">Shadow button</button> <input aria-label="Shadow field">';
  open.getElementById('shadow-button').addEventListener('click', () => window.qa.shadow++);
  open.querySelector('input').addEventListener('input', event => window.qa.shadowValue = event.target.value);
  const closed = document.getElementById('closed-host').attachShadow({mode: 'closed'});
  closed.innerHTML = '<button>Closed shadow button</button>';
  closed.querySelector('button').addEventListener('click', () => window.qa.closed++);
</script>'''

FRAMES_INNER = '''<!doctype html><meta charset="utf-8"><title>Same site frame</title>
<body style="margin:8px;font:16px -apple-system,sans-serif">
<button onclick="top.postMessage({clicked: 'same'}, '*')">Same-origin button</button>
<script>top.postMessage({loaded: 'same'}, '*')</script></body>'''

FRAMES_CROSS = '''<!doctype html><meta charset="utf-8"><title>Card frame</title>
<body style="margin:12px;font:16px -apple-system,sans-serif">
<button onclick="top.postMessage({clicked: 'cross'}, '*')">Cross-site button</button>
<input aria-label="Card number" oninput="top.postMessage({value: this.value}, '*')">
<iframe title="Nested frame" src="MERCHANT/frames/nested" style="display:block;width:300px;height:70px;margin-top:10px"></iframe>
<script>top.postMessage({loaded: 'cross'}, '*')</script></body>'''

FRAMES_NESTED = '''<!doctype html><meta charset="utf-8"><title>Nested frame</title>
<body style="margin:8px;font:16px -apple-system,sans-serif">
<button onclick="top.postMessage({clicked: 'nested'}, '*')">Nested button</button>
<script>top.postMessage({loaded: 'nested'}, '*')</script></body>'''

# A step only the person can take: a check the page passes once its button is pressed, after which the page
# says "Verified".
PERSON_CHECK = '''<!doctype html><meta charset="utf-8"><title>Handoff</title>
<body style="font:16px -apple-system,sans-serif;margin:24px">
<h1>Are you a person?</h1><p id="state">Waiting for verification</p>
<button id="human" onclick="document.getElementById('state').textContent = 'Verified'">I am a person</button></body>'''


def icon_png(color):
    """A 32-pixel page icon: a rounded square of one color with a white bar, for the side panel's tabs."""
    import struct, zlib
    size = 32
    rows = []
    for y in range(size):
        row = bytearray([0])
        for x in range(size):
            corner = min(x, size - 1 - x) + min(y, size - 1 - y) < 5
            bar = 9 <= y <= 13 and 7 <= x <= 24
            row += bytes((0, 0, 0, 0)) if corner else bytes((255, 255, 255, 255)) if bar else bytes(color + (255,))
        rows.append(bytes(row))
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    header = struct.pack('>IIBBBBB', size, size, 8, 6, 0, 0, 0)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) + chunk(b'IDAT', zlib.compress(b''.join(rows))) + chunk(b'IEND', b'')


# The memory saver's pages (BROWSER_HOST section 3, "Memory saver"): a page that holds memory in its renderer, with a
# frame from another site that holds some in its own; a page that plays sound once started; a form; a page whose
# policy allows no script of its own; and the next page of a history.
SAVER_PAGE = """<!doctype html><meta charset="utf-8"><title>Saver NUMBER</title><link rel="icon" href="/icon-green.png">
<h1>Saver page NUMBER</h1><iframe title="Other site" src="ISSUER/saver/frame" style="width:300px;height:80px"></iframe>
<script>window.held = Array.from({length: 40}, (_, i) => new Float64Array(250000).fill(i));</script>"""
SAVER_FRAME = """<!doctype html><meta charset="utf-8"><title>Saver frame</title><p>Another site's frame
<script>window.held = Array.from({length: 16}, (_, i) => new Float64Array(250000).fill(i));</script>"""
SAVER_MEDIA = """<!doctype html><meta charset="utf-8"><title>Saver media</title><h1>Sound</h1><audio id="tone" loop></audio>
<script>
function start() {
  const rate = 8000, samples = rate, data = new DataView(new ArrayBuffer(44 + samples * 2));
  const text = (offset, value) => [...value].forEach((c, i) => data.setUint8(offset + i, c.charCodeAt(0)));
  text(0, 'RIFF'); data.setUint32(4, 36 + samples * 2, true); text(8, 'WAVEfmt '); data.setUint32(16, 16, true);
  data.setUint16(20, 1, true); data.setUint16(22, 1, true); data.setUint32(24, rate, true); data.setUint32(28, rate * 2, true);
  data.setUint16(32, 2, true); data.setUint16(34, 16, true); text(36, 'data'); data.setUint32(40, samples * 2, true);
  for (let i = 0; i < samples; i++) data.setInt16(44 + i * 2, Math.sin(i / rate * 2 * Math.PI * 440) * 800, true);
  const tone = document.getElementById('tone');
  tone.src = URL.createObjectURL(new Blob([data.buffer], {type: 'audio/wav'}));
  return tone.play().then(() => 'playing', error => String(error));
}
</script>"""
SAVER_FORM = """<!doctype html><meta charset="utf-8"><title>Saver form</title><h1>Form</h1>
<label>Name <input id="name" value=""></label>"""
SAVER_CSP = """<!doctype html><meta charset="utf-8"><title>Saver CSP</title><h1>No script of its own</h1>"""
SAVER_NEXT = """<!doctype html><meta charset="utf-8"><title>Saver next</title><h1>Next page</h1>"""

ICONS = {'/icon-blue.png': icon_png((37, 99, 235)), '/icon-green.png': icon_png((22, 163, 74))}


class Handler(BaseHTTPRequestHandler):
    timeout = 30

    def do_GET(self):
        with (args.output_dir / 'requests.jsonl').open('a') as log:
            log.write(json.dumps({'path': self.path, 'ua': self.headers.get('User-Agent')}) + '\n')
        global landed
        if self.path.startswith('/vault/landed'):
            landed += 1
        if self.path == '/qa/landed':
            return self.send(str(landed).encode(), {'Content-Type': 'text/plain', 'Cache-Control': 'no-store'})
        if self.path == '/favicon.ico':
            self.send_response(204)
            self.end_headers()
            return
        headers = {'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store'}
        if self.path.startswith('/cookie-check/'):
            return self.cookie_check()
        if self.path.startswith('/follow/'):
            return self.follow()
        if self.path.startswith('/slow-redirect'):
            time.sleep(1.5)
            self.send_response(302)
            self.send_header('Location', '/second')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if self.path.startswith('/no-content'):
            self.send_response(204)
            self.end_headers()
            return
        if self.path.startswith('/slow'):
            query = self.path.partition('?')[2]
            milliseconds = int(dict(part.partition('=')[::2] for part in query.split('&') if part).get('ms', '1500'))
            time.sleep(milliseconds / 1000)
            payload = SLOW.encode()
        elif self.path.startswith('/busy'):
            payload = BUSY.encode()
        elif self.path.startswith('/isolation'):
            payload = ISOLATION.encode()
        elif self.path.startswith('/vault/login'):
            payload = VAULT_LOGIN.encode()
        elif self.path.startswith('/vault/get'):
            payload = VAULT_GET.encode()
        elif self.path.startswith('/vault/elsewhere'):
            payload = VAULT_ELSEWHERE.encode()
        elif self.path.startswith('/vault/landed'):
            payload = VAULT_LANDED.encode()
        elif self.path.startswith('/vault/react'):
            payload = VAULT_REACT.encode()
        elif self.path.startswith('/vault/otp/setup'):
            payload = VAULT_OTP_SETUP.encode()
        elif self.path.startswith('/vault/otp/export'):
            payload = VAULT_OTP_EXPORT.encode()
        elif self.path.startswith('/vault/otp'):
            payload = VAULT_OTP.encode()
        elif self.path.startswith('/vault/reveal'):
            payload = VAULT_REVEAL.encode()
        elif self.path.startswith('/vault/step'):
            payload = VAULT_STEP.encode()
        elif self.path.startswith('/vault/signup'):
            payload = VAULT_SIGNUP.encode()
        elif self.path.startswith('/vault/change'):
            payload = VAULT_CHANGE.encode()
        elif self.path.startswith('/vault/webauthn'):
            payload = VAULT_WEBAUTHN.encode()
        elif self.path.startswith('/passkey'):
            payload = PASSKEY.encode()
        elif self.path.startswith('/compat/frame'):
            payload = COMPAT_FRAME.encode()
        elif self.path.startswith('/compat/echo'):
            payload = (self.headers.get('Cookie') or '').encode()
            headers = {'Content-Type': 'text/plain', 'Cache-Control': 'no-store'}
        elif self.path.startswith('/compat/doc.pdf'):
            payload = PDF
            headers = {'Content-Type': 'application/pdf'}
        elif self.path.startswith('/compat'):
            payload = (COMPAT.replace('TLS_ORIGIN', 'https://127.0.0.1:%d' % tls_port)
                       .replace('FRAME_ORIGIN', 'http://localhost:%d' % server.server_port)).encode()
        elif self.path.startswith('/basic-auth'):
            expected = 'Basic ' + base64.b64encode(b'qa:secret').decode()
            if self.headers.get('Authorization') == expected:
                payload = AUTHORIZED.encode()
            else:
                payload = UNAUTHORIZED.encode()
                self.send_response(401)
                self.send_header('WWW-Authenticate', 'Basic realm="Yardlet QA"')
                for name, value in headers.items():
                    self.send_header(name, value)
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                return
        elif self.path.startswith('/login-frame'):
            query = dict(part.partition('=')[::2] for part in self.path.partition('?')[2].split('&') if part)
            payload = LOGIN_FRAME.replace('SRC', html.escape(unquote(query.get('src', '')))).encode()
        elif self.path.startswith('/login'):
            query = dict(part.partition('=')[::2] for part in self.path.partition('?')[2].split('&') if part)
            field = query.get('autofocus')
            payload = (LOGIN.replace('<input id="%s"' % field, '<input id="%s" autofocus' % field) if field else LOGIN).encode()
        elif self.path.startswith('/spa'):
            payload = SPA.encode()
        elif self.path in ICONS:
            payload = ICONS[self.path]
            headers = {'Content-Type': 'image/png'}
        elif self.path.startswith('/download'):
            query = dict(part.partition('=')[::2] for part in self.path.partition('?')[2].split('&') if part)
            name = ''.join(c for c in unquote(query.get('name', 'qa-download.txt')) if c.isalnum() or c in '.-_')
            payload = b'Yardlet browser QA download\n'
            headers = {'Content-Type': 'text/plain', 'Content-Disposition': 'attachment; filename="%s"' % name}
        elif self.path.startswith('/second'):
            payload = SECOND.encode()
        elif self.path.startswith('/animation'):
            payload = ANIMATION.encode()
        elif self.path.startswith('/a11y'):
            payload = ACCESSIBILITY.encode()
        elif self.path.startswith('/large'):
            payload = large_page().encode()
        elif self.path.startswith('/tall'):
            payload = TALL.encode()
        elif self.path.startswith('/viewport'):
            payload = VIEWPORT.encode()
        elif self.path.startswith('/responsive'):
            payload = RESPONSIVE.encode()
        elif self.path.startswith('/frames/inner'):
            payload = FRAMES_INNER.encode()
        elif self.path.startswith('/frames/cross'):
            payload = sites(FRAMES_CROSS).encode()
        elif self.path.startswith('/frames/nested'):
            payload = FRAMES_NESTED.encode()
        elif self.path.startswith('/frames'):
            payload = sites(FRAMES).encode()
        elif self.path.startswith('/handoff'):
            payload = PERSON_CHECK.encode()
        elif self.path.startswith('/pick'):
            payload = PICK.encode()
        elif self.path.startswith('/checkout/frame'):
            payload = sites(CHECKOUT_FRAME).encode()
        elif self.path.startswith('/checkout/redirect'):
            payload = sites(CHECKOUT_REDIRECT).encode()
        elif self.path.startswith('/checkout/popup'):
            payload = sites(CHECKOUT_POPUP).encode()
        elif self.path.startswith('/checkout/address'):
            payload = CHECKOUT_ADDRESS.encode()
        elif self.path.startswith('/checkout/wallet'):
            payload = CHECKOUT_WALLET.encode()
        elif self.path.startswith('/checkout'):
            payload = CHECKOUT.encode()
        elif self.path.startswith('/acs/popup'):
            payload = sites(ISSUER_POPUP).encode()
        elif self.path.startswith('/saver/frame'):
            payload = SAVER_FRAME.encode()
        elif self.path.startswith('/saver/page'):
            query = dict(part.partition('=')[::2] for part in self.path.partition('?')[2].split('&') if part)
            payload = sites(SAVER_PAGE).replace('NUMBER', html.escape(query.get('n', '0'))).encode()
        elif self.path.startswith('/saver/media'):
            payload = SAVER_MEDIA.encode()
        elif self.path.startswith('/saver/form'):
            payload = SAVER_FORM.encode()
        elif self.path.startswith('/saver/csp'):
            payload = SAVER_CSP.encode()
            headers = dict(headers, **{'Content-Security-Policy': "default-src 'none'; script-src 'none'"})
        elif self.path.startswith('/saver/next'):
            payload = SAVER_NEXT.encode()
        else:
            payload = PAGE.encode()
        self.send(payload, headers)

    def do_POST(self):
        """The checkout's form posts: the card form, and the issuer's and merchant's 3-D Secure pages. The
        log names the fields only."""
        length = int(self.headers.get('Content-Length') or 0)
        fields = {name: values[0] for name, values in parse_qs(self.rfile.read(length).decode()).items()}
        with (args.output_dir / 'requests.jsonl').open('a') as log:
            log.write(json.dumps({'path': self.path, 'method': 'POST', 'fields': sorted(fields)}) + '\n')
        global landed
        if self.path.startswith('/vault/landed'):
            landed += 1
        if self.path.startswith('/follow/signin'):
            return self.redirect('/follow/home', ['qa_follow=%s; Path=/; HttpOnly; SameSite=Lax; Max-Age=3600' % (
                ''.join(c for c in fields.get('user', '') if c.isalnum()) or 'none')])
        if self.path.startswith('/checkout/done'):
            payload = PAID
        elif self.path.startswith('/checkout/shipped'):
            payload = PAID.replace('Paid', 'Shipped')
        elif self.path.startswith('/acs/method'):
            payload = auto_post(sites('MERCHANT/checkout/method-done'), {'threeDSMethodData': 'qa'})
        elif self.path.startswith('/checkout/method-done'):
            payload = "<!doctype html><script>parent.postMessage({step: 'method'}, '*')</script>"
        elif self.path.startswith('/acs/challenge'):
            payload = ISSUER_CHALLENGE.replace('RETURN', html.escape(fields.get('return', '')))
        elif self.path.startswith('/acs/verify'):
            payload = auto_post(fields.get('return', ''), {'cres': 'authenticated'})
        elif self.path.startswith('/checkout/complete'):
            payload = "<!doctype html><script>parent.postMessage({step: 'challenge', result: '%s'}, '*')</script>" % (
                html.escape(fields.get('cres', '')))
        elif self.path.startswith('/vault/landed'):
            payload = VAULT_LANDED
        elif self.path.startswith('/checkout/return'):
            payload = '<!doctype html><meta charset="utf-8"><title>Checkout returned</title><h1>%s</h1>' % (
                html.escape(fields.get('cres', '')))
        else:
            self.send_response(404)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        self.send(payload.encode(), {'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store'})

    def follow(self):
        """The sign-ins tasks follow (FOLLOW_SIGN_IN above)."""
        route, _, query = self.path.partition('?')
        page = {'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store'}
        if route == '/follow/signin':
            return self.send(FOLLOW_SIGN_IN.encode(), page)
        if route == '/follow/home':
            return self.send(FOLLOW_HOME.encode(), page)
        if route == '/follow/idp':
            back = parse_qs(query).get('return', [''])[0]
            return self.send(FOLLOW_IDP.replace('RETURN', html.escape(back)).encode(), page)
        if route == '/follow/callback':
            return self.redirect('/follow/home', ['qa_follow=SSO; Path=/; HttpOnly; SameSite=Lax; Max-Age=3600'])
        self.send_response(404)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def cookie_check(self):
        """The sign-in's cookie check across two sites (COOKIE_SIGN_IN above)."""
        route = self.path.partition('?')[0]
        stamp = time.time_ns()
        page = {'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store'}
        if route == '/cookie-check/start':
            return self.redirect(ORIGINS['ISSUER'] + '/cookie-check/set', [])
        if route == '/cookie-check/set':
            return self.redirect('/cookie-check/verify', [
                '%s=%d; Path=/; Secure; HttpOnly; SameSite=None' % (name, stamp) for name in COOKIE_SIGN_IN])
        if route == '/cookie-check/console':
            return self.send(sites(COOKIE_CONSOLE).encode(), page)
        if route == '/cookie-check/frame':
            return self.send(COOKIE_FRAME.encode(), dict(page, **{'Set-Cookie': [
                'qa_partitioned=%d; Path=/; Secure; SameSite=None; Partitioned' % stamp,
                'qa_thirdparty=%d; Path=/; Secure; SameSite=None' % stamp]}))
        if route == '/cookie-check/verify':
            counts = {}
            for part in (self.headers.get('Cookie') or '').split(';'):
                name = part.strip().partition('=')[0]
                if name:
                    counts[name] = counts.get(name, 0) + 1
            missing = [name for name in COOKIE_SIGN_IN if name not in counts]
            twice = sorted(name for name, count in counts.items() if count > 1)
            leaked = [name for name in ['qa_partitioned'] if name in counts]
            check = {'status': 'CookieMismatch' if missing or twice or leaked else 'ok', 'missing': missing,
                     'twice': twice, 'leaked': leaked, 'names': sorted(counts),
                     'userAgent': self.headers.get('User-Agent'), 'secChUa': self.headers.get('Sec-CH-UA'),
                     'secChUaPlatform': self.headers.get('Sec-CH-UA-Platform')}
            payload = ('<!doctype html><meta charset="utf-8"><title>%s</title><h1>%s</h1><script>window.qa = '
                       '{cookieCheck: %s}</script>' % (check['status'], check['status'], json.dumps(check)))
            return self.send(payload.encode(), page)
        self.send_response(404)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def redirect(self, location, cookies):
        self.send_response(302)
        self.send_header('Location', location)
        for cookie in cookies:
            self.send_header('Set-Cookie', cookie)
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', '0')
        self.end_headers()

    def send(self, payload, headers):
        self.send_response(200)
        for name, value in headers.items():
            for one in value if isinstance(value, list) else [value]:
                self.send_header(name, one)
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
# The card issuer's site for the checkout pages: the same pages on another port, reached as localhost.
issuer = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=issuer.serve_forever, daemon=True).start()
ORIGINS = {'MERCHANT': f'http://127.0.0.1:{server.server_port}', 'ISSUER': f'http://localhost:{issuer.server_port}'}


def sites(text):
    """`text` with the checkout's merchant and issuer origins in place of MERCHANT and ISSUER."""
    for name, origin in ORIGINS.items():
        text = text.replace(name, origin)
    return text


(args.output_dir / 'port').write_text(str(server.server_port))
# The same pages over HTTPS with a self-signed certificate, for the certificate error a browser shows.
tls_port = 0
try:
    certificate, key = args.output_dir / 'tls-cert.pem', args.output_dir / 'tls-key.pem'
    subprocess.run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                    '-subj', '/CN=127.0.0.1', '-keyout', str(key), '-out', str(certificate)],
                   check=True, capture_output=True)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificate, key)

    class TLSServer(ThreadingHTTPServer):
        # The handshake runs in the request's own thread, so a connection that never finishes it (a
        # speculative one) cannot hold up the next.
        def get_request(self):
            connection, address = self.socket.accept()
            return context.wrap_socket(connection, server_side=True, do_handshake_on_connect=False), address

    tls_server = TLSServer(('127.0.0.1', 0), Handler)
    tls_port = tls_server.server_port
    threading.Thread(target=tls_server.serve_forever, daemon=True).start()
except (OSError, subprocess.CalledProcessError) as error:
    print(f'no HTTPS server: {error}', flush=True)
(args.output_dir / 'tls-port').write_text(str(tls_port))
print(f'http://127.0.0.1:{server.server_port}/', flush=True)
server.serve_forever()

#!/usr/bin/env node
// Generates README screenshots via headless Chrome with fake DNS data injected.
// Usage: node scripts/screenshot.js

const puppeteer = require('/Users/smingolelli/.npm/_npx/7d92d9a2d2ccc630/node_modules/puppeteer');
const http = require('http');
const fs = require('fs');
const path = require('path');

const OUT = path.join(__dirname, '../docs/screenshots');
const HTML = path.join(__dirname, '../public/index.html');

// ── Tiny static server ────────────────────────────────────────────────────────
function startServer() {
  return new Promise(resolve => {
    const html = fs.readFileSync(HTML, 'utf8');
    const srv = http.createServer((req, res) => {
      // All paths serve the single-page app; fetch interception handles /resolve + /fetch
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(html);
    });
    srv.listen(0, '127.0.0.1', () => resolve({ srv, port: srv.address().port }));
  });
}

// ── Fake DNS response builder ─────────────────────────────────────────────────
function makeDnsResp(answers, ad = false) {
  return JSON.stringify({ Status: 0, TC: false, RD: true, RA: true, AD: ad, CD: false, Answer: answers });
}

function txtRecord(name, data) {
  return { name: name + '.', type: 16, TTL: 300, data: `"${data}"` };
}

function caaRecord(name, data) {
  return { name: name + '.', type: 257, TTL: 300, data };
}

function dsRecord(name) {
  return { name: name + '.', type: 43, TTL: 300, data: '2371 13 2 ABC123DEF456789ABCDEF0123456789ABCDEF0123456789ABCDEF01234567' };
}

function aRecord(name) {
  return { name: name + '.', type: 1, TTL: 300, data: '104.21.0.1' };
}

// Build a fake response map for a single domain
function fakeResponsesFor(domain) {
  return {
    // SPF
    [`name=${encodeURIComponent(domain)}&type=TXT`]:
      makeDnsResp([txtRecord(domain, `v=spf1 include:_spf.simplelogin.co -all`)]),

    // DMARC
    [`name=${encodeURIComponent('_dmarc.' + domain)}&type=TXT`]:
      makeDnsResp([txtRecord('_dmarc.' + domain, `v=DMARC1; p=reject; rua=mailto:postmaster@${domain}`)]),

    // MTA-STS TXT
    [`name=${encodeURIComponent('_mta-sts.' + domain)}&type=TXT`]:
      makeDnsResp([txtRecord('_mta-sts.' + domain, `v=STSv1; id=20260101000000`)]),

    // CAA
    [`name=${encodeURIComponent(domain)}&type=CAA`]:
      makeDnsResp([
        caaRecord(domain, '0 issue "letsencrypt.org"'),
        caaRecord(domain, '0 issuewild ";"'),
        caaRecord(domain, `0 iodef "mailto:postmaster@${domain}"`),
      ]),

    // DNSSEC DS
    [`name=${encodeURIComponent(domain)}&type=DS`]:
      makeDnsResp([dsRecord(domain)]),

    // DNSSEC A via 1.1.1.1 (AD flag = true)
    [`name=${encodeURIComponent(domain)}&type=A&ns=${encodeURIComponent('1.1.1.1')}`]:
      makeDnsResp([aRecord(domain)], true),

    // DNSKEY (not needed when DS present, but queried if DS absent)
    [`name=${encodeURIComponent(domain)}&type=DNSKEY`]:
      makeDnsResp([]),

    // DKIM — hit on 'google' selector
    [`name=${encodeURIComponent('google._domainkey.' + domain)}&type=TXT`]:
      makeDnsResp([txtRecord('google._domainkey.' + domain, 'v=DKIM1; k=rsa; p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQ==')]),
  };
}

const DOMAINS = [
  'jake8us.org',
  'dewlabz.com',
  'lamolabs.com',
  'lamolabs.org',
  'lamotech.com',
  'lamotech.org',
  'lmnolabs.org',
];

// Build combined lookup for all domains
function buildFakeMap() {
  const map = {};
  for (const d of DOMAINS) {
    Object.assign(map, fakeResponsesFor(d));
  }
  return map;
}

// MTA-STS policy bodies
function policyFor(domain) {
  return `version: STSv1\nmode: enforce\nmx: mx1.simplelogin.co\nmx: mx2.simplelogin.co\nmax_age: 86400`;
}

async function injectFakeData(page, fakeMap, domains) {
  await page.evaluateOnNewDocument((fakeMap, domains, policies) => {
    const origFetch = window.fetch.bind(window);
    window.fetch = async (url, opts) => {
      // /resolve?... — fake DNS
      if (url.startsWith('/resolve?')) {
        const qs = url.slice('/resolve?'.length);
        if (qs in fakeMap) {
          return new Response(fakeMap[qs], { headers: { 'Content-Type': 'application/dns-json' } });
        }
        // Any DKIM selector not explicitly mapped → empty answer (NXDOMAIN-ish)
        return new Response(
          JSON.stringify({ Status: 3, TC: false, RD: true, RA: true, AD: false, CD: false, Answer: [] }),
          { headers: { 'Content-Type': 'application/dns-json' } }
        );
      }

      // /fetch?url=... — MTA-STS policy
      if (url.startsWith('/fetch?')) {
        const params = new URLSearchParams(url.slice('/fetch?'.length));
        const target = params.get('url') || '';
        for (const d of domains) {
          if (target.includes(`mta-sts.${d}`)) {
            return new Response(policies[d], { status: 200, headers: { 'Content-Type': 'text/plain' } });
          }
        }
        return new Response('Not found', { status: 404 });
      }

      return origFetch(url, opts);
    };
  }, fakeMap, domains, Object.fromEntries(domains.map(d => [d, policyFor(d)])));
}

async function wait(ms) {
  return new Promise(r => setTimeout(r, ms));
}

async function waitForChecks(page, timeout = 12000) {
  const start = Date.now();
  while (Date.now() - start < timeout) {
    const loading = await page.$$('.status-badge.loading');
    if (loading.length === 0) return;
    await wait(200);
  }
}

async function waitForBulk(page, timeout = 20000) {
  const start = Date.now();
  while (Date.now() - start < timeout) {
    const loading = await page.$$('.bulk-badge.loading');
    if (loading.length === 0) return;
    await wait(300);
  }
}

(async () => {
  const { srv, port } = await startServer();
  const BASE = `http://127.0.0.1:${port}`;
  const fakeMap = buildFakeMap();

  const browser = await puppeteer.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox'],
    defaultViewport: { width: 1320, height: 880 },
  });

  try {
    // ── Single domain view ───────────────────────────────────────────────────
    console.log('single-domain...');
    const page = await browser.newPage();
    await page.setViewport({ width: 1320, height: 880 });
    await injectFakeData(page, fakeMap, DOMAINS);
    await page.goto(BASE, { waitUntil: 'networkidle0' });

    await page.evaluate(() => {
      document.documentElement.setAttribute('data-theme', 'dark');
    });

    // Type domain and inspect
    await page.type('#domainInput', 'jake8us.org');
    await page.click('#inspectBtn');
    await waitForChecks(page);
    await wait(400);

    await page.screenshot({ path: `${OUT}/single-domain-dark.png`, fullPage: false });
    console.log('  -> single-domain-dark.png');

    // ── Bulk view ────────────────────────────────────────────────────────────
    console.log('bulk-view...');
    const page2 = await browser.newPage();
    await page2.setViewport({ width: 1320, height: 760 });
    await injectFakeData(page2, fakeMap, DOMAINS);
    await page2.goto(BASE, { waitUntil: 'networkidle0' });

    await page2.evaluate(() => {
      document.documentElement.setAttribute('data-theme', 'dark');
    });

    // Switch to Bulk tab
    await page2.click('#tabBulk');
    await wait(200);

    // Fill textarea with all domains
    await page2.type('#bulkInput', DOMAINS.join('\n'));
    await page2.click('#bulkBtn');
    await waitForBulk(page2);
    await wait(400);

    // Expand viewport to show full table
    const tableHeight = await page2.evaluate(() => {
      const el = document.querySelector('.bulk-table-wrap');
      return el ? el.getBoundingClientRect().bottom + 40 : 760;
    });
    await page2.setViewport({ width: 1320, height: Math.max(760, Math.ceil(tableHeight)) });
    await wait(100);

    await page2.screenshot({ path: `${OUT}/bulk-view-dark.png`, fullPage: false });
    console.log('  -> bulk-view-dark.png');

    // ── CLI check-all output ─────────────────────────────────────────────────
    console.log('cli-output...');
    const page3 = await browser.newPage();
    await page3.setViewport({ width: 900, height: 320 });
    const CLI_ROWS = [
      { domain: 'jake8us.org',   spf:'pass', dmarc:'pass', caa:'pass', dnssec:'pass', mta:'pass', dkim:'pass', dkimSel:'dkim' },
      { domain: 'dewlabz.com',   spf:'pass', dmarc:'pass', caa:'pass', dnssec:'pass', mta:'pass', dkim:'pass', dkimSel:'dkim' },
      { domain: 'lamolabs.com',  spf:'pass', dmarc:'pass', caa:'pass', dnssec:'pass', mta:'pass', dkim:'pass', dkimSel:'dkim' },
      { domain: 'lamolabs.org',  spf:'pass', dmarc:'pass', caa:'pass', dnssec:'pass', mta:'pass', dkim:'fail', dkimSel:'' },
      { domain: 'lamotech.com',  spf:'pass', dmarc:'pass', caa:'pass', dnssec:'pass', mta:'pass', dkim:'pass', dkimSel:'dkim' },
      { domain: 'lamotech.org',  spf:'pass', dmarc:'pass', caa:'pass', dnssec:'pass', mta:'pass', dkim:'pass', dkimSel:'dkim' },
      { domain: 'lmnolabs.org',  spf:'pass', dmarc:'pass', caa:'pass', dnssec:'pass', mta:'pass', dkim:'pass', dkimSel:'dkim' },
    ];
    function badge(status, sel) {
      const color = status === 'pass' ? '#28B86A' : status === 'warn' ? '#E09020' : '#D83A3A';
      const label = status.toUpperCase();
      const suffix = sel ? ` <span style="color:#5878a0">(${sel})</span>` : '';
      return `<span style="color:${color};font-weight:700">${label}</span>${suffix}`;
    }
    const rows = CLI_ROWS.map(r =>
      `<tr><td>${r.domain}</td><td>${badge(r.spf)}</td><td>${badge(r.dmarc)}</td><td>${badge(r.caa)}</td><td>${badge(r.dnssec)}</td><td>${badge(r.mta)}</td><td>${badge(r.dkim, r.dkimSel)}</td></tr>`
    ).join('');
    const cliHtml = `<!DOCTYPE html><html><head><style>
      * { margin:0; padding:0; box-sizing:border-box; }
      body { background:#0d1117; font-family:'Courier New',Courier,monospace; font-size:13.5px; color:#c0d0e4; padding:22px 26px; }
      .prompt { color:#5878a0; margin-bottom:14px; font-size:13px; }
      .prompt span { color:#4a88d8; }
      table { border-collapse:collapse; width:100%; }
      th { text-align:left; color:#5878a0; font-weight:700; padding:0 18px 6px 0; border-bottom:1px solid #253a52; }
      td { padding:5px 18px 0 0; vertical-align:top; white-space:nowrap; }
      td:first-child { color:#c0d0e4; min-width:140px; }
    </style></head><body>
      <div class="prompt">$ <span>./mta-sts/check-all.sh</span></div>
      <table>
        <thead><tr><th>DOMAIN</th><th>SPF</th><th>DMARC</th><th>CAA</th><th>DNSSEC</th><th>MTA-STS</th><th>DKIM</th></tr></thead>
        <tbody>${rows}</tbody>
      </table>
    </body></html>`;
    await page3.setContent(cliHtml, { waitUntil: 'networkidle0' });
    const bodyHeight = await page3.evaluate(() => document.body.scrollHeight);
    await page3.setViewport({ width: 900, height: bodyHeight + 44 });
    await page3.screenshot({ path: `${OUT}/cli-output-dark.png`, fullPage: false });
    console.log('  -> cli-output-dark.png');

    console.log(`\nDone. Screenshots in docs/screenshots/`);
  } finally {
    await browser.close();
    srv.close();
  }
})();

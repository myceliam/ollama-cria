"use strict";

const fs = require("fs");

function replaceExactly(text, needle, replacement, expected, label) {
  const count = text.split(needle).length - 1;
  if (count !== expected) {
    throw new Error(`${label}: expected ${expected} matches, found ${count}`);
  }
  return text.split(needle).join(replacement);
}

const helper = `
const dns_promises_ssrf = require("node:dns/promises");
const net_ssrf = require("node:net");
const ip_ssrf = require("../utils/ip");
async function assertPublicUrlSsrf(urlValue) {
    const parsed = urlValue instanceof URL ? urlValue : new URL(urlValue);
    const hostname = parsed.hostname.startsWith('[') ? parsed.hostname.slice(1, -1) : parsed.hostname;
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
        throw new Error(\`Blocked non-HTTP URL: \${parsed.protocol}\`);
    }
    if (hostname.toLowerCase() === 'localhost') {
        throw new Error('Blocked localhost destination');
    }
    const literal = net_ssrf.isIP(hostname);
    const addresses = literal ? [hostname] : (await dns_promises_ssrf.lookup(hostname, { all: true })).map((x) => x.address);
    if (!addresses.length || addresses.some((address) => ip_ssrf.isIPInNonPublicRange(address))) {
        throw new Error(\`Blocked non-public destination: \${hostname}\`);
    }
    return parsed;
}
`;

// Always enable the upstream DNS/private-IP gate in self-hosted mode. Keeping
// NODE_ENV unset is deliberate: upstream then launches Chrome --no-sandbox,
// allowing the container itself to remain non-root, no-new-privileges and
// cap_drop ALL instead of granting the documented SYS_ADMIN capability.
{
  const path = "/app/build/services/misc.js";
  let text = fs.readFileSync(path, "utf8");
  text = replaceExactly(
    text,
    "exports.privateIpNotAcceptable = Boolean(process.env['NODE_ENV']?.toLowerCase()?.includes('prod') && process.env['GCLOUD_PROJECT']);",
    "exports.privateIpNotAcceptable = true; // local self-host hardening: never allow private targets",
    1,
    "misc private-IP gate"
  );
  fs.writeFileSync(path, text);
}

// The curl engine follows redirects itself. Validate the initial URL and every
// redirect hop before opening the next connection.
{
  const path = "/app/build/services/curl.js";
  let text = fs.readFileSync(path, "utf8");
  text = replaceExactly(
    text,
    'const readability_1 = require("civkit/readability");',
    'const readability_1 = require("civkit/readability");' + helper,
    1,
    "curl helper insertion"
  );
  text = replaceExactly(
    text,
    "            const s = await this.urlToStream(nextHopUrl, opts);",
    "            await assertPublicUrlSsrf(nextHopUrl);\n            const s = await this.urlToStream(nextHopUrl, opts);",
    2,
    "curl per-hop validation"
  );
  fs.writeFileSync(path, text);
}

// The browser engine sees navigation redirects and subresources through one
// request interceptor. Resolve and reject every HTTP(S) request whose current
// destination is not globally routable.
{
  const path = "/app/build/services/puppeteer.js";
  let text = fs.readFileSync(path, "utf8");
  text = replaceExactly(
    text,
    "const misc_1 = require(\"./misc\");",
    "const misc_1 = require(\"./misc\");" + helper,
    1,
    "browser helper insertion"
  );
  const oldBlock = `            if (misc_1.privateIpNotAcceptable && (parsedUrl.hostname === 'localhost' ||
                parsedUrl.hostname.startsWith('127.'))) {
                page.emit('abuse', { url: requestUrl, page, sn, reason: \`Suspicious action: Request to localhost: \${requestUrl}\` });
                return req.abort('blockedbyclient', 1000);
            }`;
  const newBlock = `            if (requestUrl.startsWith('http:') || requestUrl.startsWith('https:')) {
                try {
                    await assertPublicUrlSsrf(parsedUrl);
                }
                catch (err) {
                    page.emit('abuse', { url: requestUrl, page, sn, reason: \`Suspicious action: \${err}\` });
                    return req.abort('blockedbyclient', 1000);
                }
            }`;
  text = replaceExactly(text, oldBlock, newBlock, 1, "browser per-request validation");
  fs.writeFileSync(path, text);
}

console.log("Applied self-hosted SSRF hardening to official Jina Reader OSS image");

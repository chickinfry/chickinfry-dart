const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const der = (tag, value) => {
  const body = Buffer.concat(value);
  let length = [body.length];
  if (body.length >= 128) {
    length = [];
    for (let n = body.length; n > 0; n >>= 8) length.unshift(n & 255);
    length.unshift(0x80 | length.length);
  }
  return Buffer.concat([Buffer.from([tag, ...length]), body]);
};
const seq = (...values) => der(0x30, values);
const hex = (value) => Buffer.from(value, 'hex');
const name = (value) => seq(der(0x31, [seq(hex('0603550403'), der(0x0c, [Buffer.from(value)]))]));
const day = 24 * 60 * 60 * 1000;
const now = Date.now();
const utc = (timestamp) => new Date(timestamp).toISOString().split('.')[0].replace(/[-:T]/g, '').slice(2) + 'Z';
const algorithm = seq(hex('06092a864886f70d01010b'), hex('0500'));
const rootKeys = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const leafKeys = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const rootName = name('Chickinfry TLS Test CA');
const extension = (oid, value, critical = false) => seq(hex(oid), ...(critical ? [hex('0101ff')] : []), der(0x04, [value]));
const certificate = (serial, subject, keys, extensions, validTo) => {
  const body = seq(
    der(0xa0, [hex('020102')]), der(0x02, [Buffer.from([serial])]), algorithm, rootName,
    seq(der(0x17, [Buffer.from(utc(now - day))]), der(0x17, [Buffer.from(validTo)])),
    subject, keys.publicKey.export({ type: 'spki', format: 'der' }), der(0xa3, [seq(...extensions)])
  );
  const bytes = seq(body, algorithm, der(0x03, [Buffer.from([0]), crypto.sign('sha256', body, rootKeys.privateKey)]));
  return '-----BEGIN CERTIFICATE-----\n' + bytes.toString('base64').match(/.{1,64}/g).join('\n') + '\n-----END CERTIFICATE-----\n';
};
const root = certificate(1, rootName, rootKeys, [extension('0603551d13', seq(hex('0101ff')), true)], '490101000000Z');
const leaf = certificate(2, name('127.0.0.1'), leafKeys, [
  extension('0603551d13', seq(), true),
  extension('0603551d0f', hex('030205a0'), true),
  extension('0603551d25', seq(hex('06082b06010505070301'))),
  extension('0603551d11', seq(der(0x87, [hex('7f000001')])))
], utc(now + 365 * day));
const parsed = new crypto.X509Certificate(leaf);
assert(parsed.verify(rootKeys.publicKey));
assert.equal(parsed.checkIP('127.0.0.1'), '127.0.0.1');
fs.writeFileSync(path.join(__dirname, 'server_chain.pem'), leaf + root);
fs.writeFileSync(path.join(__dirname, 'ca.pem'), root);
fs.writeFileSync(path.join(__dirname, 'server_key.pem'), leafKeys.privateKey.export({ type: 'pkcs8', format: 'pem' }));

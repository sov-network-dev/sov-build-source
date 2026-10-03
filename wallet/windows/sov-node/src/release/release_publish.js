'use strict';
/**
 * release_publish.js — upload built artifacts + the signed manifest to the external
 * download host (Storj recommended; works with any S3-compatible host: R2, B2, OVH).
 * See docs/SOV_DOWNLOAD_HOSTING.md.
 *
 * Pure Node `crypto` AWS Signature V4 — NO aws-sdk dependency (keeps the snap lean).
 * `PUT` to a key OVERWRITES it, so a node can always override with a newer version.
 * The host only ever stores bytes; trust is the threshold-signed manifest, so a
 * compromised host cannot forge a release (clients verify signature + SHA-256).
 *
 * Credentials come from env / sealed secret on the publishing node(s) — multiple
 * nodes may hold them (no single uploader = no single point of failure):
 *   SOV_S3_ENDPOINT   e.g. gateway.storjshare.io   (host only, no scheme)
 *   SOV_S3_REGION     e.g. us-1
 *   SOV_S3_BUCKET     e.g. sov-downloads
 *   SOV_S3_KEY / SOV_S3_SECRET
 *   SOV_DL_BASE       public link base the manifest URLs use (Storj Linksharing URL)
 */
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const https = require('https');

const sha256hex = (buf) => crypto.createHash('sha256').update(buf).digest('hex');
const hmac = (key, str) => crypto.createHmac('sha256', key).update(str, 'utf8').digest();

function _amzDate(d) {
  const z = (n) => String(n).padStart(2, '0');
  return d.getUTCFullYear() + z(d.getUTCMonth() + 1) + z(d.getUTCDate()) + 'T' +
         z(d.getUTCHours()) + z(d.getUTCMinutes()) + z(d.getUTCSeconds()) + 'Z';
}

/**
 * S3 PUT one object (path-style), SigV4-signed. Overwrites if the key exists.
 * @returns Promise<{status, key, url}>
 */
function putObject({ endpoint, region, bucket, accessKey, secretKey, key, body, contentType, now }) {
  return new Promise((resolve, reject) => {
    const host = endpoint;
    const canonicalUri = '/' + bucket + '/' + key.split('/').map(encodeURIComponent).join('/');
    const payloadHash = sha256hex(body);
    const amzdate = _amzDate(now || new Date());
    const datestamp = amzdate.slice(0, 8);
    const canonicalHeaders =
      'host:' + host + '\n' +
      'x-amz-content-sha256:' + payloadHash + '\n' +
      'x-amz-date:' + amzdate + '\n';
    const signedHeaders = 'host;x-amz-content-sha256;x-amz-date';
    const canonicalRequest = ['PUT', canonicalUri, '', canonicalHeaders, signedHeaders, payloadHash].join('\n');
    const scope = datestamp + '/' + region + '/s3/aws4_request';
    const stringToSign = ['AWS4-HMAC-SHA256', amzdate, scope, sha256hex(Buffer.from(canonicalRequest))].join('\n');
    const kDate = hmac('AWS4' + secretKey, datestamp);
    const kRegion = hmac(kDate, region);
    const kService = hmac(kRegion, 's3');
    const kSigning = hmac(kService, 'aws4_request');
    const signature = crypto.createHmac('sha256', kSigning).update(stringToSign, 'utf8').digest('hex');
    const authorization = `AWS4-HMAC-SHA256 Credential=${accessKey}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`;

    const req = https.request({
      method: 'PUT', host, path: canonicalUri,
      headers: {
        'Authorization': authorization,
        'x-amz-date': amzdate,
        'x-amz-content-sha256': payloadHash,
        'Content-Type': contentType || 'application/octet-stream',
        'Content-Length': body.length,
      },
    }, (res) => {
      let b = ''; res.on('data', (d) => (b += d));
      res.on('end', () => {
        if (res.statusCode >= 200 && res.statusCode < 300) resolve({ status: res.statusCode, key });
        else reject(new Error(`S3 PUT ${key} -> ${res.statusCode}: ${b.slice(0, 300)}`));
      });
    });
    req.on('error', reject);
    req.write(body); req.end();
  });
}

/**
 * Upload every artifact in `artifacts` (filenames) from outDir, plus the signed
 * manifest, to the bucket. Returns the public download base + uploaded keys.
 * @param o.creds {endpoint,region,bucket,accessKey,secretKey,publicBase}
 */
async function publishRelease({ artifacts, outDir, manifest, creds, now, log }) {
  const out = (log || console);
  const uploaded = [];
  for (const file of artifacts) {
    const p = path.join(outDir, file);
    if (!fs.existsSync(p)) { out.warn && out.warn('[Publish] missing ' + file); continue; }
    await putObject({ ...creds, key: file, body: fs.readFileSync(p), now });
    uploaded.push(file);
    out.info && out.info('[Publish] uploaded ' + file);
  }
  // The signed manifest is the trust anchor clients fetch first — overwrite `latest`.
  const manifestBody = Buffer.from(JSON.stringify(manifest), 'utf8');
  await putObject({ ...creds, key: 'sov-release-manifest.json', body: manifestBody, contentType: 'application/json', now });
  out.info && out.info('[Publish] uploaded signed manifest (overwrote latest)');
  return { base: creds.publicBase, uploaded, manifestKey: 'sov-release-manifest.json' };
}

/** Build creds from env (sealed secret on the publishing node). Returns null if unset. */
function credsFromEnv() {
  const e = process.env;
  if (!e.SOV_S3_ENDPOINT || !e.SOV_S3_KEY || !e.SOV_S3_SECRET || !e.SOV_S3_BUCKET) return null;
  return {
    endpoint: e.SOV_S3_ENDPOINT, region: e.SOV_S3_REGION || 'us-1', bucket: e.SOV_S3_BUCKET,
    accessKey: e.SOV_S3_KEY, secretKey: e.SOV_S3_SECRET, publicBase: e.SOV_DL_BASE || '',
  };
}

module.exports = { putObject, publishRelease, credsFromEnv };

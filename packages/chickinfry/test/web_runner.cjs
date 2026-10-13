const assert = require('node:assert/strict');
const path = require('node:path');

globalThis.self = globalThis;
globalThis.fetchCalls = 0;
globalThis.fetch = async () => {
  globalThis.fetchCalls++;
  return new Response('{}', { status: 200 });
};

process.on('beforeExit', () => assert.equal(globalThis.fetchCalls, 0));
require(path.resolve(process.argv[2]));

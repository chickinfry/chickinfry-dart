The loopback TLS certificate and key are disposable test data generated with
Node's built-in crypto module by `node test/fixtures/generate.cjs`. The test CA
expires in 2049; the server certificate is valid for one year after regeneration
and covers only 127.0.0.1. Regenerate the fixtures if the server certificate expires.
Never use this publicly stored test key as deployment credentials. Only the TLS
test trusts the CA, in that test isolate's in-memory default security context.

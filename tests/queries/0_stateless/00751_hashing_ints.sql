-- Tags: no-fasttest, no-openssl-fips

SELECT halfMD5(123456);
SELECT sipHash64(123456);
SELECT cityHash64(123456);
SELECT farmFingerprint64(123456);
SELECT farmFingerprint64('123456');
SELECT farmHash64(123456);
SELECT metroHash64(123456);
SELECT murmurHash2_32(123456);
SELECT murmurHash2_64(123456);

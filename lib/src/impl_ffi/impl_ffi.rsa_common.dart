// Copyright 2020 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

part of impl_ffi;

ffi.Pointer<ssl.EVP_PKEY> _importPkcs8RsaPrivateKey(List<int> keyData) {
  final key = _withDataAsCBS(keyData, ssl.EVP_parse_private_key);
  _checkData(key.address != 0, fallback: 'unable to parse key');

  try {
    _checkData(ssl.EVP_PKEY_id(key) == ssl.EVP_PKEY_RSA,
        message: 'key is not an RSA key');

    final rsa = ssl.EVP_PKEY_get0_RSA(key);
    _checkData(rsa.address != 0, fallback: 'key is not an RSA key');
    _checkData(ssl.RSA_check_key(rsa) == 1, fallback: 'invalid key');

    return key;
  } catch (_) {
    // We only free key if an exception/error was thrown
    ssl.EVP_PKEY_free(key);
    rethrow;
  }
}

ffi.Pointer<ssl.EVP_PKEY> _importSpkiRsaPublicKey(List<int> keyData) {
  final key = _withDataAsCBS(keyData, ssl.EVP_parse_public_key);
  _checkData(key.address != 0, fallback: 'unable to parse key');

  try {
    _checkData(ssl.EVP_PKEY_id(key) == ssl.EVP_PKEY_RSA,
        message: 'key is not an RSA key');

    final rsa = ssl.EVP_PKEY_get0_RSA(key);
    _checkData(rsa.address != 0, fallback: 'key is not an RSA key');
    _checkData(ssl.RSA_check_key(rsa) == 1, fallback: 'invalid key');

    return key;
  } catch (_) {
    // We only free key if an exception/error was thrown
    ssl.EVP_PKEY_free(key);
    rethrow;
  }
}

ffi.Pointer<ssl.EVP_PKEY> _importJwkRsaPrivateOrPublicKey(
  JsonWebKey jwk, {
  @required bool isPrivateKey,
  @required String expectedAlg,
  String expectedUse,
}) {
  assert(isPrivateKey != null);
  assert(expectedAlg != null);

  final scope = _Scope();
  try {
    void checkJwk(bool condition, String prop, String message) =>
        _checkData(condition, message: 'JWK property "$prop" $message');

    checkJwk(jwk.kty == 'RSA', 'kty', 'must be "RSA"');
    checkJwk(
      jwk.alg == null || jwk.alg == expectedAlg,
      'alg',
      'must be "$expectedAlg", if present',
    );
    checkJwk(
      jwk.use == null || jwk.use == expectedUse,
      'use',
      'must be "$expectedUse", if present',
    );

    // TODO: Consider rejecting keys with key_ops inconsistent with isPrivateKey
    //       See also JWK import logic for EC keys

    ffi.Pointer<ssl.BIGNUM> readBN(String value, String prop) {
      final bin = _jwkDecodeBase64UrlNoPadding(value, prop);
      checkJwk(bin.isNotEmpty, prop, 'must not be empty');
      checkJwk(
        bin.length == 1 || bin[0] != 0,
        prop,
        'must not have leading zeros',
      );
      return scope.create(
        () => ssl.BN_bin2bn(scope.dataAsPointer(bin), bin.length, ffi.nullptr),
        ssl.BN_free,
      );
    }

    final rsa = scope.create(ssl.RSA_new, ssl.RSA_free);

    final n = readBN(jwk.n, 'n');
    final e = readBN(jwk.e, 'e');
    _checkOpIsOne(ssl.RSA_set0_key(rsa, n, e, ffi.nullptr));
    scope.move(n); // ssl.RSA_set0_key takes ownership
    scope.move(e);

    if (isPrivateKey) {
      // The "p", "q", "dp", "dq", and "qi" properties are optional in the JWA
      // spec. However they are required by Chromium's WebCrypto implementation.
      final d = readBN(jwk.d, 'd');
      // If present properties p,q,dp,dq,qi enable optional optimizations, see:
      // https://tools.ietf.org/html/rfc7518#section-6.3.2
      // However, these are required by Chromes Web Crypto implementation:
      // https://chromium.googlesource.com/chromium/src/+/43d62c50b705f88c67b14539e91fd8fd017f70c4/components/webcrypto/algorithms/rsa.cc#82
      // They are also required by Web Crypto implementation in Firefox:
      // https://hg.mozilla.org/mozilla-central/file/38e6ad5fd7535be88e432075f76ec4a2dc294672/dom/crypto/CryptoKey.cpp#l588
      // We follow this precedence because (a) having optimizations is nice,
      // and, (b) following Chromes/Firefox behavior is safe.
      // Notice, we can choose to support this in the future without breaking
      // the public API.
      final p = readBN(jwk.p, 'p');
      final q = readBN(jwk.q, 'q');
      final dp = readBN(jwk.dp, 'dp');
      final dq = readBN(jwk.dq, 'dq');
      final qi = readBN(jwk.qi, 'qi');

      _checkOpIsOne(ssl.RSA_set0_key(rsa, ffi.nullptr, ffi.nullptr, d));
      scope.move(d); // ssl.RSA_set0_key takes ownership

      _checkOpIsOne(ssl.RSA_set0_factors(rsa, p, q));
      scope.move(p); // ssl.RSA_set0_factors takes ownership
      scope.move(q);

      _checkOpIsOne(ssl.RSA_set0_crt_params(rsa, dp, dq, qi));
      scope.move(dp); // ssl.RSA_set0_crt_params takes ownership
      scope.move(dq);
      scope.move(qi);

      // Notice that 'jwk.oth' isn't supported by Chrome:
      // https://chromium.googlesource.com/chromium/src/+/43d62c50b705f88c67b14539e91fd8fd017f70c4/components/webcrypto/algorithms/rsa.cc#31
      // This also appears to be ignored by Firefox:
      // https://hg.mozilla.org/mozilla-central/file/38e6ad5fd7535be88e432075f76ec4a2dc294672/dom/crypto/CryptoKey.cpp#l588
      // Thus, we follow Chrome and ignore property.
    }

    _checkDataIsOne(ssl.RSA_check_key(rsa), fallback: 'invalid RSA key');

    final key = scope.create(ssl.EVP_PKEY_new, ssl.EVP_PKEY_free);
    _checkOpIsOne(ssl.EVP_PKEY_set1_RSA(key, rsa));

    return scope.move(key);
  } finally {
    scope.release();
  }
}

Map<String, dynamic> _exportJwkRsaPrivateOrPublicKey(
  ffi.Pointer<ssl.EVP_PKEY> key, {
  @required bool isPrivateKey,
  @required String jwkAlg,
  @required String jwkUse,
}) {
  assert(isPrivateKey != null);
  assert(jwkUse != null);
  assert(jwkAlg != null);

  final scope = _Scope();
  try {
    final rsa = ssl.EVP_PKEY_get0_RSA(key);
    _checkOp(rsa.address != 0, fallback: 'internal key type error');

    String encodeBN(ffi.Pointer<ssl.BIGNUM> bn) {
      final N = ssl.BN_num_bytes(bn);
      final result = _withOutPointer(N, (ffi.Pointer<ssl.Bytes> p) {
        _checkOpIsOne(ssl.BN_bn2bin_padded(p, N, bn));
      });
      assert(result.length == 1 || result[0] != 0);
      return _jwkEncodeBase64UrlNoPadding(result);
    }

    // Public key parameters
    final n = scope.allocate<ffi.Pointer<ssl.BIGNUM>>();
    final e = scope.allocate<ffi.Pointer<ssl.BIGNUM>>();
    ssl.RSA_get0_key(rsa, n, e, ffi.nullptr);

    if (!isPrivateKey) {
      return JsonWebKey(
        kty: 'RSA',
        use: jwkUse,
        alg: jwkAlg,
        n: encodeBN(n.value),
        e: encodeBN(e.value),
      ).toJson();
    }

    final d = scope.allocate<ffi.Pointer<ssl.BIGNUM>>();
    ssl.RSA_get0_key(rsa, ffi.nullptr, ffi.nullptr, d);

    // p, q, dp, dq, qi is optional in:
    // // https://tools.ietf.org/html/rfc7518#section-6.3.2
    // but explicitly required when exporting in Web Crypto.
    final p = scope.allocate<ffi.Pointer<ssl.BIGNUM>>();
    final q = scope.allocate<ffi.Pointer<ssl.BIGNUM>>();
    ssl.RSA_get0_factors(rsa, p, q);

    final dp = scope.allocate<ffi.Pointer<ssl.BIGNUM>>();
    final dq = scope.allocate<ffi.Pointer<ssl.BIGNUM>>();
    final qi = scope.allocate<ffi.Pointer<ssl.BIGNUM>>();
    ssl.RSA_get0_crt_params(rsa, dp, dq, qi);

    return JsonWebKey(
      kty: 'RSA',
      use: jwkUse,
      alg: jwkAlg,
      n: encodeBN(n.value),
      e: encodeBN(e.value),
      d: encodeBN(d.value),
      p: encodeBN(p.value),
      q: encodeBN(q.value),
      dp: encodeBN(dp.value),
      dq: encodeBN(dq.value),
      qi: encodeBN(qi.value),
    ).toJson();
  } finally {
    scope.release();
  }
}

_KeyPair<ffi.Pointer<ssl.EVP_PKEY>, ffi.Pointer<ssl.EVP_PKEY>>
    _generateRsaKeyPair(
  int modulusLength,
  BigInt publicExponent,
) {
  // Sanity check for the modulusLength
  if (modulusLength < 256 || modulusLength > 16384) {
    throw UnsupportedError(
      'modulusLength must between 256 and 16k, $modulusLength is not supported',
    );
  }
  if ((modulusLength % 8) != 0) {
    throw UnsupportedError(
        'modulusLength: $modulusLength is not a multiple of 8');
  }

  // Limit publicExponent allow-listed as in chromium:
  // https://chromium.googlesource.com/chromium/src/+/43d62c50b705f88c67b14539e91fd8fd017f70c4/components/webcrypto/algorithms/rsa.cc#286
  if (publicExponent != BigInt.from(3) &&
      publicExponent != BigInt.from(65537)) {
    throw UnsupportedError('publicExponent is not supported, try 3 or 65537');
  }

  ffi.Pointer<ssl.RSA> privRSA, pubRSA;
  ffi.Pointer<ssl.EVP_PKEY> privKey, pubKey;
  try {
    // Generate private RSA key
    privRSA = ssl.RSA_new();
    _checkOp(privRSA.address != 0, fallback: 'allocation failure');
    _withBIGNUM((e) {
      _checkOp(ssl.BN_set_word(e, publicExponent.toInt()) == 1);
      _checkOp(
          ssl.RSA_generate_key_ex(privRSA, modulusLength, e, ffi.nullptr) == 1);
    });

    // Copy out the public RSA key
    final pubRSA = ssl.RSAPublicKey_dup(privRSA);
    _checkOp(pubRSA.address != 0);

    // Create private key
    privKey = ssl.EVP_PKEY_new();
    _checkOp(privKey.address != 0, fallback: 'allocation failure');
    _checkOp(ssl.EVP_PKEY_set1_RSA(privKey, privRSA) == 1);

    // Create public key
    pubKey = ssl.EVP_PKEY_new();
    _checkOp(pubKey.address != 0, fallback: 'allocation failure');
    _checkOp(ssl.EVP_PKEY_set1_RSA(pubKey, pubRSA) == 1);

    return _KeyPair(
      privateKey: privKey,
      publicKey: pubKey,
    );
  } catch (_) {
    // Free privKey/pubKey on exception
    if (privKey != null) {
      ssl.EVP_PKEY_free(privKey);
    }
    if (pubKey != null) {
      ssl.EVP_PKEY_free(pubKey);
    }
    rethrow;
  } finally {
    // Always free RSA keys, we create a new reference with set1 method
    if (privRSA != null) {
      ssl.RSA_free(privRSA);
    }
    if (pubRSA != null) {
      ssl.RSA_free(pubRSA);
    }
  }
}

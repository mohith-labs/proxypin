import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/util/compress.dart';
import 'package:proxypin/server/capture/content_decoding.dart';

/// Compressed bodies must stay readable everywhere ProxyPin shows them (fixtures made with Node's zlib).
void main() {
  const text = '{"todos":[{"id":1,"todo":"Do something nice for someone you care about","completed":false}],"total":1}';
  final brotli = base64.decode(
      'G2UAAC0OeNMudBEVCtH03rgUqEX2WPoWUVqx6GQX2VuKxGw55YC11QKp+eHzg8Ddxo7nuRTD6NUU4PPMRk4+EfiNxmNRP7jJJDAIq2awh00gHQ==');
  final zlibWrapped = base64.decode(
      'eJwdzDEOgzAQBMCvnLamob2aX0QpjH0klowX2UeBLP4ehXaKGXAmduhrICfoPD0AxULp3M2/uX6k5miysT3EanLxlBiaSVh5OiZE7kcxtwTdQul2v/+ThwKd7x/5lSMx');
  final rawDeflate = base64.decode(
      'HcwxDoMwEATAr5y2pqG9ml9EKYx9JJaMF9lHgSz+HoV2ihlwJnboayAn6Dw9AMVC6dzNv7l+pOZosrE9xGpy8ZQYmklYeTomRO5HMbcE3ULpdr//k4cCne8f');

  HttpResponse response(String encoding, List<int> body) => HttpResponse(HttpStatus.ok)
    ..headers.set('Content-Encoding', encoding)
    ..headers.set('Content-Type', 'application/json; charset=utf-8')
    ..body = body;

  test('deflate: zlib-wrapped (as HTTP defines it) and raw', () {
    expect(utf8.decode(zlibDecode(zlibWrapped)), text);
    expect(utf8.decode(zlibDecode(rawDeflate)), text);
    expect(response('deflate', zlibWrapped).bodyAsString, text);
  });

  test('brotli decodes synchronously and asynchronously', () async {
    expect(response('br', brotli).bodyAsString, text);
    expect(await response('br', brotli).decodeBodyString(), text);
    expect(utf8.decode(await brDecodeAsync(brotli)), text);
  });

  test('a body decoded elsewhere is preferred, travels in JSON and is dropped with a new body', () async {
    final message = response('br', [1, 2, 3]) // not decodable here: only the server-side copy is
      ..decodedBody = utf8.encode(text);
    expect(message.bodyAsString, text);
    expect(await message.decodeBodyString(), text);

    final copy = HttpResponse.fromJson(message.toJson());
    expect(copy.body, [1, 2, 3]);
    expect(copy.bodyAsString, text);

    copy.body = utf8.encode('edited');
    expect(copy.decodedBody, isNull);
    expect(copy.bodyAsString, isNot(text));
  });

  test('the server decodes only what the browser cannot', () {
    expect(utf8.decode(ContentDecoding.decodedBody(response('br', brotli))!), text);
    expect(ContentDecoding.decodedBody(response('gzip', gzipEncode(utf8.encode(text)))), isNull);
    expect(ContentDecoding.decodedBody(response('br', utf8.encode('not brotli'))), isNull);
    expect(ContentDecoding.decodedBody(HttpResponse(HttpStatus.ok)..body = utf8.encode(text)), isNull);
  });
}

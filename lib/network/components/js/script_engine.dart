import 'dart:async';
import 'dart:convert';

import '../../http/http.dart';
import '../../http/http.dart' as http;
import '../../http/http_headers.dart';
import '../../util/lang.dart';
import '../../util/uri.dart';
import 'script_runtime_server.dart'
    if (dart.library.js_interop) 'script_runtime_web.dart'
    if (dart.library.ui) 'script_runtime_flutter.dart' as runtime;

/// Runs ProxyPin scripts. The desktop/mobile app embeds flutter_js (QuickJS/JavaScriptCore); the headless server
/// uses a Node.js worker; the web UI asks the server.
abstract class ScriptRuntime {
  static int defaultPoolSize = 4;
  static Duration timeout = const Duration(seconds: 30);

  /// [consoleLog] receives `[level, ...args]` for every console call, like flutter_js' ConsoleLog channel.
  static ScriptRuntime create({int? poolSize, Function(dynamic args)? consoleLog}) =>
      runtime.createScriptRuntime(poolSize: poolSize ?? defaultPoolSize, consoleLog: consoleLog);

  /// Evaluates [code]; its last expression (often a Promise) is the result, decoded to Dart JSON values.
  /// Script errors are thrown as [SignalException].
  Future<dynamic> evaluate(String code);

  Future<void> dispose();
}

class JavaScriptEngine {
  //转换js request
  static Future<Map<String, dynamic>> convertJsRequest(HttpRequest request) async {
    var requestUri = request.requestUri;
    return {
      'host': requestUri?.host,
      'url': request.requestUrl,
      'path': requestUri?.path,
      'queries': requestUri?.queryParameters,
      'headers': request.headers.toMap(),
      'method': request.method.name,
      'body': await request.decodeBodyString(),
      'rawBody': request.body
    };
  }

  /// 脚本是否未修改请求：返回对象去掉 scriptContext 后与原始请求结构一致即视为未改动。
  /// 用于在脚本未真正改动请求时跳过 convertHttpRequest 的有损重建（避免 query 重编码/header 重排破坏签名）。
  /// 直接复用 runScript 已构建的请求 Map 做结构化深比较，无需再次序列化。
  static bool isRequestUnchanged(Map<dynamic, dynamic> originalRequest, dynamic result) {
    if (result is! Map) return false;
    final copy = Map<dynamic, dynamic>.of(result)..remove('scriptContext');
    return _deepEquals(copy, originalRequest);
  }

  static bool _deepEquals(dynamic a, dynamic b) {
    if (identical(a, b)) return true;
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final key in a.keys) {
        if (!b.containsKey(key) || !_deepEquals(a[key], b[key])) return false;
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_deepEquals(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }

  //转换js response
  static Future<Map<String, dynamic>> convertJsResponse(HttpResponse response) async {
    dynamic body = await response.decodeBodyString();
    if (response.contentType.isBinary) {
      body = response.body;
    }

    return {
      'headers': response.headers.toMap(),
      'statusCode': response.status.code,
      'body': body,
      'rawBody': response.body
    };
  }

  //http request
  static HttpRequest convertHttpRequest(HttpRequest request, Map<dynamic, dynamic> map) {
    request.headers.clear();
    request.method = http.HttpMethod.values.firstWhere((element) => element.name == map['method']);
    String query = UriUtils.mapToQuery(map['queries']);

    var requestUri = request.requestUri!.replace(path: map['path'], query: query);
    if (requestUri.isScheme('https')) {
      var query = requestUri.query;
      request.uri = requestUri.path + (query.isNotEmpty ? '?${requestUri.query}' : '');
    } else {
      request.uri = requestUri.toString();
    }

    map['headers'].forEach((key, value) {
      if (value is List) {
        request.headers.addValues(key, value.map((e) => e.toString()).toList());
        return;
      }
      request.headers.set(key, value);
    });

    request.headers.remove(HttpHeaders.CONTENT_ENCODING);

    //判断是否是二进制
    if (Lists.getElementType(map['body']) == int) {
      request.body = Lists.convertList<int>(map['body']);
      return request;
    }

    request.body = map['body']?.toString().codeUnits;

    if (request.body != null && (request.charset == 'utf-8' || request.charset == 'utf8')) {
      request.body = utf8.encode(map['body'].toString());
    }
    return request;
  }

  //http response
  static HttpResponse convertHttpResponse(HttpResponse response, Map<dynamic, dynamic> map) {
    response.headers.clear();
    response.status = HttpStatus.valueOf(map['statusCode']);
    map['headers'].forEach((key, value) {
      if (value is List) {
        response.headers.addValues(key, value.map((e) => e.toString()).toList());
        return;
      }

      response.headers.set(key, value);
    });

    response.headers.remove(HttpHeaders.CONTENT_ENCODING);

    //判断是否是二进制
    if (Lists.getElementType(map['body']) == int) {
      response.body = Lists.convertList<int>(map['body']);
      return response;
    }

    response.body = map['body']?.toString().codeUnits;
    if (response.body != null && (response.charset == 'utf-8' || response.charset == 'utf8')) {
      response.body = utf8.encode(map['body'].toString());
    }

    return response;
  }
}

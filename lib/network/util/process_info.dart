/*
 * Copyright 2023 Hongen Wang All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
import 'dart:typed_data';

import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/util/socket_address.dart';

import 'cache.dart';
// Native lookups (method channels, FFI, win32) only exist in the Flutter desktop/mobile build.
import 'process_info_platform_stub.dart'
    if (dart.library.js_interop) 'process_info_platform_stub.dart'
    if (dart.library.ui) 'process_info_platform_flutter.dart' as platform;

/// 进程信息工具类 用于获取进程信息
///@author wanghongen
class ProcessInfoUtils {
  static final processInfoCache = ExpiringCache<String, ProcessInfo>(const Duration(minutes: 5));

  static Future<ProcessInfo?> getProcessByPort(InetSocketAddress socketAddress, String cacheKeyPre) =>
      platform.getProcessByPort(socketAddress, cacheKeyPre);

  /// Android VPN: the real destination of a transparently proxied connection.
  static Future<HostAndPort?> getRemoteAddressByPort(int port) => platform.getRemoteAddressByPort(port);

  static Future<ProcessInfo?> getProcess(int pid) => platform.getProcess(pid);
}

class ProcessInfo {
  static final _iconCache = ExpiringCache<String, Uint8List?>(const Duration(minutes: 5));

  final String id; //应用包名
  final String name; //应用名称
  final String path;
  final String? os;

  Uint8List? icon;
  String? remoteHost;
  int? remotePost;

  ProcessInfo(this.id, this.name, this.path, {required this.os, this.icon, this.remoteHost, this.remotePost});

  factory ProcessInfo.fromJson(Map<String, dynamic> json) {
    return ProcessInfo(json['id'], json['name'], json['path'], os: json['os']);
  }

  bool get hasCacheIcon => icon != null || _iconCache.get(id) != null;

  Uint8List? get cacheIcon => icon ?? _iconCache.get(id);

  Future<Uint8List> getIcon() async {
    if (icon != null) return icon!;
    if (_iconCache.get(id) != null) return _iconCache.get(id)!;
    try {
      icon = await platform.loadIcon(this) ?? Uint8List(0);
      _iconCache.set(id, icon);
    } catch (e) {
      icon = Uint8List(0);
    }
    return icon!;
  }

  Map<String, dynamic> toJson() {
    return {'id': id, 'name': name, 'path': path, 'os': os};
  }

  @override
  String toString() {
    return toJson().toString();
  }
}

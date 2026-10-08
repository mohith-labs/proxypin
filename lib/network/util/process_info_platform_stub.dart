// Process lookup for targets without local client processes (headless server, web UI): connections come from
// other machines or from the browser, so there is nothing to resolve. See process_info_platform_flutter.dart.
import 'dart:typed_data';

import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/util/socket_address.dart';

import 'process_info.dart';

Future<ProcessInfo?> getProcessByPort(InetSocketAddress socketAddress, String cacheKeyPre) async => null;

Future<HostAndPort?> getRemoteAddressByPort(int port) async => null;

Future<ProcessInfo?> getProcess(int pid) async => null;

Future<Uint8List?> loadIcon(ProcessInfo processInfo) async => null;

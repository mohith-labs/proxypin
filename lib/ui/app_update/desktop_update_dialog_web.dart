import 'package:flutter/widgets.dart';
import 'package:proxypin/ui/app_update/remote_version_entity.dart';
import 'package:url_launcher/url_launcher.dart';

/// The web UI cannot install desktop packages; open the release asset instead.
Future<void> showDesktopUpdateDialog(BuildContext context, RemoteVersionEntity version, ReleaseAsset asset) async {
  final url = Uri.tryParse(asset.downloadUrl);
  if (url != null) await launchUrl(url);
}

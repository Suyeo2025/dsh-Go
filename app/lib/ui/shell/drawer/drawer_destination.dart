import '../../../platform/platform_caps.dart';

/// Secondary destinations the drawer (or something inside it) can open.
/// Pages the drawer opens; [settingsSearch] is ⚙ held down. 快捷入口 stores
/// these by [Enum.name], so a rename here is a change to stored preferences.
enum DrawerDestination {
  web,
  remote,
  plugins,
  engine,
  settings,
  settingsSearch,
  features;

  /// Whether this build has it: no on-device engine page on a remote-only platform (iOS).
  bool get available => this != engine || !isRemoteOnlyPlatform;
}

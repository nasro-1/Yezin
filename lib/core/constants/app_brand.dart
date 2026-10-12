class AppBrand {
  static const String name = 'Yezin';

  static const Set<String> _legacyDefaultStoreNames = {
    'Bayaa',
    'Bayaa POS',
    'Bayaa Store',
  };

  static bool isDefaultStoreName(String? name) =>
      name == null ||
      name.isEmpty ||
      name == AppBrand.name ||
      name == '${AppBrand.name} POS' ||
      _legacyDefaultStoreNames.contains(name);
}

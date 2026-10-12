enum UserType { admin, manager, cashier }

class User {
  String username;
  String name;
  String phone;
  UserType userType;
  String password;
  String? imagePath;
  Set<String> permissions;

  User({
    required this.username,
    required this.name,
    required this.phone,
    required this.userType,
    required this.password,
    this.imagePath,
    this.permissions = const {},
  });

  factory User.fromServerMap(Map<String, dynamic> map) {
    final username = (map['username'] ?? map['id'] ?? '').toString();
    final role = (map['role'] ?? 'cashier').toString().trim().toLowerCase();
    return User(
      name: (map['display_name'] ?? map['name'] ?? username).toString(),
      username: username,
      password: '',
      userType: switch (role) {
        'admin' => UserType.admin,
        'manager' => UserType.manager,
        _ => UserType.cashier,
      },
      phone: (map['phone'] ?? '').toString(),
      imagePath: map['image_path']?.toString() ?? map['imagePath']?.toString(),
    );
  }

  bool hasPermission(String permission) {
    if (permissions.contains(permission)) return true;
    if (userType == UserType.admin) return true;
    if (userType == UserType.manager &&
        {
          'customer.read',
          'supplier.read',
          'ledger.read',
          'stock.adjust',
          'stock.opening_stock',
        }.contains(permission)) {
      return true;
    }
    return false;
  }

  Map<String, dynamic> toMap() {
    return {
      'username': username,
      'name': name,
      'phone': phone,
      'userType': userType.index,
      'password': password,
      'imagePath': imagePath,
      'permissions': permissions.toList(),
    };
  }
}

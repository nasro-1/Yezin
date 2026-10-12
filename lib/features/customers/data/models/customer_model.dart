class Customer {
  final String id;
  final String code;
  final String name;
  final String registrationName;
  final String activity;
  final String category;
  final String address;
  final String phone;
  final String mobile;
  final String? email;
  final String? taxNumber;
  final String? registrationNumber;
  final String? customerReference;
  final String? commercialRegister;
  final String? taxId;
  final String? nis;
  final String? ai;
  final double creditLimit;
  final double openingBalance;
  final String? notes;
  final double currentBalance;
  final bool isActive;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Customer({
    required this.id,
    required this.code,
    required this.name,
    this.registrationName = '',
    this.activity = 'Retail',
    this.category = 'General',
    this.address = '',
    this.phone = '',
    this.mobile = '',
    this.email,
    this.taxNumber,
    this.registrationNumber,
    this.customerReference,
    this.commercialRegister,
    this.taxId,
    this.nis,
    this.ai,
    this.creditLimit = 0.0,
    this.openingBalance = 0.0,
    this.notes,
    this.currentBalance = 0.0,
    this.isActive = true,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Customer.fromMap(Map<String, dynamic> map) {
    return Customer(
      id: map['id'] as String,
      code: (map['code'] as String?) ?? '',
      name: map['name'] as String,
      registrationName: (map['registration_name'] as String?) ?? '',
      activity: (map['activity'] as String?) ?? 'Retail',
      category: (map['category'] as String?) ?? 'General',
      address: (map['address'] as String?) ?? '',
      phone: (map['phone'] as String?) ?? '',
      mobile: (map['mobile'] as String?) ?? '',
      email: map['email'] as String?,
      taxNumber: map['tax_number'] as String?,
      registrationNumber: map['registration_number'] as String?,
      customerReference: map['customer_reference'] as String?,
      commercialRegister: map['commercial_register'] as String?,
      taxId: map['tax_id'] as String?,
      nis: map['nis'] as String?,
      ai: map['ai'] as String?,
      creditLimit: (map['credit_limit'] as num?)?.toDouble() ?? 0.0,
      openingBalance: (map['opening_balance'] as num?)?.toDouble() ?? 0.0,
      notes: map['notes'] as String?,
      currentBalance: (map['current_balance'] as num?)?.toDouble() ?? 0.0,
      isActive: (map['is_active'] as int?) == 1,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'code': code,
      'name': name,
      'registration_name': registrationName,
      'activity': activity,
      'category': category,
      'address': address,
      'phone': phone,
      'mobile': mobile,
      'email': email,
      'tax_number': taxNumber,
      'registration_number': registrationNumber,
      'customer_reference': customerReference,
      'commercial_register': commercialRegister,
      'tax_id': taxId,
      'nis': nis,
      'ai': ai,
      'credit_limit': creditLimit,
      'opening_balance': openingBalance,
      'notes': notes,
      'current_balance': currentBalance,
      'is_active': isActive ? 1 : 0,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  Customer copyWith({
    String? id,
    String? code,
    String? name,
    String? registrationName,
    String? activity,
    String? category,
    String? address,
    String? phone,
    String? mobile,
    String? email,
    String? taxNumber,
    String? registrationNumber,
    String? customerReference,
    String? commercialRegister,
    String? taxId,
    String? nis,
    String? ai,
    double? creditLimit,
    double? openingBalance,
    String? notes,
    double? currentBalance,
    bool? isActive,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Customer(
      id: id ?? this.id,
      code: code ?? this.code,
      name: name ?? this.name,
      registrationName: registrationName ?? this.registrationName,
      activity: activity ?? this.activity,
      category: category ?? this.category,
      address: address ?? this.address,
      phone: phone ?? this.phone,
      mobile: mobile ?? this.mobile,
      email: email ?? this.email,
      taxNumber: taxNumber ?? this.taxNumber,
      registrationNumber: registrationNumber ?? this.registrationNumber,
      customerReference: customerReference ?? this.customerReference,
      commercialRegister: commercialRegister ?? this.commercialRegister,
      taxId: taxId ?? this.taxId,
      nis: nis ?? this.nis,
      ai: ai ?? this.ai,
      creditLimit: creditLimit ?? this.creditLimit,
      openingBalance: openingBalance ?? this.openingBalance,
      notes: notes ?? this.notes,
      currentBalance: currentBalance ?? this.currentBalance,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

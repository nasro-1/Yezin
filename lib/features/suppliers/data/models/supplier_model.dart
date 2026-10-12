class Supplier {
  final String id;
  final String code;
  final String name;
  final String registrationName;
  final String activity;
  final String address;
  final String phone;
  final String mobile;
  final String? email;
  final String? taxNumber;
  final String? registrationNumber;
  final String? supplierReference;
  final String? contactPerson;
  final String? commercialRegister;
  final String? taxId;
  final String? nis;
  final String? ai;
  final String? bankName;
  final String? bankAccount;
  final String currency;
  final double creditLimit;
  final double openingBalance;
  final String? notes;
  final double currentBalance;
  final bool isActive;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Supplier({
    required this.id,
    required this.code,
    required this.name,
    this.registrationName = '',
    this.activity = 'Retail',
    this.address = '',
    this.phone = '',
    this.mobile = '',
    this.email,
    this.taxNumber,
    this.registrationNumber,
    this.supplierReference,
    this.contactPerson,
    this.commercialRegister,
    this.taxId,
    this.nis,
    this.ai,
    this.bankName,
    this.bankAccount,
    this.currency = 'DZD',
    this.creditLimit = 0.0,
    this.openingBalance = 0.0,
    this.notes,
    this.currentBalance = 0.0,
    this.isActive = true,
    required this.createdAt,
    required this.updatedAt,
  });

  static double _number(Object? value) => value is num
      ? value.toDouble()
      : double.tryParse(value?.toString() ?? '') ?? 0.0;

  factory Supplier.fromMap(Map<String, dynamic> map) {
    return Supplier(
      id: map['id'] as String,
      code: (map['code'] as String?) ?? '',
      name: map['name'] as String,
      registrationName: (map['registration_name'] as String?) ?? '',
      activity: (map['activity'] as String?) ?? 'Retail',
      address: (map['address'] as String?) ?? '',
      phone: (map['phone'] as String?) ?? '',
      mobile: (map['mobile'] as String?) ?? '',
      email: map['email'] as String?,
      taxNumber: map['tax_number'] as String?,
      registrationNumber: map['registration_number'] as String?,
      supplierReference: map['supplier_reference'] as String?,
      contactPerson: map['contact_person'] as String?,
      commercialRegister: map['commercial_register'] as String?,
      taxId: map['tax_id'] as String?,
      nis: map['nis'] as String?,
      ai: map['ai'] as String?,
      bankName: map['bank_name'] as String?,
      bankAccount: map['bank_account'] as String?,
      currency: (map['currency'] as String?) == 'EGP'
          ? 'DZD'
          : (map['currency'] as String?) ?? 'DZD',
      creditLimit: _number(map['credit_limit']),
      openingBalance: _number(map['opening_balance']),
      notes: map['notes'] as String?,
      currentBalance: _number(map['current_balance']),
      isActive: map['is_active'] == true || map['is_active'] == 1,
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
      'address': address,
      'phone': phone,
      'mobile': mobile,
      'email': email,
      'tax_number': taxNumber,
      'registration_number': registrationNumber,
      'supplier_reference': supplierReference,
      'contact_person': contactPerson,
      'commercial_register': commercialRegister,
      'tax_id': taxId,
      'nis': nis,
      'ai': ai,
      'bank_name': bankName,
      'bank_account': bankAccount,
      'currency': currency,
      'credit_limit': creditLimit,
      'opening_balance': openingBalance,
      'notes': notes,
      'current_balance': currentBalance,
      'is_active': isActive ? 1 : 0,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }
}

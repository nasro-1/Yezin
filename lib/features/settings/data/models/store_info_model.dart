// store_info_model.dart

class StoreInfo {
  String name;
  String address;
  String phone;
  String email;
  String vat;
  String? logoPath;
  String rcNumber;
  String nif;
  String nis;
  String aiNumber;
  String capital;
  String bankAccount;

  StoreInfo({
    required this.name,
    required this.address,
    required this.phone,
    required this.email,
    required this.vat,
    this.logoPath,
    this.rcNumber = '',
    this.nif = '',
    this.nis = '',
    this.aiNumber = '',
    this.capital = '',
    this.bankAccount = '',
  });

  Map<String, String> toMap() {
    return {
      'name': name,
      'address': address,
      'phone': phone,
      'email': email,
      'vat': vat,
      'logoPath': logoPath ?? '',
      'rcNumber': rcNumber,
      'nif': nif,
      'nis': nis,
      'aiNumber': aiNumber,
      'capital': capital,
      'bankAccount': bankAccount,
    };
  }

  factory StoreInfo.fromMap(Map<dynamic, dynamic> map) {
    return StoreInfo(
      name: map['name']?.toString() ?? '',
      address: map['address']?.toString() ?? '',
      phone: map['phone']?.toString() ?? '',
      email: map['email']?.toString() ?? '',
      vat: map['vat']?.toString() ?? '',
      logoPath: map['logoPath']?.toString(),
      rcNumber: map['rcNumber']?.toString() ?? '',
      nif: map['nif']?.toString() ?? '',
      nis: map['nis']?.toString() ?? '',
      aiNumber: map['aiNumber']?.toString() ?? '',
      capital: map['capital']?.toString() ?? '',
      bankAccount: map['bankAccount']?.toString() ?? '',
    );
  }
}

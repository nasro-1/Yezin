// lib/core/data/models/store_settings_model.dart

import 'dart:io';
import 'dart:typed_data';
import 'package:bayaa_pos/core/constants/app_brand.dart';

class StoreSettingsModel {
  static const String singletonId = 'store_settings_singleton';

  final String id;
  final String storeName;
  final String? storeAddress;
  final String? storePhone;
  final String? storeEmail;
  final String? logoPath;
  final double taxRate;
  final String currency;
  final String invoicePrefix;
  final int lastInvoiceNumber;
  final bool showLogo;
  final bool showVat;
  final bool showAmountInWords;
  final bool showBarcode;
  final DateTime createdAt;
  final DateTime updatedAt;

  Uint8List? _logoBytes;

  StoreSettingsModel({
    String? id,
    required this.storeName,
    this.storeAddress,
    this.storePhone,
    this.storeEmail,
    this.logoPath,
    this.taxRate = 0.0,
    this.currency = 'DZD',
    this.invoicePrefix = 'INV',
    this.lastInvoiceNumber = 0,
    this.showLogo = true,
    this.showVat = true,
    this.showAmountInWords = true,
    this.showBarcode = true,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : id = id ?? singletonId,
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  Future<Uint8List?> getLogoBytes() async {
    if (_logoBytes != null) return _logoBytes;

    if (logoPath != null && logoPath!.isNotEmpty) {
      final file = File(logoPath!);
      if (await file.exists()) {
        _logoBytes = await file.readAsBytes();
        return _logoBytes;
      }
    }
    return null;
  }

  String generateNextInvoiceNumber() {
    final nextNumber = lastInvoiceNumber + 1;
    return '$invoicePrefix-${nextNumber.toString().padLeft(6, '0')}';
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'store_name': storeName,
      'store_address': storeAddress,
      'store_phone': storePhone,
      'store_email': storeEmail,
      'logo_path': logoPath,
      'tax_rate': taxRate,
      'currency': currency,
      'invoice_prefix': invoicePrefix,
      'last_invoice_number': lastInvoiceNumber,
      'show_logo': showLogo ? 1 : 0,
      'show_vat': showVat ? 1 : 0,
      'show_amount_in_words': showAmountInWords ? 1 : 0,
      'show_barcode': showBarcode ? 1 : 0,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  Map<String, dynamic> toSQLite() => toJson();

  factory StoreSettingsModel.fromSQLite(Map<String, dynamic> map) {
    return StoreSettingsModel(
      id: map['id'] as String,
      storeName: map['store_name'] as String,
      storeAddress: map['store_address'] as String?,
      storePhone: map['store_phone'] as String?,
      storeEmail: map['store_email'] as String?,
      logoPath: map['logo_path'] as String?,
      taxRate: (map['tax_rate'] as num?)?.toDouble() ?? 0.0,
      currency: _normalizeCurrency(map['currency'] as String?),
      invoicePrefix: map['invoice_prefix'] as String? ?? 'INV',
      lastInvoiceNumber: (map['last_invoice_number'] as int?) ?? 0,
      showLogo: _asBool(map['show_logo'], true),
      showVat: _asBool(map['show_vat'], true),
      showAmountInWords: _asBool(map['show_amount_in_words'], true),
      showBarcode: _asBool(map['show_barcode'], true),
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }

  factory StoreSettingsModel.defaultSettings() {
    return StoreSettingsModel(
      storeName: AppBrand.name,
      storeAddress: 'Address not set',
      storePhone: '0000000000',
      currency: 'DZD',
      invoicePrefix: 'INV',
    );
  }

  static String _normalizeCurrency(String? value) {
    return value == null || value == 'EGP' || value.isEmpty ? 'DZD' : value;
  }

  static bool _asBool(Object? value, bool fallback) {
    if (value == null) return fallback;
    if (value is bool) return value;
    return (value as num?)?.toInt() == 1;
  }

  StoreSettingsModel copyWith({
    String? storeName,
    String? storeAddress,
    String? storePhone,
    String? storeEmail,
    String? logoPath,
    double? taxRate,
    String? currency,
    String? invoicePrefix,
    int? lastInvoiceNumber,
    bool? showLogo,
    bool? showVat,
    bool? showAmountInWords,
    bool? showBarcode,
  }) {
    return StoreSettingsModel(
      id: id,
      storeName: storeName ?? this.storeName,
      storeAddress: storeAddress ?? this.storeAddress,
      storePhone: storePhone ?? this.storePhone,
      storeEmail: storeEmail ?? this.storeEmail,
      logoPath: logoPath ?? this.logoPath,
      taxRate: taxRate ?? this.taxRate,
      currency: currency ?? this.currency,
      invoicePrefix: invoicePrefix ?? this.invoicePrefix,
      lastInvoiceNumber: lastInvoiceNumber ?? this.lastInvoiceNumber,
      showLogo: showLogo ?? this.showLogo,
      showVat: showVat ?? this.showVat,
      showAmountInWords: showAmountInWords ?? this.showAmountInWords,
      showBarcode: showBarcode ?? this.showBarcode,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }
}

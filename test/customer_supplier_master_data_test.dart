import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:dartz/dartz.dart';
import 'package:bayaa_pos/core/data/services/sqlite_manager.dart';
import 'package:bayaa_pos/core/error/failure.dart';
import 'package:bayaa_pos/features/customers/data/models/customer_model.dart';
import 'package:bayaa_pos/features/customers/data/repository/customer_repository_impl.dart';
import 'package:bayaa_pos/features/invoice/domain/invoice_mapper.dart';
import 'package:bayaa_pos/features/orders/data/models/proforma_model.dart';
import 'package:bayaa_pos/features/suppliers/data/models/supplier_model.dart';
import 'package:bayaa_pos/features/suppliers/data/repository/supplier_repository_impl.dart';
import 'package:bayaa_pos/features/customers/presentation/customers_screen.dart';
import 'package:bayaa_pos/features/suppliers/presentation/suppliers_screen.dart';
import 'package:bayaa_pos/l10n/app_localizations.dart';

void main() {
  late Directory tempDirectory;
  late SQLiteManager database;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp('bayaa-master-data-');
    database = SQLiteManager(
      databasePath: '${tempDirectory.path}${Platform.pathSeparator}data.db',
    );
    await database.initialize();
  });

  tearDown(() async {
    await database.close();
    await tempDirectory.delete(recursive: true);
  });

  test('minimal customer and supplier remain backward compatible', () {
    final now = DateTime(2026, 9, 24);
    final customer = Customer(
      id: 'customer-old',
      code: 'CUS-001',
      name: 'John',
      phone: '0555000000',
      createdAt: now,
      updatedAt: now,
    );
    final supplier = Supplier(
      id: 'supplier-old',
      code: 'SUP-001',
      name: 'Supplier A',
      phone: '0666000000',
      createdAt: now,
      updatedAt: now,
    );

    final customerReloaded = Customer.fromMap(customer.toMap());
    final supplierReloaded = Supplier.fromMap(supplier.toMap());

    expect(customerReloaded.name, 'John');
    expect(customerReloaded.phone, '0555000000');
    expect(customerReloaded.customerReference, isNull);
    expect(supplierReloaded.name, 'Supplier A');
    expect(supplierReloaded.phone, '0666000000');
    expect(supplierReloaded.bankAccount, isNull);
  });

  test('full customer fields round-trip through model and SQLite', () async {
    final now = DateTime(2026, 9, 24);
    final customer = Customer(
      id: 'customer-full',
      code: 'CUS-002',
      name: 'HOTELL HIDAB',
      customerReference: 'HOTEL-001',
      phone: '0555000000',
      email: 'hotel@example.com',
      address: 'Algiers, Algeria',
      commercialRegister: 'RC-123456',
      taxId: 'NIF-123456789',
      nis: 'NIS-987654',
      ai: 'AI-12345',
      notes: 'VIP customer',
      createdAt: now,
      updatedAt: now,
    );

    await database.database.insert('customers', customer.toMap());
    final row = (await database.query(
      'customers',
      where: 'id = ?',
      whereArgs: [customer.id],
    ))
        .single;
    final reloaded = Customer.fromMap(row);

    expect(reloaded.toMap(), containsPair('customer_reference', 'HOTEL-001'));
    expect(reloaded.email, 'hotel@example.com');
    expect(reloaded.address, 'Algiers, Algeria');
    expect(reloaded.commercialRegister, 'RC-123456');
    expect(reloaded.taxId, 'NIF-123456789');
    expect(reloaded.nis, 'NIS-987654');
    expect(reloaded.ai, 'AI-12345');
    expect(reloaded.notes, 'VIP customer');

    await database.update(
      'customers',
      customer
          .copyWith(
            customerReference: 'HOTEL-002',
            address: 'Oran, Algeria',
            taxId: 'NIF-UPDATED',
            nis: 'NIS-UPDATED',
            ai: 'AI-UPDATED',
          )
          .toMap(),
      where: 'id = ?',
      whereArgs: [customer.id],
    );
    final edited = Customer.fromMap(
      (await database.query(
        'customers',
        where: 'id = ?',
        whereArgs: [customer.id],
      ))
          .single,
    );
    expect(edited.customerReference, 'HOTEL-002');
    expect(edited.address, 'Oran, Algeria');
    expect(edited.taxId, 'NIF-UPDATED');
    expect(edited.nis, 'NIS-UPDATED');
    expect(edited.ai, 'AI-UPDATED');
  });

  test('full supplier fields round-trip through model and SQLite', () async {
    final now = DateTime(2026, 9, 24);
    final supplier = Supplier(
      id: 'supplier-full',
      code: 'SUP-002',
      name: 'Algerian Foods',
      supplierReference: 'SUPPLIER-001',
      contactPerson: 'Samir',
      phone: '0666000000',
      email: 'supplier@example.com',
      address: 'Blida, Algeria',
      commercialRegister: 'RC-SUP-1',
      taxId: 'NIF-SUP-1',
      nis: 'NIS-SUP-1',
      ai: 'AI-SUP-1',
      bankName: 'BNA',
      bankAccount: '007999123456',
      notes: 'Preferred supplier',
      createdAt: now,
      updatedAt: now,
    );

    await database.database.insert('suppliers', supplier.toMap());
    final reloaded = Supplier.fromMap(
      (await database.query(
        'suppliers',
        where: 'id = ?',
        whereArgs: [supplier.id],
      ))
          .single,
    );

    expect(reloaded.supplierReference, 'SUPPLIER-001');
    expect(reloaded.contactPerson, 'Samir');
    expect(reloaded.email, 'supplier@example.com');
    expect(reloaded.address, 'Blida, Algeria');
    expect(reloaded.commercialRegister, 'RC-SUP-1');
    expect(reloaded.taxId, 'NIF-SUP-1');
    expect(reloaded.nis, 'NIS-SUP-1');
    expect(reloaded.ai, 'AI-SUP-1');
    expect(reloaded.bankName, 'BNA');
    expect(reloaded.bankAccount, '007999123456');
    expect(reloaded.notes, 'Preferred supplier');
  });

  test('customer and supplier search fields are case insensitive', () async {
    final now = DateTime(2026, 9, 24).toIso8601String();
    await database.database.insert('customers', {
      'id': 'search-customer',
      'code': 'CUS-SEARCH',
      'name': 'HOTELL HIDAB',
      'customer_reference': 'HOTEL-001',
      'phone': '0555111222',
      'tax_id': 'NIF-CUSTOMER',
      'is_active': 1,
      'created_at': now,
      'updated_at': now,
    });
    await database.database.insert('suppliers', {
      'id': 'search-supplier',
      'code': 'SUP-SEARCH',
      'name': 'Algerian Foods',
      'supplier_reference': 'FOOD-001',
      'phone': '0666111222',
      'tax_id': 'NIF-SUPPLIER',
      'is_active': 1,
      'created_at': now,
      'updated_at': now,
    });

    final customerMatches = await database.query(
      'customers',
      where:
          '(code LIKE ? OR name LIKE ? OR phone LIKE ? OR customer_reference LIKE ? OR tax_id LIKE ?) AND is_active = 1',
      whereArgs: [
        '%hotel-001%',
        '%hotel-001%',
        '%hotel-001%',
        '%hotel-001%',
        '%hotel-001%'
      ],
    );
    final supplierMatches = await database.query(
      'suppliers',
      where:
          '(code LIKE ? OR name LIKE ? OR phone LIKE ? OR supplier_reference LIKE ? OR tax_id LIKE ?) AND is_active = 1',
      whereArgs: [
        '%nif-supplier%',
        '%nif-supplier%',
        '%nif-supplier%',
        '%nif-supplier%',
        '%nif-supplier%'
      ],
    );

    expect(customerMatches, hasLength(1));
    expect(supplierMatches, hasLength(1));
  });

  test('schema version 35 contains local FIFO lineage and master data columns',
      () async {
    expect(SQLiteManager.databaseSchemaVersion, 35);
    final customerColumns =
        await database.database.rawQuery('PRAGMA table_info(customers)');
    final supplierColumns =
        await database.database.rawQuery('PRAGMA table_info(suppliers)');

    expect(
        customerColumns.map((row) => row['name']),
        containsAll([
          'customer_reference',
          'commercial_register',
          'tax_id',
          'nis',
          'ai'
        ]));
    expect(
        supplierColumns.map((row) => row['name']),
        containsAll([
          'supplier_reference',
          'contact_person',
          'commercial_register',
          'tax_id',
          'nis',
          'ai',
          'bank_name',
          'bank_account'
        ]));
    final stockMovementColumns =
        await database.database.rawQuery('PRAGMA table_info(stock_movements)');
    expect(
      stockMovementColumns.map((row) => row['name']),
      contains('lineage_id'),
    );
    expect(
      customerColumns
          .where((row) => row['name'] == 'customer_reference')
          .single['notnull'],
      0,
    );
  });

  test('customer legal data propagates to invoice and proforma models', () {
    final customer = Customer(
      id: 'customer-print',
      code: 'CUS-PRINT',
      name: 'HOTELL HIDAB',
      customerReference: 'HOTEL-001',
      address: 'Algiers, Algeria',
      commercialRegister: 'RC-123456',
      taxId: 'NIF-123456789',
      nis: 'NIS-987654',
      ai: 'AI-12345',
      createdAt: DateTime(2026, 9, 24),
      updatedAt: DateTime(2026, 9, 24),
    );
    final proforma = Proforma(
      id: 'proforma-1',
      referenceNumber: 'PRO-1',
      customerId: customer.id,
      proformaDate: DateTime(2026, 9, 24),
      lines: const [],
    );
    final document = InvoiceMapper.fromProforma(
      proforma: proforma,
      customer: customer,
      storeName: 'Bayaa',
      storeAddress: '',
      storePhone: '',
    );

    expect(document.customerName, 'HOTELL HIDAB');
    expect(document.customerAddress, 'Algiers, Algeria');
    expect(document.customerCommercialRegister, 'RC-123456');
    expect(document.customerTaxId, 'NIF-123456789');
    expect(document.customerNis, 'NIS-987654');
    expect(document.customerAi, 'AI-12345');
    expect(document.customerReference, 'HOTEL-001');
  });

  testWidgets('customer dialog exposes master-data fields and validates name',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: CustomersScreen(repository: _FakeCustomerRepository()),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add customer').last);
    await tester.pumpAndSettle();

    for (final label in [
      'Customer / Company Name',
      'Customer Reference',
      'Phone',
      'Email Address',
      'Address',
      'RC Number',
      'Tax ID (NIF / MF)',
      'NIS',
      'AI',
      'Notes',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('supplier dialog exposes master-data and banking fields',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SuppliersScreen(repository: _FakeSupplierRepository()),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add supplier'));
    await tester.pumpAndSettle();

    for (final label in [
      'Name',
      'Supplier Reference',
      'Contact Person',
      'Phone',
      'Email Address',
      'Address',
      'RC Number',
      'Tax ID (NIF / MF)',
      'NIS',
      'AI',
      'Bank Name',
      'RIB / Bank Account',
      'Notes',
    ]) {
      expect(find.text(label), findsOneWidget);
    }

    Finder field(String label) => find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is TextField && widget.decoration?.labelText == label,
          ),
        );
    final name = tester.getRect(field('Name'));
    final phone = tester.getRect(field('Phone'));
    final reference = tester.getRect(field('Supplier Reference'));
    final contact = tester.getRect(field('Contact Person'));
    final email = tester.getRect(field('Email Address'));
    final address = tester.getRect(field('Address'));
    final rc = tester.getRect(field('RC Number'));
    final tax = tester.getRect(field('Tax ID (NIF / MF)'));
    final nis = tester.getRect(field('NIS'));
    final ai = tester.getRect(field('AI'));
    final bank = tester.getRect(field('Bank Name'));
    final account = tester.getRect(field('RIB / Bank Account'));
    final notes = tester.getRect(field('Notes'));

    expect(name.top, phone.top);
    expect(phone.left, greaterThan(name.left));
    expect(reference.top, contact.top);
    expect(contact.left, greaterThan(reference.left));
    expect(email.top, address.top);
    expect(address.left, greaterThan(email.left));
    expect(rc.top, tax.top);
    expect(nis.top, ai.top);
    expect(bank.top, account.top);
    expect(notes.width, greaterThan(bank.width));
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);

    await tester.ensureVisible(field('Notes'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

class _FakeCustomerRepository implements CustomerRepository {
  @override
  Future<Either<Failure, Unit>> createCustomer(Customer customer) async =>
      const Right(unit);
  @override
  Future<Either<Failure, Unit>> deleteCustomer(String customerId) async =>
      const Right(unit);
  @override
  Future<Either<Failure, List<Customer>>> getAllCustomers() async =>
      const Right([]);
  @override
  Future<Either<Failure, double>> getCustomerBalance(String customerId) async =>
      const Right(0);
  @override
  Future<Either<Failure, Customer?>> getCustomerById(String customerId) async =>
      const Right(null);
  @override
  Future<Either<Failure, List<Map<String, dynamic>>>> getCustomerLedger(
          String customerId) async =>
      const Right([]);
  @override
  Future<Either<Failure, List<Customer>>> searchCustomers(String query,
          {int limit = 50}) async =>
      const Right([]);
  @override
  Future<Either<Failure, Unit>> updateCustomer(Customer customer) async =>
      const Right(unit);
}

class _FakeSupplierRepository implements SupplierRepository {
  @override
  Future<Either<Failure, Unit>> createSupplier(Supplier supplier) async =>
      const Right(unit);
  @override
  Future<Either<Failure, Unit>> deleteSupplier(String supplierId) async =>
      const Right(unit);
  @override
  Future<Either<Failure, List<Supplier>>> getAllSuppliers() async =>
      const Right([]);
  @override
  Future<Either<Failure, double>> getSupplierBalance(String supplierId) async =>
      const Right(0);
  @override
  Future<Either<Failure, Supplier?>> getSupplierById(String supplierId) async =>
      const Right(null);
  @override
  Future<Either<Failure, List<Map<String, dynamic>>>> getSupplierLedger(
          String supplierId) async =>
      const Right([]);
  @override
  Future<Either<Failure, List<Supplier>>> searchSuppliers(String query,
          {int limit = 50}) async =>
      const Right([]);
  @override
  Future<Either<Failure, Unit>> updateSupplier(Supplier supplier) async =>
      const Right(unit);
}

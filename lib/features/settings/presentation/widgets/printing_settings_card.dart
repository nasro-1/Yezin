import 'package:flutter/material.dart';

import '../../../../core/data/models/store_settings_model.dart';
import '../../../../core/data/services/persistence_initializer.dart';

class PrintingSettingsCard extends StatefulWidget {
  const PrintingSettingsCard({super.key});

  @override
  State<PrintingSettingsCard> createState() => _PrintingSettingsCardState();
}

class _PrintingSettingsCardState extends State<PrintingSettingsCard> {
  StoreSettingsModel? _settings;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repository = PersistenceInitializer.settingsRepository;
    if (repository == null) return;
    final settings = await repository.getStoreSettings();
    if (mounted) setState(() => _settings = settings);
  }

  Future<void> _set(String key, bool value) async {
    final repository = PersistenceInitializer.settingsRepository;
    final current = _settings;
    if (repository == null || current == null) return;
    final updated = current.copyWith(
      showLogo: key == 'logo' ? value : null,
      showVat: key == 'vat' ? value : null,
      showAmountInWords: key == 'words' ? value : null,
      showBarcode: key == 'barcode' ? value : null,
    );
    setState(() => _settings = updated);
    await repository.updatePrintingSettings(
      showLogo: updated.showLogo,
      showVat: updated.showVat,
      showAmountInWords: updated.showAmountInWords,
      showBarcode: updated.showBarcode,
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: settings == null
            ? const SizedBox(
                height: 48,
                child: Center(child: CircularProgressIndicator()),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Printing',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  _toggle('Show logo', 'logo', settings.showLogo),
                  _toggle('Show VAT', 'vat', settings.showVat),
                  _toggle(
                    'Amount in words',
                    'words',
                    settings.showAmountInWords,
                  ),
                  _toggle('Barcode', 'barcode', settings.showBarcode),
                ],
              ),
      ),
    );
  }

  Widget _toggle(String label, String key, bool value) {
    return SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      value: value,
      onChanged: (next) => _set(key, next),
    );
  }
}

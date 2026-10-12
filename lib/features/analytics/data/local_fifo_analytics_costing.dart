class LocalFifoAnalyticsCosting {
  const LocalFifoAnalyticsCosting();

  double? costForNextSale({
    required List<Map<String, dynamic>> movements,
    required String productId,
    required double quantity,
    required DateTime createdAt,
  }) {
    final referenceId = '__fifo_sale_cost_estimate__';
    final result = calculate(
      movements: [
        ...movements,
        {
          'id': '__fifo_sale_cost_estimate___movement',
          'product_id': productId,
          'movement_type': 'sale',
          'quantity_change': -quantity,
          'unit_cost': 0.0,
          'reference_type': 'sale',
          'reference_id': referenceId,
          'lineage_id': '__fifo_sale_cost_estimate__',
          'created_at': createdAt.toIso8601String(),
        },
      ],
      start: createdAt,
      endExclusive: createdAt.add(const Duration(microseconds: 1)),
    );
    final key = _referenceProductKey(referenceId, productId);
    if (result.incompleteReferences.contains(key)) return null;
    return result.costByReferenceProduct[key];
  }

  LocalFifoAnalyticsCostResult calculate({
    required List<Map<String, dynamic>> movements,
    required DateTime start,
    required DateTime endExclusive,
  }) {
    final inventory = <String, List<_CostLayer>>{};
    final consumedBySaleItem = <String, List<_ConsumedLayer>>{};
    final seenSaleLineages = <String>{};
    final costByProduct = <String, double>{};
    final costByLineage = <String, double>{};
    final costByReferenceProduct = <String, double>{};
    final unknownCostProducts = <String>{};
    final incompleteReferences = <String>{};
    var totalCost = 0.0;

    void insertLayer(String productId, _CostLayer layer) {
      final layers = inventory.putIfAbsent(productId, () => []);
      var index = layers.length;
      for (var i = 0; i < layers.length; i++) {
        if (layer.acquiredAt.isBefore(layers[i].acquiredAt) ||
            (layer.acquiredAt.isAtSameMomentAs(layers[i].acquiredAt) &&
                layer.sequence < layers[i].sequence)) {
          index = i;
          break;
        }
      }
      layers.insert(index, layer);
    }

    List<_ConsumedLayer> consume(String productId, double quantity) {
      final layers = inventory.putIfAbsent(productId, () => []);
      final consumed = <_ConsumedLayer>[];
      var remaining = quantity;
      while (remaining > 1e-9 && layers.isNotEmpty) {
        final layer = layers.first;
        final taken = remaining < layer.remaining ? remaining : layer.remaining;
        if (taken <= 1e-9) {
          layers.removeAt(0);
          continue;
        }
        layer.remaining -= taken;
        remaining -= taken;
        consumed.add(_ConsumedLayer(layer, taken, layer.unitCost));
        if (layer.remaining <= 1e-9) layers.removeAt(0);
      }
      return consumed;
    }

    var sequence = 0;
    for (final movement in movements) {
      final productId = movement['product_id'] as String;
      final movementType = (movement['movement_type'] as String).toLowerCase();
      final quantityChange = (movement['quantity_change'] as num).toDouble();
      final createdAt = DateTime.parse(movement['created_at'] as String);
      final movementUnitCost = (movement['unit_cost'] as num?)?.toDouble();
      final lineageId = (movement['lineage_id'] as String?)?.trim();
      final hasLineage = lineageId != null && lineageId.isNotEmpty;
      final isInRange =
          !createdAt.isBefore(start) && createdAt.isBefore(endExclusive);

      if (quantityChange > 0 &&
          (movementType == 'purchase' ||
              movementType == 'opening_stock' ||
              movementType == 'stock_adjustment')) {
        insertLayer(
          productId,
          _CostLayer(
            remaining: quantityChange,
            unitCost: movementUnitCost,
            acquiredAt: createdAt,
            sequence: sequence++,
          ),
        );
        continue;
      }

      if (movementType == 'sale' && quantityChange < 0) {
        final saleItemId = hasLineage
            ? lineageId
            : _lineageFromMovementId(movement['id'] as String);
        if (saleItemId != null) seenSaleLineages.add(saleItemId);

        final chunks = consume(productId, quantityChange.abs());
        var cost = 0.0;
        var costAvailable = true;
        for (final chunk in chunks) {
          final chunkCost = chunk.layer.unitCost;
          if (chunkCost == null) {
            costAvailable = false;
            if (isInRange) unknownCostProducts.add(productId);
          } else {
            cost += chunk.remaining * chunkCost;
          }
          chunk.cogsUnitCost = chunkCost;
        }

        var allocated =
            chunks.fold<double>(0, (sum, chunk) => sum + chunk.remaining);
        final unallocated = quantityChange.abs() - allocated;
        if (unallocated > 1e-9) {
          costAvailable = false;
          if (isInRange) unknownCostProducts.add(productId);
          final fallbackLayer = _CostLayer(
            remaining: 0,
            unitCost: null,
            acquiredAt: createdAt,
            sequence: sequence++,
          );
          chunks.add(_ConsumedLayer(fallbackLayer, unallocated, null));
        }
        if (saleItemId != null) {
          consumedBySaleItem.putIfAbsent(saleItemId, () => []).addAll(chunks);
        }
        if (isInRange && costAvailable) {
          totalCost += cost;
          costByProduct[productId] = (costByProduct[productId] ?? 0) + cost;
          if (saleItemId != null) {
            costByLineage[saleItemId] = (costByLineage[saleItemId] ?? 0) + cost;
          }
          final referenceId = movement['reference_id'] as String?;
          if (referenceId != null) {
            final key = _referenceProductKey(referenceId, productId);
            if (costAvailable) {
              costByReferenceProduct[key] =
                  (costByReferenceProduct[key] ?? 0) + cost;
            } else {
              incompleteReferences.add(key);
            }
          }
        } else if (isInRange) {
          final referenceId = movement['reference_id'] as String?;
          if (referenceId != null) {
            incompleteReferences
                .add(_referenceProductKey(referenceId, productId));
          }
        }
        continue;
      }

      if (movementType == 'customer_return' && quantityChange > 0) {
        var remaining = quantityChange;
        var restoredCost = 0.0;
        var costAvailable = true;
        final restoredLayers = <_CostLayer>[];
        final consumed = hasLineage ? consumedBySaleItem[lineageId] : null;
        while (remaining > 1e-9 && consumed != null && consumed.isNotEmpty) {
          final chunk = consumed.last;
          final restored =
              remaining < chunk.remaining ? remaining : chunk.remaining;
          if (restored <= 1e-9) {
            consumed.removeLast();
            continue;
          }
          chunk.remaining -= restored;
          remaining -= restored;
          chunk.layer.remaining += restored;
          restoredLayers.add(chunk.layer);
          final cogsUnitCost = chunk.cogsUnitCost;
          if (cogsUnitCost == null) {
            costAvailable = false;
            if (isInRange) unknownCostProducts.add(productId);
          } else {
            restoredCost += restored * cogsUnitCost;
          }
          if (chunk.remaining <= 1e-9) consumed.removeLast();
        }

        for (final layer in restoredLayers) {
          insertLayer(productId, layer);
        }
        if (remaining > 1e-9) {
          costAvailable = false;
          if (isInRange) unknownCostProducts.add(productId);
          insertLayer(
            productId,
            _CostLayer(
              remaining: remaining,
              unitCost: null,
              acquiredAt: createdAt,
              sequence: sequence++,
            ),
          );
        }
        if (isInRange && costAvailable) {
          totalCost -= restoredCost;
          costByProduct[productId] =
              (costByProduct[productId] ?? 0) - restoredCost;
          if (hasLineage) {
            costByLineage[lineageId] =
                (costByLineage[lineageId] ?? 0) - restoredCost;
          }
          final referenceId = movement['reference_id'] as String?;
          if (referenceId != null) {
            final key = _referenceProductKey(referenceId, productId);
            costByReferenceProduct[key] =
                (costByReferenceProduct[key] ?? 0) - restoredCost;
            if (!costAvailable) incompleteReferences.add(key);
          }
        } else if (isInRange) {
          final referenceId = movement['reference_id'] as String?;
          if (referenceId != null) {
            incompleteReferences
                .add(_referenceProductKey(referenceId, productId));
          }
        }
        continue;
      }

      if (quantityChange < 0) {
        consume(productId, quantityChange.abs());
      }
    }

    return LocalFifoAnalyticsCostResult(
      totalCost: unknownCostProducts.isEmpty ? totalCost : null,
      costByProduct: costByProduct,
      costByLineage: costByLineage,
      costByReferenceProduct: costByReferenceProduct,
      unknownCostProducts: unknownCostProducts,
      incompleteReferences: incompleteReferences,
      seenSaleLineages: seenSaleLineages,
    );
  }

  String? _lineageFromMovementId(String movementId) {
    const suffix = '_movement';
    if (!movementId.endsWith(suffix)) return null;
    return movementId.substring(0, movementId.length - suffix.length);
  }

  String _referenceProductKey(String referenceId, String productId) =>
      '$referenceId::$productId';
}

class LocalFifoAnalyticsCostResult {
  const LocalFifoAnalyticsCostResult({
    required this.totalCost,
    required this.costByProduct,
    required this.costByLineage,
    required this.costByReferenceProduct,
    required this.unknownCostProducts,
    required this.incompleteReferences,
    required this.seenSaleLineages,
  });

  final double? totalCost;
  final Map<String, double> costByProduct;
  final Map<String, double> costByLineage;
  final Map<String, double> costByReferenceProduct;
  final Set<String> unknownCostProducts;
  final Set<String> incompleteReferences;
  final Set<String> seenSaleLineages;
}

class _CostLayer {
  _CostLayer({
    required this.remaining,
    required this.unitCost,
    required this.acquiredAt,
    required this.sequence,
  });

  double remaining;
  final double? unitCost;
  final DateTime acquiredAt;
  final int sequence;
}

class _ConsumedLayer {
  _ConsumedLayer(this.layer, this.remaining, this.cogsUnitCost);

  final _CostLayer layer;
  double remaining;
  double? cogsUnitCost;
}

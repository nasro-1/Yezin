import 'package:flutter/material.dart';

typedef SearchableItemFilter<T> = bool Function(T item, String query);
typedef SearchableItemBuilder<T> = Widget Function(
  BuildContext context,
  T item,
);

Future<T?> showSearchableSelectionDialog<T>({
  required BuildContext context,
  required String title,
  required String searchHint,
  required List<T> items,
  required SearchableItemFilter<T> filter,
  required SearchableItemBuilder<T> itemBuilder,
  String emptyMessage = 'No items available.',
  String noResultsMessage = 'No matching items found.',
  IconData searchIcon = Icons.search,
}) {
  return showDialog<T>(
    context: context,
    builder: (_) => SearchableSelectionDialog<T>(
      title: title,
      searchHint: searchHint,
      items: items,
      filter: filter,
      itemBuilder: itemBuilder,
      emptyMessage: emptyMessage,
      noResultsMessage: noResultsMessage,
      searchIcon: searchIcon,
    ),
  );
}

class SearchableSelectionDialog<T> extends StatefulWidget {
  const SearchableSelectionDialog({
    super.key,
    required this.title,
    required this.searchHint,
    required this.items,
    required this.filter,
    required this.itemBuilder,
    required this.emptyMessage,
    required this.noResultsMessage,
    required this.searchIcon,
  });

  final String title;
  final String searchHint;
  final List<T> items;
  final SearchableItemFilter<T> filter;
  final SearchableItemBuilder<T> itemBuilder;
  final String emptyMessage;
  final String noResultsMessage;
  final IconData searchIcon;

  @override
  State<SearchableSelectionDialog<T>> createState() =>
      _SearchableSelectionDialogState<T>();
}

class _SearchableSelectionDialogState<T>
    extends State<SearchableSelectionDialog<T>> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  String _query = '';

  List<T> get _filteredItems {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return List<T>.of(widget.items);
    return widget.items
        .where((item) => widget.filter(item, query))
        .toList(growable: false);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredItems;
    final media = MediaQuery.of(context);
    final maxHeight = (media.size.height -
            media.viewInsets.bottom -
            media.viewPadding.vertical -
            96)
        .clamp(180.0, 620.0);
    final maxWidth = (media.size.width - 32).clamp(0.0, 620.0);
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: maxWidth,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _searchController,
                focusNode: _searchFocusNode,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: widget.searchHint,
                  prefixIcon: Icon(widget.searchIcon),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                          icon: const Icon(Icons.clear),
                        ),
                  border: const OutlineInputBorder(),
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
              const SizedBox(height: 12),
              if (filtered.isNotEmpty)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    '${filtered.length} result${filtered.length == 1 ? '' : 's'}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              const SizedBox(height: 4),
              Flexible(
                fit: FlexFit.loose,
                child: filtered.isEmpty
                    ? Center(
                        child: Text(
                          filtered.isEmpty && _query.trim().isNotEmpty
                              ? widget.noResultsMessage
                              : widget.emptyMessage,
                          textAlign: TextAlign.center,
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) => InkWell(
                          onTap: () =>
                              Navigator.of(context).pop(filtered[index]),
                          child: widget.itemBuilder(context, filtered[index]),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

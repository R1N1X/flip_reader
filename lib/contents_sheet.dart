import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'pdf_pipeline.dart';
import 'reader_settings.dart';

/// Table of contents and bookmarks.
///
/// There is no outline in the PDF pipeline, so "contents" here is every page as
/// a thumbnail, and bookmarks are the reader's own marks on top of it. Both live
/// in one sheet because they answer the same question: where do I jump to.
class ContentsSheet extends StatelessWidget {
  const ContentsSheet({super.key, required this.currentPage, required this.onJump});

  final int currentPage;
  final ValueChanged<int> onJump;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<ReaderSettings>();
    final book = context.watch<PdfBook>();
    final pageCount = book.pageCount;
    final thumbOf = book.thumb;
    return DefaultTabController(
      length: 2,
      child: DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, controller) => ColoredBox(
          color: const Color(0xFF15181F),
          child: Column(
            children: [
              const TabBar(
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white38,
                indicatorColor: Colors.white,
                tabs: [
                  Tab(text: 'Contents'),
                  Tab(text: 'Bookmarks'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _PageGrid(
                      pages: List.generate(pageCount, (i) => i),
                      currentPage: currentPage,
                      settings: settings,
                      thumbOf: thumbOf,
                      onJump: onJump,
                      controller: controller,
                      emptyMessage: 'This document has no pages.',
                    ),
                    _PageGrid(
                      pages: settings.bookmarks,
                      currentPage: currentPage,
                      settings: settings,
                      thumbOf: thumbOf,
                      onJump: onJump,
                      controller: controller,
                      emptyMessage:
                          'No bookmarks yet. Tap the ribbon on the toolbar to mark a page.',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PageGrid extends StatelessWidget {
  const _PageGrid({
    required this.pages,
    required this.currentPage,
    required this.settings,
    required this.thumbOf,
    required this.onJump,
    required this.controller,
    required this.emptyMessage,
  });

  final List<int> pages;
  final int currentPage;
  final ReaderSettings settings;
  final ui.Image? Function(int page) thumbOf;
  final ValueChanged<int> onJump;
  final ScrollController controller;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    if (pages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            emptyMessage,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ),
      );
    }

    return GridView.builder(
      controller: controller,
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.7,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: pages.length,
      itemBuilder: (context, i) {
        final page = pages[i];
        final image = thumbOf(page);
        final isCurrent = page == currentPage;
        return GestureDetector(
          onTap: () => onJump(page),
          child: Column(
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(
                      color: isCurrent ? Colors.white : Colors.white24,
                      width: isCurrent ? 2.5 : 1,
                    ),
                  ),
                  // A blank sheet while the thumbnail renders, never a spinner.
                  child: image == null ? null : RawImage(image: image, fit: BoxFit.contain),
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (settings.isBookmarked(page))
                    const Padding(
                      padding: EdgeInsets.only(right: 3),
                      child: Icon(Icons.bookmark, size: 11, color: Colors.white70),
                    ),
                  Text('${page + 1}', style: const TextStyle(color: Colors.white54, fontSize: 11)),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

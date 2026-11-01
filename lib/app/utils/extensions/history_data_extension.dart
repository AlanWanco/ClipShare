import 'dart:convert';
import 'dart:io';

import 'package:clipshare/app/data/enums/translation_key.dart';
import 'package:clipshare/app/data/repository/entity/tables/history.dart';
import 'package:clipshare/app/utils/extensions/file_extension.dart';
import 'package:clipshare/app/utils/extensions/platform_extension.dart';
import 'package:clipshare/app/utils/extensions/string_extension.dart';
import 'package:clipshare/app/utils/global.dart';
import 'package:clipshare/app/utils/log.dart';
import 'package:clipshare/app/services/clipboard_service.dart';
import 'package:clipshare_clipboard_listener/clipboard_manager.dart';
import 'package:clipshare_clipboard_listener/enums.dart';
import 'package:flutter/cupertino.dart';
import 'package:get/get.dart';
import 'package:super_clipboard/super_clipboard.dart';

const _waylandClipboardTag = "HistoryDataExtension";

bool _isWaylandSession() {
  final environment = Platform.environment;
  return Platform.isLinux &&
      (environment['XDG_SESSION_TYPE'] == 'wayland' ||
          environment['WAYLAND_DISPLAY']?.isNotEmpty == true);
}

class PendingWaylandImageClipboardCopy {
  PendingWaylandImageClipboardCopy({
    required Process process,
    required ClipboardService? clipboardService,
    required bool ignoreMarked,
    required Future<bool> inputReady,
  }) : _process = process,
       _clipboardService = clipboardService,
       _ignoreMarked = ignoreMarked,
       _inputReady = inputReady;

  final Process _process;
  final ClipboardService? _clipboardService;
  final Future<bool> _inputReady;
  bool _ignoreMarked;
  bool _finished = false;

  Future<bool> waitForInput() => _inputReady;

  Future<bool> commit() async {
    if (_finished) return false;
    _finished = true;

    if (!await _inputReady) {
      _process.kill();
      _cancelIgnore();
      logger.warn(
        _waylandClipboardTag,
        'wl-copy failed while receiving image bytes',
      );
      return false;
    }

    try {
      // Keep stdin open until persistence and history insertion succeed.
      await _process.stdin.close();
      final exitCode = await _process.exitCode;
      if (exitCode != 0) {
        _cancelIgnore();
        logger.warn(_waylandClipboardTag, 'wl-copy exited with code $exitCode');
        return false;
      }
      return true;
    } catch (err, stack) {
      _process.kill();
      _cancelIgnore();
      logger.error(
        _waylandClipboardTag,
        'copy image bytes to Wayland clipboard failed: $err',
        stack,
      );
      return false;
    }
  }

  Future<void> cancel() async {
    if (_finished) return;
    _finished = true;
    _process.kill();
    _cancelIgnore();
    try {
      await _process.exitCode.timeout(const Duration(seconds: 2));
    } catch (_) {
      // The process may already have exited or may not respond to termination.
    }
  }

  void _cancelIgnore() {
    if (!_ignoreMarked) return;
    _clipboardService?.cancelIgnoreNextClipboardContent(
      ClipboardContentType.image,
    );
    _ignoreMarked = false;
  }
}

Future<PendingWaylandImageClipboardCopy?> beginWaylandImageClipboardCopy(
  String imagePath,
  List<int> imageBytes,
) async {
  if (!_isWaylandSession()) return null;

  Process? process;
  ClipboardService? clipboardService;
  var ignoreMarked = false;
  try {
    if (Get.isRegistered<ClipboardService>()) {
      clipboardService = Get.find<ClipboardService>();
      clipboardService.ignoreNextClipboardContent(
        ClipboardContentType.image,
      );
      ignoreMarked = true;
    }
    process = await Process.start('/usr/bin/wl-copy', [
      '--type',
      _waylandImageMimeType(imagePath),
    ]);
    final inputReady = process.stdin
        .addStream(Stream<List<int>>.value(imageBytes))
        .then<bool>((_) => true)
        .catchError((Object err, StackTrace stack) {
          logger.error(
            _waylandClipboardTag,
            'wl-copy failed while receiving image bytes: $err',
            stack,
          );
          return false;
        });
    return PendingWaylandImageClipboardCopy(
      process: process,
      clipboardService: clipboardService,
      ignoreMarked: ignoreMarked,
      inputReady: inputReady,
    );
  } catch (err, stack) {
    process?.kill();
    if (ignoreMarked) {
      clipboardService!.cancelIgnoreNextClipboardContent(
        ClipboardContentType.image,
      );
    }
    logger.error(
      _waylandClipboardTag,
      'could not start wl-copy for image bytes: $err',
      stack,
    );
    return null;
  }
}

String _waylandImageMimeType(String path) {
  final extension = path.toLowerCase().split('.').last;
  switch (extension) {
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'webp':
      return 'image/webp';
    case 'gif':
      return 'image/gif';
    case 'bmp':
      return 'image/bmp';
    case 'tif':
    case 'tiff':
      return 'image/tiff';
    default:
      return 'image/png';
  }
}

Future<bool> _copyToWaylandClipboard(
  ClipboardContentType type,
  String content,
) async {
  if (type == ClipboardContentType.image && !await File(content).exists()) {
    logger.warn(_waylandClipboardTag, "copy image failed: $content, file not exists");
    return false;
  }

  final mimeType = type == ClipboardContentType.image
      ? _waylandImageMimeType(content)
      : 'text/plain';
  Process? process;
  ClipboardService? clipboardService;
  var ignoreMarked = false;
  try {
    if (Get.isRegistered<ClipboardService>()) {
      clipboardService = Get.find<ClipboardService>();
      clipboardService.ignoreNextClipboardContent(type);
      ignoreMarked = true;
    }
    process = await Process.start('/usr/bin/wl-copy', [
      '--type',
      mimeType,
    ]);
    if (type == ClipboardContentType.image) {
      await process.stdin.addStream(File(content).openRead());
    } else {
      process.stdin.add(utf8.encode(content));
    }
    await process.stdin.close();
    final exitCode = await process.exitCode;
    if (exitCode != 0) {
      if (ignoreMarked) {
        clipboardService!.cancelIgnoreNextClipboardContent(type);
      }
      logger.warn(_waylandClipboardTag, "wl-copy exited with code $exitCode");
    }
    return exitCode == 0;
  } catch (err, stack) {
    process?.kill();
    if (ignoreMarked) {
      clipboardService!.cancelIgnoreNextClipboardContent(type);
    }
    logger.error(_waylandClipboardTag, "copy to Wayland clipboard failed: $err", stack);
    return false;
  }
}

extension HistoryDataExtension on History {
  static const String tag = "HistoryDataExtension";
  bool get canCopy {
    var type = ClipboardContentType.parse(this.type);
    if (type != ClipboardContentType.image &&
        type != ClipboardContentType.text) {
      if(type == ClipboardContentType.file && PlatformExt.isDesktop){
        return true;
      }
      if (extracted.isNullOrEmpty) {
        return false;
      }
      type = ClipboardContentType.text;
    }
    return true;
  }

  ClipboardContentType? getCopyType() {
    final canCopy = this.canCopy;
    if (!canCopy) {
      return null;
    }
    var type = ClipboardContentType.parse(this.type);
    if (type == ClipboardContentType.image || type == ClipboardContentType.file) {
      return type;
    }
    return ClipboardContentType.text;
  }

  Future<void> copyContent({
    BuildContext? context,
    bool showFeedback = false,
  }) async {
    if (context == null && showFeedback) {
      throw 'context must be not null if show feedback';
    }
    if (!canCopy) {
      return;
    }
    final type = getCopyType();
    if (type == null) {
      return;
    }
    final content = extracted ?? this.content;
    bool copyResult;
    if (type == ClipboardContentType.file) {
      final superClipboard = SystemClipboard.instance;
      final file = File(content);
      if (superClipboard == null) {
        copyResult = false;
        logger.warn(tag, "copy file failed: superClipboard is null");
      } else if (!await file.exists()) {
        logger.warn(tag, "copy file failed: $content, file not exists");
        copyResult = false;
      } else {
        final item = DataWriterItem(
          suggestedName: file.fileName,
        );
        item.add(
          Formats.fileUri(file.uri),
        );
        try {
          await superClipboard.write([item]);
          copyResult = true;
        } catch (err, stack) {
          logger.error(tag, err, stack);
          copyResult = false;
        }
      }
    } else if (_isWaylandSession()) {
      copyResult = await _copyToWaylandClipboard(type, content);
    } else {
      copyResult = await clipboardManager.copy(type, content);
    }
    if (!showFeedback) {
      return;
    }
    if (copyResult) {
      Global.showSnackBarSuc(
        text: TranslationKey.copySuccess.tr,
        context: context,
      );
    } else {
      Global.showSnackBarErr(
        text: TranslationKey.copyFailed.tr,
        context: context,
      );
    }
  }
}
